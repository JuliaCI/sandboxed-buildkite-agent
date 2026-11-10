#!/usr/bin/env bash

# Say how the scheduler admitted the job: its size and where that came from,
# what it was charged against the host's budget, and how long it waited. The
# scheduler renders the line (`SBA_ADMISSION`); without it (an older scheduler
# or guest image) print nothing. Last of these hooks, so that the section holds
# only this line.
if [[ -n "${SBA_ADMISSION:-}" ]]; then
    echo "~~~ Admission"
    printf '%s\n' "${SBA_ADMISSION}"
fi
