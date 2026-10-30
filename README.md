# Sandboxed Buildkite agent

This repository hosts Julia's sandboxed Buildkite workers.


## Architecture

Each host runs one scheduler, configured with runner groups that define a
Buildkite queue, worker tags, sandbox backend, and resource limits. Each group
registers a Buildkite Stack. The scheduler polls for jobs, selects one for an
available worker, reserves it, chooses its cache, and launches an agent with
`--acquire-job` inside the configured sandbox.

### Job selection

Jobs are selected only when their Buildkite agent query rules match the worker's
tags. This follows Buildkite's positive `key=value` and `key=*` matching
semantics; the runner group's Stack handles the queue match.

Matching jobs are admitted by runner-group priority while respecting the host
CPU pool and each group's `max_jobs` limit. CPUs are a budget rather than
specific cores: a Linux job's cgroup gets `cpu.weight = 100 × cpus`, so CPU time
is shared in proportion to requests under contention and idle cores stay
usable; KVM sizes the VM accordingly; and every job is told its parallelism
through `JULIA_CPU_THREADS`.
Within a runner group, jobs with a higher Buildkite job `priority` run first,
and jobs of equal priority run oldest first. Job priorities do not override the
runner-group order, and running jobs are never preempted.

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

- `queues`: Single Buildkite queue served by the group.
- `job_cpus`: Required CPU cost per job. Linux groups may use `0`; macOS and
  KVM groups may not.
- `threads`: `JULIA_CPU_THREADS` given to the group's jobs (default:
  `job_cpus`). Linux also sets `OMP_THREAD_LIMIT` to it so `nproc` agrees. With
  `job_cpus = 0` and no `threads`, the job's hook falls back to `nproc`.
- `mem_gib`: Linux `memory.max` for each job, with swap disabled so a job over
  its limit is OOM-killed rather than paging (default: unlimited). The kernel
  kills the job's largest process and the agent reports the failure; OOM kills
  are also logged before the job's cgroup is removed. Needs `Delegate=memory`, which `bk reinstall` adds.
- `max_jobs`: Concurrency cap. Defaults to `floor(total_cpus / job_cpus)` and is
  required when `job_cpus = 0`.
- `priority`: Admission priority; lower values run first (default: `10`).
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
