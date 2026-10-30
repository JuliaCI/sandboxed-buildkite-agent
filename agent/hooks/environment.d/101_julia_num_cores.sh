#!/usr/bin/env bash

# This defines `JULIA_CPU_THREADS` to be `nproc`, unless the scheduler already
# set it to the job's width.
# If you want a different value, I suggest overriding this value within
# another environment hook in your `environment.local.d` directory,
# which is appropriately `.gitignore`'d to maintain a local config.
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS has no `nproc`. Report the job's width so scripts that size `make -j`
    # from it agree with Julia, and otherwise all logical cores, efficiency cores
    # included.
    function nproc() {
        if [[ -n "${JULIA_CPU_THREADS:-}" ]]; then
            echo "${JULIA_CPU_THREADS}"
        else
            sysctl -n "hw.logicalcpu"
        fi
    }
    export -f nproc
elif [[ "$(uname)" == "FreeBSD" ]]; then
    function nproc() {
        sysctl -n "hw.ncpu"
    }
    export -f nproc
fi

if [[ -z "${JULIA_CPU_THREADS:-}" ]]; then
    export JULIA_CPU_THREADS="$(nproc)"
fi
