#!/bin/bash
# Create .bash_profile for juliaup to modify
sudo -i -u julia touch /Users/julia/.bash_profile

# Install juliaup
sudo -i -u julia curl -fsSL https://install.julialang.org | sh -s -- -y
