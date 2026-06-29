#!/usr/bin/env bash
# kvm-guest-exec.sh — run a command *inside* a libvirt-managed Windows/KVM guest
# via the qemu-guest-agent and print its decoded stdout/stderr.  Needs no guest
# networking or SSH — only the guest agent (org.qemu.guest_agent.0), which is
# installed in our base images.
#
# Useful for inspecting a "stuck"-looking worker without disturbing the job:
# e.g. dump the process tree by CPU to see whether a build is actually
# progressing (a busy julia.exe/cc1.exe) or genuinely hung (all idle).
#
# Usage:
#   kvm-guest-exec.sh <domain> cmd /c "tasklist"
#   kvm-guest-exec.sh <domain> --ps  <<'PS'      # run a PowerShell script (stdin)
#       gcim Win32_Process | Sort {$_.KernelModeTime+$_.UserModeTime} -Desc |
#         Select -First 12 ProcessId,ParentProcessId,
#           @{n='cpu_s';e={[int](($_.KernelModeTime+$_.UserModeTime)/1e7)}},Name,CommandLine |
#         Format-Table -Auto | Out-String -Width 220
#   PS
#
# Requires: python3, and `sudo virsh` (LIBVIRT_DEFAULT_URI=qemu:///system).
set -uo pipefail
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

DOM="${1:?usage: kvm-guest-exec.sh <domain> [--ps | <path> <args...>]}"; shift

if [[ "${1:-}" == "--ps" ]]; then
    SCRIPT="$(cat)"
    ENC=$(python3 -c 'import sys,base64;print(base64.b64encode(sys.stdin.buffer.read().decode().encode("utf-16-le")).decode())' <<<"$SCRIPT")
    REQ=$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-NonInteractive","-EncodedCommand",sys.argv[1]],"capture-output":True}}))' "$ENC")
else
    PATHBIN="${1:?need a path}"; shift
    REQ=$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":sys.argv[1],"arg":sys.argv[2:],"capture-output":True}}))' "$PATHBIN" "$@")
fi

PID=$(sudo virsh qemu-agent-command "$DOM" "$REQ" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])') || { echo "kvm-guest-exec: guest-exec failed (agent down?)"; exit 1; }

for _ in $(seq 1 2400); do   # up to ~20 min
    ST=$(sudo virsh qemu-agent-command "$DOM" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}" 2>/dev/null)
    if python3 - "$ST" <<'PY'
import json,sys,base64
st=json.loads(sys.argv[1])["return"]
if not st.get("exited"): sys.exit(7)
sys.stderr.write(f"[exitcode={st.get('exitcode', st.get('signal'))}]\n")
for k in ("out-data","err-data"):
    d=st.get(k)
    if d: sys.stdout.write(base64.b64decode(d).decode("utf-8","replace"))
sys.exit(0)
PY
    then exit 0; fi
    sleep 0.5
done
echo "kvm-guest-exec: TIMEOUT waiting on pid $PID"; exit 1
