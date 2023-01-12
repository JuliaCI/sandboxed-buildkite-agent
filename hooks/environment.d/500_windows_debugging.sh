#!/usr/bin/env bash

LOG_FILES=(
    # This log file should get cleared out every boot
    "${HOME}/startup.log"
    # This log file should persist as long as the cache drive does
    "${BUILDKITE_PLUGIN_JULIA_CACHE_DIR}/startup.log"
)

function log() {
    # Read the message in from stdin
    MSG="$(</dev/stdin)"

    # Write it out to log files
    for LOG_FILE in "${LOG_FILES[@]}"; do
        cat >"${LOG_FILE}" <<<"${MSG}"
    done

    # Finally, spit it out to the console
    cat <<<"${MSG}"
}

function debug_startup() {
    echo "--- Startup Debugging"
    # First, say who and when we are
    hostname | log
    date | log

    # Next, show some buildkite data
    echo "buildkite processes:"
    ps --windows | grep buildkite | log
    echo "buildkite variables:"
    set | grep -i buildkite | log
}


if [[ "$(uname 2>/dev/null)" == MINGW* ]]; then
    debug_startup
fi
