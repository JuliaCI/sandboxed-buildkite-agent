#!/bin/bash
# Create .bash_profile for juliaup to modify
sudo -H -u julia touch /Users/julia/.bash_profile

# Install juliaup. The whole pipeline must run as julia — with a bare
# `sudo -u julia curl ... | sh`, only curl runs as julia; the installer
# itself runs as the caller (root) and puts juliaup in the wrong home.
sudo -H -u julia /bin/bash -c \
    "curl -fsSL https://install.julialang.org | sh -s -- -y"

# CI also wants the LTS channel available (PR #57 discussion, maleadt's
# note 3). 'release' stays the default.
sudo -H -u julia /Users/julia/.juliaup/bin/juliaup add lts || true
