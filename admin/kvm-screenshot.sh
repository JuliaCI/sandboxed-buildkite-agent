#!/usr/bin/env bash
# Take a screenshot of a libvirt-managed VM's console and save it as a PNG.
# Useful for inspecting what (headless) KVM agents are doing, e.g. whether a
# Windows worker is stuck installing updates or showing an interactive prompt.
#
# Usage: kvm-screenshot.sh <domain> [output.png]
#        kvm-screenshot.sh --list
set -euo pipefail

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

if [[ "${1:-}" == "--list" ]]; then
    exec virsh list --name
fi

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <domain> [output.png]" >&2
    echo "       $0 --list" >&2
    exit 1
fi

DOMAIN="$1"
OUT="${2:-${DOMAIN}-$(date +%Y%m%d-%H%M%S).png}"
TMP="$(mktemp --suffix=.ppm)"
trap 'rm -f "${TMP}"' EXIT

virsh screenshot "${DOMAIN}" "${TMP}" >/dev/null
convert "${TMP}" "${OUT}"
echo "${OUT}"
