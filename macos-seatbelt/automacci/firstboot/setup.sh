#!/bin/bash
# Julia CI first-boot setup. Delivered by firstboot.pkg and run as root by the
# org.julialang.ci.firstboot LaunchDaemon on the first boot after deployment.
# Logs to /var/log/juliaci-firstboot.log (tail it to watch progress).
# Idempotent: to re-run after fixing something, reinstall the pkg (restores
# payload + LaunchDaemon), `rm /private/var/juliaci/.done`, reboot.
BASE=/private/var/juliaci
exec >>/var/log/juliaci-firstboot.log 2>&1
set -x

finish() {
    rm -f /Library/LaunchDaemons/org.julialang.ci.firstboot.plist
}
if [ -e "$BASE/.done" ]; then
    finish
    exit 0
fi

# Belt-and-suspenders: the pkg postinstall also does this, but the OS install
# rebuilds /var/db and can drop a pre-placed copy; without it the machine
# shows Setup Assistant while this script runs behind it.
touch /private/var/db/.AppleSetupDone

# config provides SERVER_URL and (optionally) XCODE_ASSET, COMPUTER_NAME_PREFIX
. "$BASE/config"

# Wait for the network (up to 10 minutes). Probe a file that actually exists
# on the deploy server (bare "/" 404s on index-less file servers); fall back
# to apple.com in case the server is only needed for Xcode.
for _ in $(seq 1 60); do
    curl -fsI --max-time 5 "$SERVER_URL/firstboot.pkg" >/dev/null 2>&1 && break
    curl -fsI --max-time 5 https://www.apple.com/ >/dev/null 2>&1 && break
    sleep 10
done

# Passwordless sudo for julia (needed by the setup scripts and by Homebrew on
# Intel, where the installer sudos to create /usr/local directories).
grep -q '^julia ALL' /etc/sudoers || echo 'julia ALL = NOPASSWD: ALL' >>/etc/sudoers

# Create the julia user (uid 601 and zsh shell match the old MDS workflow).
# NOTE (Apple Silicon): a user created here, before any Setup Assistant user
# exists, may not hold a secure token / volume ownership. CI doesn't need
# one; OS *upgrades* on such machines are easiest done by redeploying.
# Existence check MUST be the exact record path, not `id julia`: macOS
# resolves user names against full names case-insensitively, so a human
# account with full name "Julia ..." makes `id julia` succeed and every
# julia-targeting command silently operate on the wrong user (observed in
# the field with a throwaway Setup Assistant account).
if ! dscl . -read /Users/julia UniqueID >/dev/null 2>&1; then
    sysadminctl -addUser julia -fullName "Julia Hub" -UID 601 -shell /bin/zsh \
        -admin -password "$(cat "$BASE/password")"
fi
dscl . -read /Users/julia UniqueID >/dev/null 2>&1 || \
    echo "JULIACI FATAL: julia user creation failed"
# Guarantee the home dir exists ourselves — createhomedir has been seen not
# delivering (field: /Users/julia absent, every later script broke or leaked
# into the invoking user's home via a failing 'sudo -i' login shell).
if [ ! -d /Users/julia ]; then
    mkdir -p /Users/julia
    chown julia:staff /Users/julia
    createhomedir -c -u julia || true
    chown -R julia:staff /Users/julia
fi

# Suppress julia's per-user first-login Setup Assistant (Apple ID, Siri,
# privacy panes — the MDS workflow's shouldSkipPrivacySetup). Without this,
# auto-login walks straight into those panes on first boot.
SA_PLIST=/Users/julia/Library/Preferences/com.apple.SetupAssistant
mkdir -p /Users/julia/Library/Preferences
for k in DidSeeCloudSetup DidSeeSiriSetup DidSeePrivacy DidSeeAppearanceSetup \
         DidSeeAvatarSetup DidSeeScreenTime DidSeeTouchIDSetup \
         DidSeeAccessibility DidSeeActivationLock DidSeeApplePaySetup \
         DidSeeTrueTonePrivacy; do
    defaults write "$SA_PLIST" "$k" -bool true
done
defaults write "$SA_PLIST" LastSeenCloudProductVersion "$(sw_vers -productVersion)"
defaults write "$SA_PLIST" LastSeenBuddyBuildVersion "$(sw_vers -buildVersion)"
chown -R julia:staff /Users/julia/Library

