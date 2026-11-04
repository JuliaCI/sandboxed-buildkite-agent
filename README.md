# Sandboxed Buildkite agent

This repository hosts Julia's sandboxed Buildkite workers.


## Architecture

Each host runs one scheduler, configured with runner groups. A group is one
sandbox backend with its worker tags, serving one or more Buildkite queues from
one pool of slots; it registers a Buildkite Stack per queue. The scheduler polls
for jobs, admits them against the host's CPU and memory budgets, reserves each
one, chooses its cache, and launches an agent with `--acquire-job` inside the
configured sandbox.

### Job selection

Jobs are selected only when their Buildkite agent query rules match the worker's
tags. This follows Buildkite's positive `key=value` and `key=*` matching
semantics; the Stack handles the queue match, and every `sched_*` rule is a
request to the scheduler (see below) rather than a rule for the agent.

### Job sizes

Pipeline steps size their jobs with agent tags next to `queue`. Like
Kubernetes' requests and limits, each resource has a request, what the job
typically uses, and an optional limit, the most it may use, which defaults to
the request and may not be below it:

```yaml
agents:
  queue: "build"
  sched_cpus: "4"            # request: charged against the host's `total_cpus`
  sched_cpus_limit: "16"     # CPUs it may run on: Linux cpuset, JULIA_CPU_THREADS; KVM vCPUs
  sched_mem_gib: "12"        # request: typical memory use (not charged yet)
  sched_mem_limit_gib: "40"  # Linux memory.max; KVM guest RAM
```

`sched_cpus` is what the job is charged: admission keeps the sum of requests
within `total_cpus`, and a Linux job's `cpu.weight` is `100 × cpus`. A weight is
a share relative to its siblings in one cgroup, not a number of cores: under
contention, jobs split the CPU time in proportion to their requests, next to the
scheduler's own supervisor cgroup and uncharged jobs (which weigh as one CPU),
while idle cores stay available to anyone. `sched_cpus_limit` is how wide the job
runs; only bursty jobs, such as builds that alternate parallel phases with long
serial ones, set it above `sched_cpus`. The CPU limit is a width, not a time
quota: it is enforced through the job cgroup's `cpuset.cpus` (vCPUs on KVM),
and there is no `cpu.max`.

`sched_mem_gib` is what the job typically uses. Admission does not charge it
yet; until it does, only the memory limit has an effect.

A step without any of these tags gets its runner group's `default` size for
the job's queue (see [Runner groups](#runner-groups)), so hosts can run untagged
pipelines at today's sizes, and queues such as pipeline uploads need no tags at
all. A step that sets any `sched_*` tag makes a complete request: `sched_cpus`
and `sched_mem_gib` are then required, all values must be positive integers set
with `=`, and a limit may not be below its request. The scheduler owns the whole
`sched_*` namespace: any other `sched_*` key, such as a typo or the old
`sched_threads` (now `sched_cpus_limit`), is an error rather than a tag some
agent might advertise.
The scheduler fails a job whose request is incomplete or invalid, or that has no
tags and no `default` to fall back on, with a message saying so, rather than
guessing its size or leaving it to wait for an agent that never comes.

CPU requests and limits are capped at `total_cpus`; on KVM, vCPUs and guest RAM
are capped at the group's `max_cpus` and `max_mem_gib`. A request is then capped
at its limit: a 6-vCPU guest asked for 8 CPUs is charged 6. macOS jobs always
get the whole host and ignore the tags, which must still be valid.

On Linux, `sched_mem_limit_gib` is the job's `memory.max`. A job over its limit
is OOM-killed: the kernel kills the job's largest process, the agent reports the
failure, and OOM kills are also logged before the job's cgroup is removed. Swap
is disabled for the job (`memory.swap.max = 0`) only where the kernel has swap
accounting; on kernels booted without it (5.4 on the POWER9 hosts) a job can
swap past its limit before it is killed. On KVM, the guest gets `sched_mem_limit_gib`
of RAM and reserves it plus the host overhead (30%, at least 8 GiB) against
`total_mem_gib`.

