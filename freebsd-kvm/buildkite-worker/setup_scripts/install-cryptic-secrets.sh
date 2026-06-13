#!/bin/sh

set -e

echo "-> Installing jq"
# Needed to parse buildkite API responses
pkg install -y jq

echo "-> Installing cryptic secrets"
SECRETS_DIR="/usr/home/${USERNAME}/secrets"
mkdir -p "${SECRETS_DIR}"
# Copy the secrets we need, but tolerate any that aren't provided: the Cryptic
# agent keypair (agent.key/agent.pub) is optional and not present on every
# deployment.  The windows worker copies the same set non-fatally (Copy-Item
# without -ErrorAction Stop), so match that rather than aborting the whole
# build under `set -e` when a key is absent.
for secret in agent.key agent.pub buildkite-api-token; do
    if [ -f "/tmp/secrets/${secret}" ]; then
        cp "/tmp/secrets/${secret}" "${SECRETS_DIR}/"
    else
        echo "   (skipping /tmp/secrets/${secret}: not provided)"
    fi
done
chmod -R 700 "${SECRETS_DIR}"
chown -R ${USERNAME}:${USERNAME} "${SECRETS_DIR}"
