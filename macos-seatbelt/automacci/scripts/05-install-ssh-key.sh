#!/bin/bash
# Deploy the buildbot SSH public key into julia's authorized_keys
# (PR #57 discussion, staticfloat's note 4). The repo was cloned by
# 01-clone-buildkite-agent.sh; the key lives inside it.
REPO=/Users/julia/src/sandboxed-buildkite-agent
KEY_SRC="$REPO/agent/secrets/ssh_keys/julia_buildbot_rsa.pub"
# location at the time of PR #57, in case it moves back:
[ -f "$KEY_SRC" ] || KEY_SRC="$REPO/secrets/ssh_keys/julia_buildbot_rsa.pub"

if [ ! -f "$KEY_SRC" ]; then
    echo "buildbot ssh key not found in $REPO; skipping"
    exit 1
fi
sudo -H -u julia mkdir -p /Users/julia/.ssh
touch /Users/julia/.ssh/authorized_keys
grep -qsF -f "$KEY_SRC" /Users/julia/.ssh/authorized_keys || \
    cat "$KEY_SRC" >> /Users/julia/.ssh/authorized_keys
chown -R julia /Users/julia/.ssh
chmod 700 /Users/julia/.ssh
chmod 600 /Users/julia/.ssh/authorized_keys
