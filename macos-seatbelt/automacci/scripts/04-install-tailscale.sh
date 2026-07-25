#!/bin/bash
# Install Tailscale (open-source CLI variant — the GUI app is per-user and
# wrong for headless CI) and its system daemon. Enrollment against
# https://headscale.julialang.org needs a per-machine preauth key and is NOT
# done here — see enroll-tailscale.sh, run from the host side over SSH.
if [ "$(uname -m)" = "arm64" ]; then
    BREW=/opt/homebrew/bin/brew
else
    BREW=/usr/local/bin/brew
fi

sudo -H -u julia "$BREW" install tailscale

# Register + start the tailscaled launchd system daemon. Do NOT derive the
# path via `brew --prefix` here: this script runs as root from a LaunchDaemon
# with no $HOME, and brew refuses to run ("Error: $HOME must be set").
# brew links tailscaled next to brew itself.
"$(dirname "$BREW")/tailscaled" install-system-daemon
