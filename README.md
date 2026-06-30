# Sandboxed Buildkite agent

This repository runs Julia's sandboxed Buildkite workers from one host
scheduler.  Each runner group in `config.toml` selects a backend:
`linux-sandbox`, `macos-seatbelt`, or `kvm`.  Linux defaults to
`linux-sandbox`, macOS defaults to `macos-seatbelt`, and KVM groups opt in with
`backend = "kvm"`.

Use `bin/bk` as the entry point:

```
bin/bk --config config.toml scheduler
bin/bk --config config.toml install
bin/bk stop
bin/bk status
bin/bk start
bin/bk uninstall
bin/bk --config config.toml debug-shell <group>
```

Example `config.toml` files for each backend live under `platforms/<platform>/`;
copy `config.toml.example` to `config.toml` and pass it with the global
`--config` option before the command.  The KVM `base-image/` directories keep a
`Makefile` for building images (`make build`, `make refresh`); everything else
is driven through `bin/bk`.

`bin/bk scheduler --dry-run --once` checks the configuration, polls Buildkite,
and logs the jobs it would select.  It does not register Stacks, reserve jobs,
fetch job environments, prepare backends, or run jobs.

`bin/bk install` writes the host supervisor service, enables it, and starts the
scheduler.  Running it again rejects the request; use `bin/bk uninstall` first
when replacing an installed service.  `bin/bk stop` asks the running scheduler
to drain: it stops claiming new Buildkite jobs, reports how many jobs are still
running, lets them finish, then exits successfully and leaves the installed
service enabled.  Re-running `stop` while a drain is already in progress
reconnects to the same drain status; running it after the scheduler has stopped
is a no-op.  `bin/bk status` reports the scheduler's current control-socket
state, including running job counts when the scheduler is active.  `bin/bk start`
resumes an installed service after a graceful stop.  It rejects if no service is
installed and no-ops if the service is already running.  `bin/bk uninstall` is
the forceful teardown path: it stops the supervisor service, disables it, and
removes the service file.  Re-running `uninstall` when no service file exists
is a no-op.

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
