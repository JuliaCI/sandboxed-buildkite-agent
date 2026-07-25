#!/bin/bash
# Enroll a deployed CI mac into https://headscale.julialang.org.
# Run from YOUR machine (host side) — enrollment credentials must not be
# baked into the deployment image.
#
# usage: ./enroll-tailscale.sh <machine-ip> [-- extra tailscale-up flags]
#
# Auth, either of:
#   TS_AUTHKEY=<preauth key>  — non-interactive (headscale admin creates one:
#                               `headscale preauthkeys create --user <u>`)
#   no TS_AUTHKEY             — interactive: tailscale prints a registration
#                               URL; send it to the headscale admin
#
# Machines advertise tag:julialang-ci (per the headscale admin) and keep the
# default tailnet hostname = the computer name, i.e. <prefix>-<serial>.
#
# Self-healing: installs tailscale + the system daemon if the machine was
# imaged before 04-install-tailscale.sh (or hit its early bugs).
set -euo pipefail

[ $# -ge 1 ] || { sed -n '2,17p' "$0"; exit 1; }
IP="$1"; shift
[ "${1:-}" = "--" ] && shift
EXTRA_FLAGS=("$@")

LOGIN_SERVER=https://headscale.julialang.org
TAGS="tag:julialang-ci"

# Self-heal: install the formula and/or register the system daemon if
# missing. tailscaled is linked next to brew — do not use `brew --prefix`
# under sudo, root has no $HOME for brew.
ssh "julia@$IP" '
    set -e
    BREW=$([ "$(uname -m)" = arm64 ] && echo /opt/homebrew/bin/brew || echo /usr/local/bin/brew)
    "$BREW" list tailscale >/dev/null 2>&1 || "$BREW" install tailscale
    if [ ! -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
        sudo "$(dirname "$BREW")/tailscaled" install-system-daemon
    fi
'

if [ -n "${TS_AUTHKEY:-}" ]; then
    # Ship the key via stdin into a root-only file and use --auth-key file:
    # so it never appears in argv/ps on either end; removed afterwards.
    printf '%s' "$TS_AUTHKEY" | ssh "julia@$IP" '
        set -e
        BREW=$([ "$(uname -m)" = arm64 ] && echo /opt/homebrew/bin/brew || echo /usr/local/bin/brew)
        TS="$(dirname "$BREW")/tailscale"
        sudo sh -c "umask 077; cat > /private/var/root/ts.authkey"
        sudo "$TS" up --login-server '"$LOGIN_SERVER"' \
            --advertise-tags '"$TAGS"' \
            --auth-key file:/private/var/root/ts.authkey '"${EXTRA_FLAGS[*]:-}"'
        sudo rm -f /private/var/root/ts.authkey
        sudo "$TS" status | head -5
    '
else
    # Interactive: prints a URL to hand to the headscale admin.
    ssh -t "julia@$IP" '
        BREW=$([ "$(uname -m)" = arm64 ] && echo /opt/homebrew/bin/brew || echo /usr/local/bin/brew)
        TS="$(dirname "$BREW")/tailscale"
        sudo "$TS" up --login-server '"$LOGIN_SERVER"' \
            --advertise-tags '"$TAGS"' '"${EXTRA_FLAGS[*]:-}"'
        sudo "$TS" status | head -5
    '
fi
echo "Enrolled $IP on $LOGIN_SERVER"
