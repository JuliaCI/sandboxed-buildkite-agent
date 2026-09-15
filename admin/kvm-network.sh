#!/usr/bin/env bash
# kvm-network.sh — inspect or fix the bridge of the libvirt network that CI
# guests attach to (`default`, bridge `virbr0`; see the kvm_machine.xml
# templates).
#
# libvirt defines that network with `<bridge stp='on' delay='0'/>`, but the
# kernel forces a forward delay of at least 2 s while STP is enabled, so every
# tap port a new guest gets goes through the listening and learning states and
# discards the guest's traffic for its first ~4 s (`journalctl -k` shows the
# transitions).  A NAT bridge with a single uplink has no loops to protect
# against, so `--apply` turns STP off: live on the running bridge, which does
# not disturb attached guests, and in the persistent definition for the next
# time the network starts.
#
# Usage:
#   kvm-network.sh            # report XML and live settings
#   kvm-network.sh --apply    # turn STP off (needs root)
set -euo pipefail
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

NETWORK="${NETWORK:-default}"
APPLY=0
case "${1:-}" in
    "") ;;
    --apply) APPLY=1 ;;
    *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

xml=$(virsh net-dumpxml --inactive "$NETWORK")
bridge=$(sed -n "s/.*<bridge name='\([^']*\)'.*/\1/p" <<<"$xml")
[[ -n "$bridge" ]] || { echo "network $NETWORK has no bridge name" >&2; exit 1; }
defined_stp=$(sed -n "s/.*<bridge [^>]*stp='\([^']*\)'.*/\1/p" <<<"$xml")

live_stp="not running"; live_delay=""
if [[ -d "/sys/class/net/$bridge/bridge" ]]; then
    live_stp=$(<"/sys/class/net/$bridge/bridge/stp_state")
    live_delay=$(<"/sys/class/net/$bridge/bridge/forward_delay")
fi

echo "network $NETWORK: bridge $bridge, defined stp=${defined_stp:-on}"
echo "live: stp_state=$live_stp forward_delay=${live_delay:-n/a} (centiseconds)"

if (( APPLY )); then
    [[ $EUID -eq 0 ]] || { echo "--apply needs root" >&2; exit 1; }
    if [[ "$live_stp" == "1" ]]; then
        ip link set dev "$bridge" type bridge stp_state 0
        echo "disabled STP on running bridge $bridge"
    fi
    if [[ "${defined_stp:-on}" != "off" ]]; then
        virsh net-define /dev/stdin <<<"${xml//"stp='on'"/"stp='off'"}"
        echo "persisted stp='off' in the $NETWORK network definition"
    fi
elif [[ "$live_stp" == "1" || "${defined_stp:-on}" != "off" ]]; then
    echo "STP is enabled; run '$0 --apply' as root to turn it off" >&2
    exit 1
fi
