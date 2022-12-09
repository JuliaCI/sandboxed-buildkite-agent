#!/bin/sh

set -e

echo "-> Installing jq"
# Needed for the secrets cleanup hook
pkg install -y jq

echo "-> Installing cryptic secrets"
SECRETS_DIR="/usr/home/${USERNAME}/secrets"
mkdir -p "${SECRETS_DIR}"
# Only copy the secrets we need
cp /tmp/secrets/agent.key "${SECRETS_DIR}/"
cp /tmp/secrets/agent.pub "${SECRETS_DIR}/"
cp /tmp/secrets/buildkite-api-token "${SECRETS_DIR}/"
chmod -R 700 "${SECRETS_DIR}"
chown -R ${USERNAME}:${USERNAME} "${SECRETS_DIR}"
# The exported variable below is actually named as expected
export BUILDKITE_PLUIGIN_CRYPYTIC_SECRETS_MOUNT_POINT="${SECRETS_DIR}"
