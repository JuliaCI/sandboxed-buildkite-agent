#!/usr/bin/env bash

function log() {
    # Read the message in from stdin
    MSG="$(</dev/stdin)"

    # Write it out to log files
    for LOG_FILE in "${LOG_FILES[@]}"; do
        LOG_FILE_DIR="$(dirname "${LOG_FILE}")"
        mkdir -p "${LOG_FILE_DIR}"
        cat >>"${LOG_FILE}" <<<"${MSG}"
    done
}

function debug_startup() {
    # First, say who and when we are
    hostname | log
    date | log

    # Next, show some buildkite data
    echo "buildkite processes:" | log
    ps --windows | grep 'buildkite' | log
    echo "buildkite variables:" | log
    set | grep -i 'BUILDKITE_.*_ID=' | log
    set | grep -i 'BUILDKITE_AGENT_PID' | log
    set | grep -i 'BUILDKITE_BUILD_NUMBER' | log


    # At the end, spit the log out:
    for LOG_FILE in "${LOG_FILES[@]}"; do
        echo "--- Startup Debugging (${LOG_FILE})"
        cat "${LOG_FILE}"
    done
    echo "--- rest of startup"
}


# DISABLED: We don't need this right now, let's clean up our build logs a bit
if false #[[ "$(uname 2>/dev/null)" == MINGW* ]]; then
    LOG_FILES=(
        # This log file should get cleared out every boot
        "${HOME}/startup.log"
        # This log file should persist as long as the cache drive does
        "$(cygpath "${BUILDKITE_PLUGIN_JULIA_CACHE_DIR}")/startup.log"
    )

    debug_startup
fi
