#!/bin/sh

set -e

echo "-> Installing qemu-guest-agent"

pkg install -y qemu-guest-agent

sysrc qemu_guest_agent_enable=YES
sysrc qemu_guest_agent_flags="-d -l /var/log/qemu-ga.log"

echo "-> Checking qemu-guest-agent guest-exec RPC availability"
for rpc in guest-ping guest-exec guest-exec-status; do
    /usr/local/bin/qemu-ga --allow-rpcs=help | grep -qx "${rpc}" ||
        { echo "qemu-ga does not advertise required RPC ${rpc}" >&2; exit 1; }
done

if ! grep -q '^virtio_console_load=' /boot/loader.conf; then
    echo 'virtio_console_load="YES"' >> /boot/loader.conf
fi
