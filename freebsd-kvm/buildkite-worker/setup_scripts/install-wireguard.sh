#!/bin/sh
set -e
pkg install -y wireguard
KEYS_DIR="$(dirname "${0}")/../wireguard_keys"
KEY_FILE="${KEYS_DIR}/${SANITIZED_HOSTNAME}.key"
if [ -e "${KEY_FILE}" ]; then
    ADDRESS="$(cat "${KEYS_DIR}/${SANITIZED_HOSTNAME}.address")"
    KEY="$(cat "${KEY_FILE}")"
    sed -i '' -e "s/{wgAddress}/${ADDRESS}/" -e "s/{wgKey}/${KEY}/" wg0.conf
    install -D /usr/local/etc/wireguard wg0.conf
fi