# Auto-login as julia (CI jobs want a real GUI session; matches the MDS
# workflow's shouldAutologin). /etc/kcpassword is the password XORed with
# Apple's fixed 11-byte key, NUL-terminated, padded to a multiple of 12.
# Trivially reversible by design — acceptable for CI machines, and it's what
# every deployment tool does. Requires FileVault off (it is, fresh install).
kcpassword_encode() {
    local pw="$1"
    local key=(125 137 82 35 210 188 221 234 163 185 31)
    local out="" i c n=${#pw}
    for (( i=0; i<n; i++ )); do
        c=$(printf '%d' "'${pw:i:1}")
        out+=$(printf '\\%03o' $(( c ^ key[i % 11] )))
    done
    out+=$(printf '\\%03o' $(( key[i % 11] )) ); i=$((i+1))
    while (( i % 12 != 0 )); do
        out+=$(printf '\\%03o' $(( key[i % 11] )) ); i=$((i+1))
    done
    printf '%b' "$out"
}
if [ -f "$BASE/password" ]; then
    kcpassword_encode "$(cat "$BASE/password")" > /etc/kcpassword
    chown root:wheel /etc/kcpassword
    chmod 600 /etc/kcpassword
    defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string julia
fi
rm -f "$BASE/password"

# Computer name: <prefix>-<serial>, matching the MDS workflow's
# honeycrisp-{{serial_number}} convention.
SERIAL="$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4}')"
if [ -n "$SERIAL" ]; then
    NAME="${COMPUTER_NAME_PREFIX:-honeycrisp}-${SERIAL}"
    scutil --set ComputerName "$NAME"
    scutil --set HostName "$NAME"
    scutil --set LocalHostName "$NAME"
fi

# Remote access: SSH and Screen Sharing.
systemsetup -setremotelogin on || launchctl load -w /System/Library/LaunchDaemons/ssh.plist
launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist || true

# Never sleep, in any form; restart after power failure. caffeinate alone has
# been seen losing to power management on macOS 15 (PR #57 discussion), hence
# the full battery of settings; some keys don't exist on some hardware.
pmset -a sleep 0 displaysleep 0 disksleep 0 || true
pmset -a hibernatemode 0 || true
pmset -a autopoweroff 0 || true
pmset -a standby 0 || true
pmset -a lidwake 0 || true
pmset -a autorestart 1 womp 1 || true

# CI machines are wired; kill Wi-Fi so machines can't wander onto it
# (PR #57 discussion, staticfloat's note 3).
WIFIDEV="$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2}')"
[ -n "$WIFIDEV" ] && networksetup -setairportpower "$WIFIDEV" off || true

# Fetch and unpack Xcode if the image was built with one.
if [ -n "${XCODE_ASSET:-}" ] && [ ! -d /Applications/Xcode.app ]; then
    cd /Applications
    case "$XCODE_ASSET" in
        *.xip)
            curl -fO "$SERVER_URL/$XCODE_ASSET"
            xip --expand "$XCODE_ASSET"   # slow: ~30+ minutes
            rm -f "$XCODE_ASSET"
            # xip may expand to a versioned name; normalize
            [ -d Xcode.app ] || mv Xcode*.app Xcode.app
            ;;
        *.tar)          curl -f "$SERVER_URL/$XCODE_ASSET" | tar -x ;;
        *.tar.gz|*.tgz) curl -f "$SERVER_URL/$XCODE_ASSET" | tar -xz ;;
    esac
    cd /
fi

# Run the setup scripts in order (00-select-xcode, 01-clone, 02-homebrew,
# 03-juliaup, 04-tailscale, 05-ssh-key). Keep going on failure — a partially
# set up machine that answers SSH beats one that never comes up; failures are
# visible in the log.
FAILED=""
for s in "$BASE"/scripts/*.sh; do
    bash "$s" || FAILED="$FAILED $s"
done

# The setup scripts run installers as root that occasionally leave
# root-owned droppings in julia's home (PR #57 discussion, staticfloat's
# note 2); sweep ownership at the end.
chown -R julia /Users/julia || true

[ -n "$FAILED" ] && echo "JULIACI SETUP FAILURES:$FAILED"
touch "$BASE/.done"
finish
echo "JULIACI SETUP COMPLETE"

# One reboot so loginwindow re-reads autologin/.AppleSetupDone — lands on
# julia's desktop with no operator touches. No loop risk: .done short-
# circuits the next run.
reboot
