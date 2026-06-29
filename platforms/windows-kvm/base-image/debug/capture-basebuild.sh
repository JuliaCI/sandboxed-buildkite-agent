#!/bin/bash
# Periodically screenshot a running packer base-image build via its VNC
# console.  Usage: capture-basebuild.sh <packer-build-log> <frames-dir>
# Packer prints its VNC port in the build log (vnc://127.0.0.1:PORT); our
# templates set vnc_use_password=false so vncdotool can connect directly.
LOG="${1:?usage: capture-basebuild.sh <packer-build-log> <frames-dir>}"
FRAMES="${2:?usage: capture-basebuild.sh <packer-build-log> <frames-dir>}"
VNCDO="${VNCDO:-$HOME/.local/bin/vncdo}"
mkdir -p "$FRAMES"

# Wait for packer to announce the VNC port
while true; do
    PORT=$(grep -m1 -oE "vnc://127.0.0.1:[0-9]+" "$LOG" | grep -oE "[0-9]+$")
    [[ -n "$PORT" ]] && break
    grep -q "Builds finished\|errored" "$LOG" && exit 0
    sleep 10
done
echo "VNC port: $PORT"

while true; do
    grep -q "Builds finished\|errored after" "$LOG" && break
    t=$(date +%H%M%S)
    timeout 30 "$VNCDO" -s "127.0.0.1::$PORT" capture "$FRAMES/$t.png" 2>/dev/null
    sleep 120
done
