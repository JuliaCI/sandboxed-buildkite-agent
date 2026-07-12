# Sandboxed Buildkite agent

This repository runs Julia's sandboxed Buildkite workers from one host
scheduler.  Each runner group in `config.toml` selects a backend:
`linux-sandbox`, `macos-seatbelt`, or `kvm`.  Linux defaults to
`linux-sandbox`, macOS defaults to `macos-seatbelt`, and KVM groups opt in with
`backend = "kvm"`.

Use `bin/bk` as the entry point:

```
bin/bk --config config.toml scheduler
bin/bk --config config.toml enable
bin/bk start
bin/bk stop
bin/bk status
bin/bk disable
```

The scheduler requires Julia 1.12. `bin/bk` selects the `1.12` juliaup channel.

Example `config.toml` files for each backend live under `platforms/<platform>/`;
copy `config.toml.example` to `config.toml` and pass it with the global
`--config` option before the command.  Each KVM platform keeps a `Makefile` (at
`platforms/<guest>-kvm/Makefile`) for building images; everything else is driven
through `bin/bk`.

`[scheduler] total_cpus` defines the host CPU pool.  Each runner group still
listens to exactly one Buildkite queue, but queues are priority classes rather
than fixed capacity partitions: `job_cpus` declares what one job from that group
costs on this host, `max_jobs` caps concurrency, and lower `priority` values
admit first.  A zero-cost group such as a launch queue must set `max_jobs`.
Linux jobs receive and enforce the allocation with cgroups, KVM jobs size the VM
from it, and macOS jobs receive it cooperatively through `JULIA_CPU_THREADS`.

`bin/bk scheduler --dry-run --once` checks the configuration, polls Buildkite,
and logs the jobs it would select.  It does not register Stacks, reserve jobs,
fetch job environments, prepare backends, or run jobs.

The host lifecycle follows systemd's split between setup, boot persistence, and
runtime.  `bin/bk enable` checks the configuration, runs any host setup, writes
the supervisor service file, and enables it to start on boot.  It does **not**
start the scheduler -- run `bin/bk start` for that.  `enable` refuses to clobber
an already-enabled service; update an existing host with `bin/bk disable` first,
so the running scheduler and its jobs are torn down before the new configuration
is written.

`bin/bk start` starts the enabled service: it rejects if nothing is enabled and
no-ops if the scheduler is already running.  `bin/bk stop` stops the running
scheduler immediately, aborting any job still in flight, but leaves the service
enabled (so a reboot, or a later `bin/bk start`, brings it back).  `bin/bk
status` reports whether the service is enabled and whether it is currently
running.  `bin/bk disable` is the full teardown: it stops the scheduler, cleans
up backend resources, disables boot start, and removes the service file;
re-running it when nothing is enabled is a no-op.

So first-time setup is `bin/bk enable && bin/bk start`, and applying a new
configuration is `bin/bk disable && bin/bk enable && bin/bk start`.

The scheduler uses the Buildkite Stacks API with each runner group's
`buildkite-agent-token`; no separate scheduler REST API token or organization
slug is required.  Groups with different
`secrets_dir` values may serve different clusters on the same host.  Each
queued runner group registers one stack, polls its queue every `poll_interval`
seconds, and keeps polling at least every 30 seconds while busy so the queue
stays connected in Buildkite.  Jobs are reserved before the sandboxed agent
starts with `--acquire-job`.

Cache paths are selected by the host scheduler after it fetches the reserved
job environment.  Trusted and untrusted jobs get separate cache pools.

Each agent receives the hooks from `agent/hooks` and secrets from the configured
`secrets_dir` (default: `agent/secrets`).

Backends:

* `linux-sandbox`: Uses [`Sandbox.jl`](https://github.com/staticfloat/Sandbox.jl/) and Linux user namespaces.  It supports nested sandboxing and optional rootless Docker.

* `macos-seatbelt`: Uses macOS Seatbelt (`sandbox-exec`).  Toolchains are installed on the host; no rootfs support exists.

* `kvm`: Runs one reserved job in a Linux-hosted VM.  The OS disk is
  throwaway; the cache disk is selected by pipeline and trust level.

KVM guests:

* `guest = "windows"` uses the image tooling under `platforms/windows-kvm/`.
* `guest = "freebsd"` uses the image tooling under `platforms/freebsd-kvm/`.
