#!/bin/sh

set -e

echo "-> Enabling sshd"

sysrc sshd_enable=YES
sed -i '' -e 's/^#PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i '' -e 's/^#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
