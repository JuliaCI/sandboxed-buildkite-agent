#!/bin/bash

# This defines `JULIA_CPU_THREADS` to be `nproc`.
# If you want a different value, I suggest overriding this value within
# another environment hook in your `environment.local.d` directory,
# which is appropriately `.gitignore`'d to maintain a local config.
if [[ "$(uname)" == "Darwin" ]]; then
    # If we're building on a big.LITTLE architecture, only use the
    # performance cores
    if [[ $(sysctl -n hw.nperflevels 2>/dev/null || true) -gt 1 ]]; then
        function nproc() {
            sysctl -n "hw.perflevel0.logicalcpu"
        }
    else
        function nproc() {
            sysctl -n "hw.ncpu"
        }
    fi
    export -f nproc
fi

export JULIA_CPU_THREADS="$(nproc)"
