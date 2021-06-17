#!/bin/bash
## Example invocation to show how to launch 4 agents on amdci7

# Build the rootfs, generate the systemd config, etc...
julia --project build_systemd_config.jl

# Enable four agents
systemctl --user enable buildkite-sandbox@amdci7.0
systemctl --user enable buildkite-sandbox@amdci7.1
systemctl --user enable buildkite-sandbox@amdci7.2
systemctl --user enable buildkite-sandbox@amdci7.3

# Start them all
systemctl --user restart buildkite-sandbox@amdci7.0
systemctl --user restart buildkite-sandbox@amdci7.1
systemctl --user restart buildkite-sandbox@amdci7.2
systemctl --user restart buildkite-sandbox@amdci7.3