CPUs are a budget rather than specific cores: a Linux job's cgroup gets
`cpu.weight = 100 × cpus`, so CPU time is shared in proportion to requests under
contention and idle cores stay usable, and KVM domains get the same weight
through their CPU shares. libvirt places domains in its own `machine.slice`,
though, not next to the scheduler's job cgroups, so a guest's weight only
competes with other guests: Linux jobs and KVM domains on one host are not
weighed against each other. Every job is told its parallelism through
`JULIA_CPU_THREADS`.

Each Linux job also runs on a cgroup cpuset of `cpus_limit` CPUs, those least
used by the other running jobs among the CPUs the scheduler's own cgroup may use
(`cpuset.cpus.effective`, which need not start at 0 or be contiguous). Julia's
`--threads auto`, libuv's available parallelism and `nproc` follow the CPU
affinity, which the cpuset bounds, rather than `JULIA_CPU_THREADS`, so an
unconstrained job would start a thread per host CPU, which a 32-bit process
cannot even hold. The kernel enforces the cpuset for every process of the job:
a job cannot widen it, and pinning a thread outside it (`JULIA_EXCLUSIVE=1`)
fails rather than escaping. The cpuset bounds how wide a job runs; `cpu.weight`
still decides its share, and cpusets may overlap when the host is
oversubscribed. The scheduler's systemd unit delegates the `cpu`, `cpuset` and
`memory` controllers (`Delegate=cpu cpuset memory`, written by `bk enable` or
`bk reinstall`), and the scheduler does not start without them.

### Admission

Pending jobs of all groups and queues are admitted in one pass, ordered by
runner-group `priority` (lower first), then Buildkite job `priority` (higher
first), then age. A job starts when its group has a free slot and its CPUs, and
for KVM its guest RAM plus host overhead, fit what is left. The oldest job that
does not fit blocks younger ones until it does, so big jobs are not starved by
small ones; jobs of a group without a free slot do not block others. Running
jobs are never preempted. While a group cannot take jobs, its pollers only look
at the oldest job of each queue; once it can, nothing at its priority or below is
admitted until its queues have been listed in full.

A job's slot and resources are released only once its teardown is confirmed:
every process of its Linux cgroup killed (one by one where the kernel has no
`cgroup.kill`) and the cgroup removed, or its KVM domain gone. A slot whose job
survives stays leased and charged, shows as `quarantined` in `bk status` and
`sba_slots_quarantined`, and is released when a retried teardown succeeds. A
scheduler does not start while job cgroups or domains of an earlier one survive.

### Cache isolation

After reserving a job, the scheduler fetches its environment and selects a cache.
The main cache is partitioned by worker, pipeline UUID, and trust level:

```
<cachedir>/<runner-group>-<host>.<worker>/<pipeline-uuid>/<trusted|untrusted>/
```

Only `BUILDKITE_PULL_REQUEST=false` is trusted; everything else is untrusted.

Untrusted jobs cannot write caches read by trusted jobs, pipelines do not share
caches, and each worker has exclusive access to its cache. Pull requests within
one partition reuse the untrusted cache; caches are not created per PR or primed
from trusted builds.

Linux may additionally configure a shared compiler cache. It omits the worker
dimension but retains the pipeline and trust boundaries:

```
<sharedcache>/<pipeline-uuid>/<trusted|untrusted>/
```

macOS and KVM do not support this shared cache. KVM persists a cache-disk overlay
in the main partition and recreates the OS-disk overlay for each job.


## Command-line interface

The main entry point is `bin/bk`:

```
❯ ./bin/bk --help
usage: bk [--config PATH] <command> [options]

Commands:
  scheduler     run the scheduler in the foreground
  enable        generate and enable the host scheduler service (does not start it)
  start         start the enabled scheduler service
  stop          stop the running scheduler service and clean up backend resources
  restart       restart the enabled scheduler service and report interrupted jobs
  reinstall     regenerate and restart the scheduler service and report interrupted jobs
  status        show scheduler service state and the latest scheduler snapshot
  logs          show scheduler or per-slot backend logs
  disable       stop the scheduler and remove its service and host setup

Global options:
  --config PATH   path to the config file (default: ./config.toml)
  -h, --help      show this help message
```

