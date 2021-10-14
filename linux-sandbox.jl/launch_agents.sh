#!/bin/bash
## Example invocation to show how to launch 4 agents named by the current hostname

# Build the rootfs, generate the systemd config, etc...
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.build()'
julia --project build_systemd_config.jl $@

# Enable four agents
systemctl --user daemon-reload
for agent_idx in 0 1 2 3; do
    systemctl --user enable  buildkite-sandbox@$(hostname).${agent_idx}
    systemctl --user restart buildkite-sandbox@$(hostname).${agent_idx}
done
