#!/bin/bash

# Split into four panes
tmux split-window -v
tmux split-window -h -t 0
tmux split-window -h -t 2

# Start an agent in each
for idx in 0 1 2 3; do
    tmux send-keys -t ${idx} "while [ true ]; do julia --project launch_agent.jl 'sandbox_agent${idx}'; sleep 1; done" enter
done
