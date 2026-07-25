#!/bin/bash
# Build the Julia CI mac deployment image.
#
# Replaces the earlier MDS-based flow (MDS went paid in ~2024; see README).
# Must run on macOS — uses pkgbuild/productbuild/hdiutil.
#
# Produces, in --output-dir:
#   juliaci.dmg      serve over HTTP; contains the macOS installer app,
#                    firstboot.pkg, and the run / run-as launch scripts
#   <Xcode asset>    (optional) Xcode archive fetched by machines at first boot
#
# The whole output dir must then be served at the URL given via --server, by a
# server that supports HTTP range requests (hdiutil needs them; python3 -m
# http.server does NOT — use caddy, nginx, or `npx http-server`).
set -euo pipefail

usage() {
    cat <<'EOF'
usage: JULIA_PASSWORD=... ./build-image.sh \
           --installer "/path/Install macOS <Name>.app" \
           --server http://<host>[:port] \
           [--xcode /path/Xcode.app | /path/Xcode.xip] \
           [--output-dir out]

  JULIA_PASSWORD  (env) password for the 'julia' user; used for SSH afterwards
  --installer     full macOS installer app. Obtain with
                  `softwareupdate --fetch-full-installer --full-installer-version <ver>`
                  or mist-cli (https://github.com/ninxsoft/mist-cli)
  --server        base URL where --output-dir will be served; machines fetch
                  the Xcode asset from here at first boot
  --xcode         Xcode.app (packed into a .tar) or an Xcode.xip (copied as-is;
                  expanded on the target, which is slower per-machine)
  --output-dir    default: ./out
EOF
    exit 1
}

INSTALLER="" SERVER="" XCODE="" OUTDIR=out PKG_ONLY="" XCODE_ASSET_OVERRIDE="" NAME_PREFIX=honeycrisp
while [ $# -gt 0 ]; do
    case "$1" in
        --installer)   INSTALLER="$2"; shift 2;;
        --server)      SERVER="${2%/}"; shift 2;;
        --xcode)       XCODE="$2"; shift 2;;
        --output-dir)  OUTDIR="$2"; shift 2;;
        # Rebuild only firstboot.pkg into --output-dir (seconds, not the
        # ~30min dmg recompress). --xcode-asset names an already-served
        # Xcode archive to reference in the pkg config without repacking.
        --pkg-only)    PKG_ONLY=1; shift;;
        --xcode-asset) XCODE_ASSET_OVERRIDE="$2"; shift 2;;
        # machines name themselves <prefix>-<serial>; default matches the
        # MDS-era honeycrisp-{{serial_number}} convention
        --name-prefix) NAME_PREFIX="$2"; shift 2;;
        *) usage;;
    esac
done

[ -n "$SERVER" ] || usage
if [ -z "$PKG_ONLY" ]; then
    [ -n "$INSTALLER" ] || usage
    [ -d "$INSTALLER" ] || { echo "error: installer app not found: $INSTALLER"; exit 1; }
    [ -x "$INSTALLER/Contents/Resources/startosinstall" ] || {
        echo "error: $INSTALLER has no Contents/Resources/startosinstall —"
        echo "       it must be a *full* installer app, not a stub"; exit 1; }
fi
[ -n "${JULIA_PASSWORD:-}" ] || { echo "error: set JULIA_PASSWORD in the environment"; exit 1; }

SRCDIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/juliaci-image.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTDIR"

# ---- Xcode asset ------------------------------------------------------------
XCODE_ASSET="$XCODE_ASSET_OVERRIDE"
if [ -n "$XCODE" ] && [ -z "$XCODE_ASSET_OVERRIDE" ]; then
    case "$XCODE" in
        *.xip)
            XCODE_ASSET="$(basename "$XCODE")"
            echo "==> Copying $XCODE_ASSET"
            cp -c "$XCODE" "$OUTDIR/" 2>/dev/null || cp "$XCODE" "$OUTDIR/";;
        *.app)
            XCODE_ASSET="Xcode.app.tar"
            echo "==> Packing $XCODE into $XCODE_ASSET (uncompressed; it's for the LAN)"
            tar -cf "$OUTDIR/$XCODE_ASSET" -C "$(dirname "$XCODE")" "$(basename "$XCODE")";;
        *) echo "error: --xcode must be an .app or a .xip"; exit 1;;
    esac
fi

