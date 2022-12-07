#!/bin/sh
set -e
pkg install -y wireguard
KEYS_DIR="$(dirname "${0}")/../secrets/wireguard_keys"
KEY_FILE="${KEYS_DIR}/${SANITIZED_HOSTNAME}.key"
if [ ! -e "${KEY_FILE}" ]; then
    exit 0
fi
ADDRESS="$(cat "${KEYS_DIR}/${SANITIZED_HOSTNAME}.address")"
KEY="$(cat "${KEY_FILE}")"
cat > /usr/local/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${ADDRESS}
PrivateKey = ${KEY}
[Peer]
PublicKey = pZq1HmTtHyYP5bToj+hrpVIITbe2oeRlyP19O1D6/QU=
Endpoint = mieli.ip.cflo.at:37
AllowedIPs = fd37:5040::/64
PersistentKeepalive = 45
EOF
