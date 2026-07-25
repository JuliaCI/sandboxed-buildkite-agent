#!/bin/bash
sudo -H -u julia mkdir -p /Users/julia/src/
[ -d /Users/julia/src/sandboxed-buildkite-agent ] || \
    sudo -H -u julia git clone https://github.com/JuliaCI/sandboxed-buildkite-agent /Users/julia/src/sandboxed-buildkite-agent
