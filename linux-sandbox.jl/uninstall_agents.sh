#!/bin/bash

for agent_idx in 0 1 2 3; do
    systemctl --user disable  buildkite-sandbox@$(hostname).${agent_idx}
    systemctl --user stop buildkite-sandbox@$(hostname).${agent_idx}
done

