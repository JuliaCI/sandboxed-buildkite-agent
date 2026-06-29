#!/usr/bin/env bash

# JuliaLang/julia has ~40k refs, so a fresh `git clone --mirror` (as performed by
# buildkite-agent's git-mirrors feature) sends a >2 MiB "want" list. Once the POST
# body exceeds git's http.postBuffer (default 1 MiB), git falls back to
# Transfer-Encoding: chunked, which GitHub's smart-HTTP endpoint rejects with
# `error: RPC failed; HTTP 400`. Raise the buffer so the request stays a single
# Content-Length POST. Injected via GIT_CONFIG_* so it applies to the agent's own
# checkout/mirror git invocations, appending rather than clobbering any existing keys.
# 16 MiB comfortably exceeds the ~2 MiB want-list; it caps the buffer, git only
# allocates the actual body size.
idx="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${idx}=http.postBuffer"
export "GIT_CONFIG_VALUE_${idx}=16777216"
export GIT_CONFIG_COUNT="$((idx + 1))"
