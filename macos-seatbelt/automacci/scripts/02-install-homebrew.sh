#!/bin/bash
# Allow passwordless sudo for julia (idempotent; the Intel Homebrew installer
# sudos to create /usr/local directories)
grep -q '^julia ALL' /etc/sudoers || \
    bash -c "echo julia ALL = NOPASSWD: ALL >> /etc/sudoers"

# Create .bash_profile for juliaup to modify
sudo -H -u julia touch /Users/julia/.bash_profile

# Setup homebrew. NONINTERACTIVE must be passed *through* sudo (a leading
# NONINTERACTIVE=1 would be scrubbed from the environment). -H (not -i):
# login shells break when the home dir is missing/broken, -H just sets HOME.
sudo -H -u julia NONINTERACTIVE=1 /bin/bash -c \
    "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash"

# Add homebrew to profile. Prefix differs by architecture: /opt/homebrew on
# Apple Silicon, /usr/local on Intel.
if [ "$(uname -m)" = "arm64" ]; then
    BREW=/opt/homebrew/bin/brew
else
    BREW=/usr/local/bin/brew
fi
grep -q 'brew shellenv' /Users/julia/.bash_profile || \
    (echo; echo "eval \"\$(${BREW} shellenv)\"") >> /Users/julia/.bash_profile

# zsh is the login default (and julia's shell), so .zprofile needs it too
# (PR #57 discussion, maleadt's note 2).
sudo -H -u julia touch /Users/julia/.zprofile
grep -q 'brew shellenv' /Users/julia/.zprofile || \
    (echo; echo "eval \"\$(${BREW} shellenv)\"") >> /Users/julia/.zprofile

# The Homebrew installer installs the Command Line Tools and switches the
# active developer directory to them (`xcode-select --switch
# /Library/Developer/CommandLineTools`), silently undoing 00-select-xcode.sh.
# CI needs full Xcode: switch back.
if [ -d /Applications/Xcode.app ]; then
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer/
fi
