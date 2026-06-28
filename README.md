# Sandboxed Buildkite agent

This repository runs Julia's sandboxed Buildkite workers from one host
scheduler.  Each runner group in `config.toml` selects a backend:
`linux-sandbox`, `macos-seatbelt`, or `kvm`.  Linux defaults to
`linux-sandbox`, macOS defaults to `macos-seatbelt`, and KVM groups opt in with
`backend = "kvm"`.

Use `bin/bk` as the entry point:

```
bin/bk scheduler --config config.toml
bin/bk install --config config.toml
bin/bk uninstall
bin/bk debug-shell --config config.toml <group>
```

`bin/bk scheduler --dry-run --once` checks the configuration, polls Buildkite,
and logs the jobs it would select.  It does not register Stacks, reserve jobs,
fetch job environments, prepare backends, or run jobs.

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

Each agent receives the hooks from `hooks` and secrets from the configured
`secrets_dir` (default: `secrets`).

Backends:

* `linux-sandbox`: Uses [`Sandbox.jl`](https://github.com/staticfloat/Sandbox.jl/) and Linux user namespaces.  It supports nested sandboxing and optional rootless Docker.

* `macos-seatbelt`: Uses macOS Seatbelt (`sandbox-exec`).  Toolchains are installed on the host; no rootfs support exists.

* `kvm`: Runs one reserved job in a Linux-hosted VM.  The OS disk is
  throwaway; the cache disk is selected by pipeline and trust level.

KVM guests:

* `guest = "windows"` uses the image tooling under `windows-kvm/`.
* `guest = "freebsd"` uses the image tooling under `freebsd-kvm/`.