# ---- firstboot.pkg ----------------------------------------------------------
echo "==> Building firstboot.pkg"
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD/private/var/juliaci/scripts" "$PAYLOAD/Library/LaunchDaemons"
cp "$SRCDIR/firstboot/setup.sh"                          "$PAYLOAD/private/var/juliaci/"
cp "$SRCDIR/firstboot/org.julialang.ci.firstboot.plist"  "$PAYLOAD/Library/LaunchDaemons/"
cp "$SRCDIR"/scripts/*.sh                                "$PAYLOAD/private/var/juliaci/scripts/"
printf '%s' "$JULIA_PASSWORD" > "$PAYLOAD/private/var/juliaci/password"
cat > "$PAYLOAD/private/var/juliaci/config" <<EOF
SERVER_URL="$SERVER"
XCODE_ASSET="$XCODE_ASSET"
COMPUTER_NAME_PREFIX="$NAME_PREFIX"
EOF
chmod 755 "$PAYLOAD/private/var/juliaci/setup.sh" "$PAYLOAD"/private/var/juliaci/scripts/*.sh
chmod 600 "$PAYLOAD/private/var/juliaci/password"
chmod 644 "$PAYLOAD/Library/LaunchDaemons/org.julialang.ci.firstboot.plist"

# Copy pkg scripts and force the exec bit — a checkout with wrong modes must
# not produce a pkg whose postinstall PackageKit can't run (it reports that
# as "The file "postinstall" doesn't exist", and the machine lands in Setup
# Assistant because .AppleSetupDone was never touched).
PKGSCRIPTS="$WORK/pkgscripts"
mkdir -p "$PKGSCRIPTS"
cp "$SRCDIR"/firstboot/pkgscripts/* "$PKGSCRIPTS/"
chmod 755 "$PKGSCRIPTS"/*

pkgbuild --root "$PAYLOAD" \
         --scripts "$PKGSCRIPTS" \
         --identifier org.julialang.ci.firstboot \
         --version 1.0 \
         --install-location / \
         --ownership recommended \
         "$WORK/firstboot-component.pkg"
# startosinstall --installpackage requires a distribution ("product archive")
# package, so wrap the component pkg. NOTE: the Intel 'run' path applies the
# pkg itself from recovery and doesn't care about signing, but the Apple
# Silicon 'run-as' path goes through startosinstall --installpackage, which
# silently drops packages it doesn't like — sign with a Developer ID
# Installer identity if you have one:
#   PKG_SIGN_ID="Developer ID Installer: <name> (<team>)"
if [ -n "${PKG_SIGN_ID:-}" ]; then
    productbuild --sign "$PKG_SIGN_ID" \
        --package "$WORK/firstboot-component.pkg" "$WORK/firstboot.pkg"
else
    productbuild --package "$WORK/firstboot-component.pkg" "$WORK/firstboot.pkg"
fi

if [ -n "$PKG_ONLY" ]; then
    cp "$WORK/firstboot.pkg" "$OUTDIR/firstboot.pkg"
    cat <<EOF

Done: $OUTDIR/firstboot.pkg (dmg untouched). Machines can use it via:
  recovery:  SERVER=$SERVER bash run      (run fetches the fresh pkg)
  booted OS: curl -O $SERVER/firstboot.pkg && sudo installer -pkg firstboot.pkg -target /
EOF
    exit 0
fi

# ---- disk image -------------------------------------------------------------
echo "==> Building juliaci.dmg (this copies the ~15GB installer; be patient)"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$INSTALLER" "$STAGE/"
cp "$WORK/firstboot.pkg" "$STAGE/"
cp "$SRCDIR/deploy/run" "$SRCDIR/deploy/run-as" "$STAGE/"
chmod 755 "$STAGE/run" "$STAGE/run-as"
# HFS+ so that even old recovery environments can mount it
hdiutil create -volname JULIACI -fs HFS+ -format UDZO -srcfolder "$STAGE" -ov \
    "$OUTDIR/juliaci.dmg"

cat <<EOF

Done. Now serve '$OUTDIR' at $SERVER with a range-request-capable server, e.g.:
    npx http-server '$OUTDIR' -p 80
Verify ranges work (expect 206):
    curl -r 0-99 -o /dev/null -s -w '%{http_code}\n' $SERVER/juliaci.dmg
Then follow README.md "Deploying a machine".
EOF
