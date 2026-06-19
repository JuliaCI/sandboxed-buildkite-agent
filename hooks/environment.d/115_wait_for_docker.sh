#!/usr/bin/env bash

# Wait for the Docker daemon to be ready before any plugin (e.g. the docker
# plugin's `docker pull`) tries to talk to it.
#
# Why this exists: the Docker daemon's data-root lives on our persistent cache
# drive (`Z:\docker-data`, see 0-03-set-docker-dataroot.ps1).  When that drive
# is slow to come up at boot -- e.g. a heavily fragmented cache-disk image on a
# copy-on-write host filesystem -- dockerd's first start can be killed or stall,
# so the `\\.\pipe\docker_engine` named pipe is not yet listening when a job
# reaches `docker pull`.  Without this gate that races out as the cryptic
#   failed to connect to the docker API at npipe:////./pipe/docker_engine ...
#   open //./pipe/docker_engine: The system cannot find the file specified.
# and fails the build -- mis-attributing a worker/cache-drive problem to Docker.
#
# This is the Windows sibling of 110_windows_cache_drive.sh: it rides out a slow
# daemon start (nudging the service in case the SCM exhausted its restarts) and
# only aborts -- with a clear, cache-drive-attributed message -- if Docker never
# becomes ready.
if [[ "$(uname 2>/dev/null)" == MINGW* ]]; then
    if ! docker version &>/dev/null; then
        echo "--- :docker: Waiting for the Docker daemon to become ready"
        docker_ready=0
        for _ in $(seq 1 60); do        # ~120s budget (60 * 2s)
            if docker version &>/dev/null; then
                docker_ready=1
                break
            fi
            # In case dockerd crashed / was killed and the SCM stopped retrying,
            # nudge it back up (no-op / harmless if it is already starting).
            sc.exe start docker &>/dev/null || true
            sleep 2
        done

        if [[ "${docker_ready}" != "1" ]]; then
            echo "+++ :rotating_light: DOCKER DAEMON NEVER BECAME READY" >&2
            echo "dockerd did not start listening on the docker_engine named pipe within ~120s." >&2
            echo "On this fleet that almost always means slow cache-drive I/O at boot: Docker's" >&2
            echo "data-root lives on the persistent cache disk (Z: / docker-data), which can be" >&2
            echo "slow to mount/read on a fragmented worker image." >&2
            echo "This is a WORKER / cache-disk problem, not a problem with this build." >&2
            echo "See https://github.com/JuliaCI/sandboxed-buildkite-agent/issues/98 for context." >&2
            exit 1
        fi
    fi
fi
