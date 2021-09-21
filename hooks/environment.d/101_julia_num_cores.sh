#!/bin/bash

# This defines `JULIA_NUM_THREADS` to be `nproc` up to a maximum of `16`.
# If you want a different value, I suggest overriding this value within
# another environment hook in your `environment.local.d` directory,
# which is appropriately `.gitignore`'d to maintain a local config.
JULIA_NUM_THREADS=$(($(nproc) > 16 ? 16 : $(nproc)))
export JULIA_CPU_THREADS=${JULIA_NUM_THREADS}
