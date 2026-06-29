#!/bin/sh

echo "-> Setting hostname to ${SANITIZED_HOSTNAME}"
# Change for the current session
hostname "${SANITIZED_HOSTNAME}"
# Make the change persistent across reboots by modifying the value in `/etc/rc.conf`
sysrc hostname="${SANITIZED_HOSTNAME}"