`stop`, `restart`, `reinstall` and `disable` first ask the scheduler to stop by
writing `stop-request` into its `logdir`; on Linux, a plain `systemctl stop` does
the same through the unit's `ExecStop`. The scheduler then admits nothing more
and stops the running jobs one at a time, a few seconds apart: it stops each
job's agent and, two seconds later, kills the job's processes rather than wait
out the agent's cancel grace period. The agent then reports the job as
`exit_status -1` with `signal_reason: agent_stop` and exits, and the scheduler
deregisters its stacks. Pipelines retry those jobs automatically on another
host, and also jobs whose agent was lost (`-1` without a reason, e.g. a Windows
guest powered off by a stop or a crashed host):

```yaml
retry:
  automatic:
    - exit_status: -1
      signal_reason: [none, agent_stop]
      limit: 1
    - exit_status: "*"
      signal_reason: agent_stop
      limit: 1
```

Windows guests are shut down cleanly instead, and FreeBSD guests still wait out
the agent's cancel grace period. Jobs still running after that are force-stopped.
If the scheduler has not exited after ten minutes, the service is killed as
before.

The commands also report jobs from the last scheduler snapshot
and print `bk job retry JOB_ID` commands for jobs shown as running. `restart`
preserves the existing service definition; `reinstall` regenerates it and reruns
host setup before starting the scheduler. Here `bk` is the Buildkite CLI on the
caller's machine, which supplies the API credentials needed to retry a job. The
snapshot is best-effort; wait for Buildkite to mark a job failed before retrying
it. Jobs that were only reserved return to the queue without a manual retry.
On macOS, `disable` also removes the caffeinate and coredump launchd services
installed by `enable`.


## Configuration

Create a `config.toml` containing `[scheduler]` and one or more runner groups.
Examples live under `platforms/<platform>/`.

### Scheduler

- `logdir`: Scheduler state and job logs; supports relative and `@scratch/`
  paths.
- `total_cpus`: Host CPU pool size (default and maximum: all logical CPUs). On
  macOS this is how wide each job runs, a per-host tuning fact; it counts the
  efficiency cores of Apple Silicon too, which Julia 1.10's `Sys.CPU_THREADS`
  leaves out.
- `total_mem_gib`: Host memory budget in GiB (default: physical memory).
- `min_mem_available_gib`: Admit no job while the host's `MemAvailable` is below
  this many GiB (default: `0`, disabled; Linux only).

