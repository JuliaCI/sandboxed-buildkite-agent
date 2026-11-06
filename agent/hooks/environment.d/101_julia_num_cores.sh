#!/usr/bin/env bash

# Size the job from the scheduler's grant: `JULIA_CPU_THREADS` is the number of
# CPUs the job may run on (`SBA_CPUS_LIMIT`), unless the step sets it itself.
# Every backend exports `SBA_CPUS_LIMIT`; a job without it did not come from
# this scheduler, and is failed rather than sized from the machine.
# To override the value on one host, use an environment hook in the
# `environment.local.d` directory, which is `.gitignore`'d for local config.
if [[ -z "${JULIA_CPU_THREADS:-}" ]]; then
    if [[ "${SBA_CPUS_LIMIT:-}" =~ ^[1-9][0-9]*$ ]]; then
        export JULIA_CPU_THREADS="${SBA_CPUS_LIMIT}"
    else
        echo "This job has no CPU grant: SBA_CPUS_LIMIT is '${SBA_CPUS_LIMIT:-}', not a positive integer, and JULIA_CPU_THREADS is not set." >&2
        echo "The sandboxed-buildkite-agent scheduler exports SBA_CPUS_LIMIT to every job; a host or guest image without it needs a newer scheduler." >&2
        exit 1
    fi
fi

case "$(uname)" in
    Darwin)
        # macOS has no `nproc`. Report the job's width, so scripts that size
        # `make -j` from it agree with Julia.
        function nproc() {
            echo "${JULIA_CPU_THREADS}"
        }
        export -f nproc
        ;;
    Linux)
        # Makes coreutils `nproc` report the same width (and caps OpenMP).
        export OMP_THREAD_LIMIT="${OMP_THREAD_LIMIT:-${JULIA_CPU_THREADS}}"
        ;;
    # FreeBSD (13.2 and later) and Git Bash on Windows have their own `nproc`,
    # which counts the guest's vCPUs: the job's width.
esac
