#!/bin/sh
set -e
SSH_DIR="/usr/home/${USER}/.ssh"
mkdir -p "${SSH_DIR}"
cat /tmp/ssh_keys/* > "${SSH_DIR}/authorized_keys"
chmod -R 700 "${SSH_DIR}"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R ${USER}:${USER} "${SSH_DIR}"
