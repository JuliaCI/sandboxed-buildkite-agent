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

The scheduler fits jobs onto hosts and tells each job what it got:

1. **Hosts state facts.** Each host's configuration says how many CPUs
   (`total_cpus`) and how much memory (`total_mem_gib`) it has for jobs. On
   Apple Silicon `total_cpus` counts the performance cores only, and
   `total_mem_gib` is physical memory minus what the OS and the scheduler need.
   No host configuration names how wide a particular job runs.
2. **A job's size is its `sched_*` tags, else its runner group's default for
   the job's queue.** Sizes are capped at the group's limits (on KVM,
   `max_cpus` and `max_mem_gib`) and CPUs at `total_cpus`. The scheduler
   admits the job once that size fits what is left of the host; it never
   shrinks a size to fit what is currently free, the job waits instead. A size
   the host can never hold (today: a KVM guest's memory) is skipped as
   impossible and left to other hosts.
3. **macOS hosts run one job at a time, and every macOS job gets the whole
   host:** `total_cpus` CPUs and `total_mem_gib` GiB, whatever `sched_*` tags
   its step sets.
4. **The granted size is exported to the job** as `SBA_CPUS`,
   `SBA_CPUS_LIMIT`, `SBA_MEM_GIB` and `SBA_MEM_LIMIT_GIB` (see
   [Job environment](#job-environment)), by every backend. Jobs size themselves
   from these rather than probing `nproc`, `hw.memsize` or cgroups.

Pipeline steps size their jobs with agent tags next to `queue`. Like
Kubernetes' requests and limits, each resource has a request, what the job
typically uses, and an optional limit, the most it may use, which defaults to
the request and may not be below it:

```yaml
agents:
  queue: "build"
  sched_cpus: "4"            # request: charged against the host's `total_cpus`
  sched_cpus_limit: "16"     # CPUs it may run on: Linux cpuset, KVM vCPUs; SBA_CPUS_LIMIT
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
of RAM and reserves it plus the host overhead (2 GiB) against
`total_mem_gib`.

CPUs are a budget rather than specific cores: a Linux job's cgroup gets
`cpu.weight = 100 × cpus`, so CPU time is shared in proportion to requests under
contention and idle cores stay usable, and KVM domains get the same weight
through their CPU shares. libvirt places domains in its own `machine.slice`,
though, not next to the scheduler's job cgroups, so a guest's weight only
competes with other guests: Linux jobs and KVM domains on one host are not
weighed against each other.

Each Linux job also runs on a cgroup cpuset of `cpus_limit` CPUs, those least
used by the other running jobs among the CPUs the scheduler's own cgroup may use
(`cpuset.cpus.effective`, which need not start at 0 or be contiguous). Julia's
`--threads auto`, libuv's available parallelism and `nproc` follow the CPU
affinity, which the cpuset bounds, rather than any environment variable, so an
unconstrained job would start a thread per host CPU, which a 32-bit process
cannot even hold. The kernel enforces the cpuset for every process of the job:
a job cannot widen it, and pinning a thread outside it (`JULIA_EXCLUSIVE=1`)
fails rather than escaping. The cpuset bounds how wide a job runs; `cpu.weight`
still decides its share, and cpusets may overlap when the host is
oversubscribed. The scheduler's systemd unit delegates the `cpu`, `cpuset` and
`memory` controllers (`Delegate=cpu cpuset memory`, written by `sba enable` or
`sba reinstall`), and the scheduler does not start without them.

Never add a `cpu.max` quota to the scheduler's or a job's cgroup. Once the
job's cgroup has a quota, Julia's bundled libuv (Julia 1.12 and later) reports
its available parallelism as (quota / period) × (`cpu.weight` / 100), at least
1 and at most the CPUs of its affinity mask; without a quota it ignores the
weight. The scheduler sets `cpu.weight` from the CPU request (100 × `cpus`), so
a quota would make what Julia sees depend on the request and the quota rather
than on the cpuset.

### Job environment

Every backend (Linux sandbox, macOS seatbelt and the KVM guests) exports the
job's granted allocation:

| Variable | Value |
|---|---|
| `SBA_CPUS` | CPU request charged to the job (`0` for an uncharged job) |
| `SBA_CPUS_LIMIT` | CPUs the job may run on: its cpuset on Linux (every CPU of the scheduler's cgroup for groups without a CPU limit), the whole host's `total_cpus` on macOS, the vCPUs on KVM |
| `SBA_MEM_GIB` | Memory request in GiB; unset when the job was granted none |
| `SBA_MEM_LIMIT_GIB` | Memory limit in GiB: Linux `memory.max`, KVM guest RAM, advisory on macOS; unset when unlimited |

`BUILDKITE_AGENT_META_DATA_SCHED_*` (from the agent tags) carries what the step
*requested*; `SBA_*` is what the job was *granted*, after defaults and caps.

The shipped environment hook,
[`agent/hooks/environment.d/101_julia_num_cores.sh`](agent/hooks/environment.d/101_julia_num_cores.sh),
sets `JULIA_CPU_THREADS` to `SBA_CPUS_LIMIT`, so existing pipelines keep
working; a `JULIA_CPU_THREADS` set by the step itself wins. A job with neither
is failed with a message: the hook never guesses a width from `nproc`. On
Linux it also sets `OMP_THREAD_LIMIT` to the same value unless the step set
it, so coreutils `nproc` agrees; on macOS, which has no `nproc`, it defines an
`nproc` function that prints `JULIA_CPU_THREADS`. On Linux the cpuset is what
enforces the width: Julia's `--threads auto`, `Sys.EFFECTIVE_CPU_THREADS`,
libuv and `nproc` follow it without any variable.

The KVM guest images carry their own copy of this hook and, on Windows, of the
launcher that passes `SBA_*` on to the agent service; a rebuilt image's hook
fails jobs without `SBA_CPUS_LIMIT`. Roll a new scheduler out first and rebuild
the images afterwards.

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
survives stays leased and charged, shows as `quarantined` in `sba status` and
`sba_slots_quarantined`, and is released when a retried teardown succeeds; a
stop also stops, waits for and reports such jobs. A scheduler does not start
while job cgroups or domains of an earlier one survive.

A job this host reserved but could not run (a failed setup, a guest that did not
boot) is not failed in Buildkite the first time, since finishing it would fail
the build for good and the cause is usually the host. The scheduler skips the
job until its reservation has expired, so another host (or this one, later) can
take it; it shows under "Quarantined jobs" in `sba status`. If the same job fails
on this host a second time, it is finished with exit status -1 and a detail
naming the host and the error.

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

The main entry point is `bin/sba`:

```
❯ ./bin/sba --help
usage: sba [--config PATH] <command> [options]

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
deregisters its stacks. KVM guests get the same treatment from inside the
guest: the agent is stopped, then the job's processes are killed (on Windows,
through console interrupts, and the job's bootstrap is ended with the exit code
the agent reports as -1). Buildkite records these jobs as `agent_stop` too. A
Windows guest whose agent has not exited within ten seconds is shut down
cleanly, as are guests after their job.
Jobs still running after the grace period are force-stopped. If the scheduler has not exited after ten
minutes, the service is killed as before.

Nothing retries the interrupted jobs: pipelines carry no retry rules for them.
Once its kill phase is over, the scheduler writes the jobs it interrupted, and
those that survived the stop, to `stop-report.json` in its `logdir`; jobs that
ended by themselves meanwhile are left out. The commands print one
`bk job retry JOB_ID` line for each, to be run where the Buildkite CLI (`bk`)
has an API token. Jobs whose agent reported `agent_stop`, on the host or in a
KVM guest, can be retried at once; the others (agents or guests that had to be
killed, or whose stop was not confirmed) only once Buildkite shows them failed,
which for a lost agent takes about four minutes. A job whose agent had not been launched yet (the scheduler then no
longer launches it) is listed as reservation only: Buildkite schedules it again
once the reservation expires. One whose agent was launched but not running may
or may not have acquired the job, and is listed on its own. Slots the stop left
held, with a job that had ended but whose teardown failed, are listed last. If the scheduler was killed before writing the report, the commands
fall back to the jobs that were running in its last status snapshot, to be
checked in Buildkite first. Jobs that were only reserved return to the queue
without a retry. `restart` preserves the existing service definition;
`reinstall` regenerates it and reruns host setup before starting the scheduler.
On macOS, `disable` also removes the caffeinate and coredump launchd services
installed by `enable`.


## Configuration

Create a `config.toml` containing `[scheduler]` and one or more runner groups.
Examples live under `platforms/<platform>/`. Unknown keys are errors, so a typo
stops the scheduler from starting instead of being ignored.

### Scheduler

- `logdir`: Scheduler state and job logs; supports relative and `@scratch/`
  paths.
- `total_cpus`: Host CPU pool size (default and maximum: all logical CPUs). On
  macOS this is how wide each job runs. The default counts the efficiency
  cores of Apple Silicon too, which Julia 1.10's `Sys.CPU_THREADS` leaves
  out; set it to the performance cores instead (4 on M1 and M2).
- `total_mem_gib`: Host memory budget in GiB for jobs (default: physical
  memory). It is a workload budget, not the installed memory: leave room for
  the OS and the scheduler. On Macs, where a job is told it has all of it,
  set it below physical memory: 6 on 8 GiB, 13 on 16 GiB, 20 on 24 GiB.
- `min_mem_available_gib`: Admit no job while the host's `MemAvailable` is below
  this many GiB (default: `0`, disabled; Linux only).
- `io_accounting`: Enable the io controller for Linux job cgroups, so their
  resource records have `io.stat`'s bytes and operations (default: `true`).
  It sets no limits or weights, but is not free of effects: with the BFQ I/O
  scheduler, jobs share a disk in proportion to their (equal) default weights,
  and cgroup writeback attributes each job's dirty pages to it. Set it to
  `false` and restart the scheduler if a host's kernel handles that badly
  (e.g. slow teardown after many jobs are killed): at startup, once stale job
  cgroups are gone, the scheduler disables io for job cgroups created from
  then on. If the kernel refuses, it logs an error and reports
  `io_accounting_stuck` in its status and the `sba_io_accounting_stuck` metric.

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
| `sba_io_accounting_stuck` | | 1 when `io_accounting` is off but Linux job cgroups still get the io controller |
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
  (`cpus = cpus_limit = total_cpus`, `mem_gib = mem_limit_gib = total_mem_gib`).

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
  the lowest free slot is used first so warm caches are reused. Required, except
  on macOS, where it defaults to 1.
- `priority`: Admission priority; lower values run first (default: `10`). Only
  needed for groups that must jump the queue, such as launchers.
- `backend`: `linux-sandbox`, `macos-seatbelt`, or `kvm` (default: native).
- `guest`: KVM guest, either `windows` or `freebsd`.
- `platform`: BinaryPlatforms triplet (default: host platform).
- `tags`: Additional Buildkite agent tags. The scheduler adds `os` and `arch`
  (from the platform, or the KVM guest), `config_gitsha`, `cpuset_limited` where
  every job runs in a cpuset, `macos_version` on macOS (`26.1`), and `cpu`: the
  host's CPU model as libuv reports it, lower case, with runs of other
  characters than letters and digits turned into `-` (`apple-m2`,
  `amd-ryzen-9-9950x-16-core-processor`, `neoverse-n1`). KVM groups get the
  host's `cpu`, since their vCPUs run on it. Steps that need one CPU model,
  such as benchmarks, require it with `cpu: "apple-m2"` in their `agents`. A
  tag set here wins over a derived one, except `macos_version` and
  `cpuset_limited`.
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
`bin/sba disable && bin/sba enable`.