- `metrics_dir`: node_exporter textfile directory for the scheduler's metrics
  (default: unset, no metrics; see [Metrics](#metrics)).

Advanced options are `poll_interval` (15 seconds), `error_sleep` (10 seconds),
`reservation_expiry_seconds` (300 seconds), and `assignment_timeout_seconds`
(12 hours).

### Metrics

With `metrics_dir` set, the scheduler writes
`<metrics_dir>/sandboxed_buildkite_agent.prom` for node_exporter's textfile
collector. The status heartbeat (at most every 30 seconds) writes it from the
same snapshot as `scheduler-status.json`, atomically; a clean shutdown removes
it, and a dry run never writes it. A failing write is logged and does not stop
scheduling. Only this host's own state is exported, all gauges, without a host
label (the scrape adds `instance`):

| Metric | Labels | Meaning |
|---|---|---|
| `sba_cpus_capacity`, `sba_cpus_allocated` | | `total_cpus`, and the CPUs charged to running jobs |
| `sba_mem_gib_capacity`, `sba_mem_gib_allocated` | | `total_mem_gib`, and the GiB reserved (only KVM guests reserve memory) |
| `sba_memory_braked` | | 1 while `MemAvailable` is below `min_mem_available_gib` |
| `sba_jobs_running` | `group`, `queue` | slots holding a job (setup and cleanup included), by the job's queue |
| `sba_slots_used`, `sba_slots_max` | `group` | leased slots and `max_slots` |
| `sba_group_blocked` | `group` | 1 when a job waits for resources or the backend is unavailable |
| `sba_scheduler_info` | `version` (git commit) | constant 1 |

The file is not refreshed while the scheduler is down, so readers should check
its age with node_exporter's `node_textfile_mtime_seconds` and ignore it when it
is older than a couple of minutes. Linux node_exporter packages read
`/var/lib/prometheus/node-exporter` (the directory must be writable by the
scheduler's user); on macOS, start node_exporter with
`--collector.textfile.directory=<dir>`.

### Runner groups

- `queues`: Buildkite queues served by the group, as an array or a
  comma-separated string (default: `["build", "test"]`). Each queue gets its own
  Stack, `julia-<group>-<queue>-<host>` (`julia-<group>-<host>` for a group with
  one queue).
- `default`: Table with the size of jobs whose step sets no `sched_*` tags, with
  the same requests and limits as the tags: `cpus`, `cpus_limit` (default:
  `cpus`), `mem_gib` (default: unlimited on Linux) and `mem_limit_gib`
  (default: `mem_gib`; KVM needs one of the two); on Linux, `cpus = 0` charges
  nothing. A table per
  queue, such as `[linux.default.build]`, overrides it for that queue; each such
  table is a complete size and inherits nothing from the group's. Without a
  `default` for its queue, an untagged job is failed. Tags always override the
  default. Not available on macOS, where a job always gets the whole host
  (`cpus = cpus_limit = total_cpus`).

  ```toml
  [linux.default.build]
  cpus = 4
  cpus_limit = 16
  mem_gib = 40
  [linux.default.test]
  cpus = 12
  mem_gib = 64
  ```
- `max_cpus`, `max_mem_gib`: KVM only; caps on the vCPUs and guest RAM a
  tagged step can get. These are facts about the host and image, not policy.
- `max_slots`: Number of persistent worker identities (cache directories, and on
  KVM the domain name and cache disk). Slots bound disk use, not concurrency;
  the lowest free slot is used first so warm caches are reused. Defaults to
  `total_cpus` (1 on macOS) and is required when a `default` has `cpus = 0`.
- `priority`: Admission priority; lower values run first (default: `10`). Only
  needed for groups that must jump the queue, such as launchers.
- `backend`: `linux-sandbox`, `macos-seatbelt`, or `kvm` (default: native).
- `guest`: KVM guest, either `windows` or `freebsd`.
- `platform`: BinaryPlatforms triplet (default: host platform).
- `tags`: Additional Buildkite agent tags.
- `tempdir`, `cachedir`: Temporary and worker-local cache roots.
- `sharedcache`: Optional Linux-only compiler-cache root.
- `persistence_dir`: Optional Linux overlayfs location.
- `secrets_dir`: Directory containing `buildkite-agent-token` (default:
  `agent/secrets`); see [`agent/secrets/README.md`](agent/secrets/README.md).
- `verbose`: Enable verbose backend output.

An advanced option is `stack_key`.


## Images

Linux uses Julia artifacts and macOS uses host toolchains. KVM images are built
locally. Create `agent/secrets/credentials.pkrvars.hcl` with a `password` value,
then run:

```
cd platforms/windows-kvm  # or platforms/freebsd-kvm
make validate
make all
```

`make base` and `make worker` build the layers individually. See the
[Windows](platforms/windows-kvm/README.md) and
[FreeBSD](platforms/freebsd-kvm/README.md) documentation for details.


## Host storage mounts

If scheduler storage lives on a separate Linux filesystem, add a host-local
systemd dependency so everything is mounted before the agent starts. For example:

```sh
unit=sandboxed-buildkite-agent.service
sudo install -d -m 0755 "/etc/systemd/system/${unit}.d"
sudo tee "/etc/systemd/system/${unit}.d/storage-mount.conf" >/dev/null <<'EOF'
[Unit]
RequiresMountsFor=/julia
EOF
sudo systemctl daemon-reload
systemctl show "$unit" -p Requires -p After
```

Replace `/julia` with the host's mountpoint. The drop-in survives
`bin/bk disable && bin/bk enable`.
