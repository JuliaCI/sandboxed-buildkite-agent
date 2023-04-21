#!/bin/bash
# Allow passwordless sudo for julia
bash -c "echo julia ALL = NOPASSWD: ALL >> /etc/sudoers"

# Create .bash_profile for juliaup to modify
sudo -i -u julia touch /Users/julia/.bash_profile

# Setup homebrew
NONINTERACTIVE=1 sudo -i -u julia /bin/bash -c "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh | /bin/bash"

# Add homebrew to profile
(echo; echo 'eval "$(/opt/homebrew/bin/brew shellenv)"') >> /Users/julia/.bash_profile