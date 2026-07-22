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
CPU pool and each group's `max_jobs` limit. Linux enforces CPU allocations with
cgroups, KVM sizes the VM accordingly, and macOS sets `JULIA_CPU_THREADS`.

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
  status        show scheduler service state and the latest scheduler snapshot
  logs          show scheduler or per-slot backend logs
  disable       stop the scheduler service, disable it, and remove it

Global options:
  --config PATH   path to the config file (default: ./config.toml)
  -h, --help      show this help message
```


## Configuration

Create a `config.toml` containing `[scheduler]` and one or more runner groups.
Examples live under `platforms/<platform>/`.

### Scheduler

- `logdir`: Scheduler state and job logs; supports relative and `@scratch/`
  paths.
- `total_cpus`: Host CPU pool size (default: all logical CPUs).

Advanced options are `poll_interval` (15 seconds), `error_sleep` (10 seconds),
`reservation_expiry_seconds` (300 seconds), and `assignment_timeout_seconds`
(six hours).

### Runner groups

- `queues`: Single Buildkite queue served by the group.
- `job_cpus`: Required CPU cost per job. Linux groups may use `0`; macOS and
  KVM groups may not.
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
