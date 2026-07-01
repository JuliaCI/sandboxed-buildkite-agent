# Agent secrets

This directory holds the secrets the host scheduler and its sandboxed agents
need. Only the files documented below are used; git ignores everything else
(see `.gitignore`).

A runner group's secrets directory defaults to this directory (`agent/secrets`),
but a group may point elsewhere with `secrets_dir` in `config.toml` (a relative
path is resolved against the config file's directory, for example an out-of-tree
locked-down store). The `secrets_dir` override applies only to the agent token
below; the KVM image tooling always reads `ssh_keys/` from this repository
directory.

## `buildkite-agent-token` (required)

The Buildkite agent token for the cluster this host serves. It is:

- read on the host by the scheduler to authenticate to the Buildkite Stacks API
  (stack registration, job polling and reservation);
- injected into every sandboxed agent as the `BUILDKITE_AGENT_TOKEN` environment
  variable, not mounted as a file;
- used by the KVM image and worker tooling under `platforms/` (via
  `platforms/common.mk`) to register guest agents.

Create it with the token from the Buildkite cluster's "Agents" page:

```
printf '%s' "$BUILDKITE_AGENT_TOKEN" > agent/secrets/buildkite-agent-token
chmod o-rwx agent/secrets/buildkite-agent-token
```

It must not be world-readable, -writable, or -executable; the scheduler refuses
to start otherwise. This file is git-ignored, so never commit it.

## `ssh_keys/` (required for KVM guests only)

Public keys (`*.pub`) that authorize this host to SSH into the Windows and
FreeBSD KVM guest VMs. Only the KVM image-build tooling under
`platforms/windows-kvm/` and `platforms/freebsd-kvm/` reads them (Packer installs
them into the guest's `authorized_keys`); the agent runtime does not, and they
are never mounted into a sandbox.

The public keys are committed here; the matching private keys live on the
operating host and do not belong in this repository. Hosts that run only the
`macos-seatbelt` or `linux-sandbox` backends do not need this directory.
