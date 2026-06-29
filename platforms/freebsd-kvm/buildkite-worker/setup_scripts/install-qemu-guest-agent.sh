#!/bin/sh

set -e

echo "-> Installing qemu-guest-agent"

pkg install -y qemu-guest-agent

sysrc qemu_guest_agent_enable=YES
sysrc qemu_guest_agent_flags="-d -v -l /var/log/qemu-ga.log"

echo "-> Checking qemu-guest-agent guest-exec RPC availability"
for rpc in guest-ping guest-exec guest-exec-status; do
    /usr/local/bin/qemu-ga --allow-rpcs=help | grep -qx "${rpc}" ||
        { echo "qemu-ga does not advertise required RPC ${rpc}" >&2; exit 1; }
done
flags="$(sysrc -n qemu_guest_agent_flags || true)"
case "${flags}" in
    *"--block-rpcs="*guest-ping*|*"-b "*guest-ping*|*"--block-rpcs="*guest-exec*|*"-b "*guest-exec*|*"--block-rpcs="*guest-exec-status*|*"-b "*guest-exec-status*)
        echo "qemu-guest-agent flags block a required RPC: ${flags}" >&2
        exit 1
        ;;
esac

if ! grep -q '^virtio_console_load=' /boot/loader.conf; then
    echo 'virtio_console_load="YES"' >> /boot/loader.conf
fi
