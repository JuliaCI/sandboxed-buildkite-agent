# Agent secrets

Runtime secrets default to this directory. A runner group may override it with
`secrets_dir`; relative paths are resolved against `config.toml`.

## `buildkite-agent-token`

Required at runtime. The scheduler uses this token for the Buildkite Stacks API
and injects it into the selected agent; it is not baked into images.

```
printf '%s' "$BUILDKITE_AGENT_TOKEN" > agent/secrets/buildkite-agent-token
chmod o-rwx agent/secrets/buildkite-agent-token
```

The scheduler rejects a world-accessible token. Different runner groups may use
different `secrets_dir` values.

## KVM image inputs

KVM image builds also use:

- `credentials.pkrvars.hcl`: A git-ignored Packer variable file containing
  `password = "..."`.
- `ssh_keys/*.pub`: Public keys installed in the guests. Matching private keys
  stay on the host and must not be committed.

These paths are fixed under `agent/secrets`; `secrets_dir` only relocates the
Buildkite token.
