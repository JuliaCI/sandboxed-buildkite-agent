#!/usr/bin/env bash

# Check to make sure our cache drives are loaded.
if [[ "$(uname 2>/dev/null)" == MINGW* ]]; then
    if [[ ! -d /c/cache ]] || [[ ! -d /z ]]; then
        echo "+++ 🚨🚨🚨 CACHE DRIVE MISSING 🚨🚨🚨" >&2
        echo "For some reason, Windows has decided not to mount our cache drive under either C:\\cache or Z:" >&2
        echo "This is a FATAL failure, and as such, this build will be aborted." >&2
        echo "See https://github.com/JuliaCI/sandboxed-buildkite-agent/issues/98 for more details." >&2
        echo "Go alert @staticfloat on the #ci-dev channel on the JuliaLang slack to hopefully get this fixed." >&2
        exit 1
    fi
fi

