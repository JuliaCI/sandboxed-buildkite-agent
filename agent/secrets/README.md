# Agent secrets

Runtime secrets default to this directory. A runner group may override it with
`secrets_dir`; relative paths are resolved against `config.toml`.

## `buildkite-agent-token`

Required at runtime: the cluster's agent token. The scheduler uses it for the
Buildkite Stacks API only. Each job's agent gets a job acquisition token minted
for that job instead, so this token never reaches a job, and it is not baked
into images.

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

This path is fixed under `agent/secrets`; `secrets_dir` only relocates the
Buildkite token.
