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
semantics; the Stack handles the queue match, and the job size tags below are
requests to the scheduler rather than rules for the agent.

### Job sizes

Pipeline steps size their jobs with agent tags next to `queue`:

```yaml
agents:
  queue: "build"
  sched_cpus: "4"       # CPUs charged against the host's `total_cpus`
  sched_threads: "16"   # optional, default sched_cpus: JULIA_CPU_THREADS (and nproc); KVM vCPUs
  sched_mem_gib: "40"   # Linux memory.max; KVM guest RAM
```

`sched_cpus` is what the job is charged, and its guaranteed share of the host:
admission keeps the sum of requests within `total_cpus`, and a Linux job's
`cpu.weight` is `100 × cpus`, so even a busy host gives it that many cores while
idle cores stay available to anyone. `sched_threads` is how wide the job runs;
only bursty jobs, such as builds that alternate parallel phases with long serial
ones, set it above `sched_cpus`.

`sched_cpus` and `sched_mem_gib` are required, and all values must be positive
integers: the scheduler fails a job that breaks this with a message saying so,
rather than guessing its size. CPUs are
capped at `total_cpus`; on KVM, vCPUs and guest RAM are capped at the group's
`max_threads` and `max_mem_gib`. Groups with a fixed `size` (launchers, the
secure queue) ignore the tags, and macOS jobs always get the whole host.

On Linux, `sched_mem_gib` is the job's `memory.max`, with swap disabled so a job
over its limit is OOM-killed rather than paging; the kernel kills the job's
largest process, the agent reports the failure, and OOM kills are also logged
before the job's cgroup is removed. On KVM, the guest reserves its RAM plus the
host overhead (30%, at least 8 GiB) against `total_mem_gib`.

CPUs are a budget rather than specific cores: a Linux job's cgroup gets
`cpu.weight = 100 × cpus`, so CPU time is shared in proportion to requests under
contention and idle cores stay usable, and KVM domains get the same weight
through their CPU shares. Every job is told its parallelism through
`JULIA_CPU_THREADS`.

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
- `total_cpus`: Host CPU pool size (default: all logical CPUs).
- `total_mem_gib`: Host memory budget in GiB (default: physical memory).
- `min_mem_available_gib`: Admit no job while the host's `MemAvailable` is below
  this many GiB (default: `0`, disabled; Linux only).

Advanced options are `poll_interval` (15 seconds), `error_sleep` (10 seconds),
`reservation_expiry_seconds` (300 seconds), and `assignment_timeout_seconds`
(12 hours).

### Runner groups

- `queues`: Buildkite queues served by the group, as an array or a
  comma-separated string (default: `["build", "test"]`). Each queue gets its own
  Stack, `julia-<group>-<queue>-<host>` (`julia-<group>-<host>` for a group with
  one queue).
- `size`: Table fixing the size of all the group's jobs, which then ignore the
  `sched_*` tags: `cpus`, `threads` (default: `cpus`) and `mem_gib` (default:
  unlimited on Linux; required on KVM). For queues whose steps are not tagged,
  such as pipeline uploads; `cpus = 0` charges nothing. Not available on macOS,
  where a job always gets the whole host (`cpus = threads = total_cpus`).
- `max_threads`, `max_mem_gib`: KVM only; caps on the vCPUs and guest RAM a
  tagged step can get. These are facts about the host and image, not policy.
- `max_slots`: Number of persistent worker identities (cache directories, and on
  KVM the domain name and cache disk). Slots bound disk use, not concurrency;
  the lowest free slot is used first so warm caches are reused. Defaults to
  `total_cpus` (1 on macOS) and is required with a `size` of `cpus = 0`.
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

Advanced options are `start_rootless_docker` and `stack_key`.


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
