#!/bin/sh

set -e

echo "-> Installing buildkite-agent"

# Based on https://raw.githubusercontent.com/buildkite/agent/main/install.sh and
# https://cgit.freebsd.org/ports/tree/devel/buildkite-agent
# We want to install buildkite in the same way as the port so that we can use it as
# a system service but we want to use buildkite's official binaries and distribution
# info to ensure consistency with other systems.
URL="https://github.com/buildkite/agent/releases/download/v3.129.0/buildkite-agent-freebsd-amd64-3.129.0.tar.gz"
FILENAME="$(basename "${URL}")"

mkdir -p /tmp/buildkite-install
cd /tmp/buildkite-install
curl -LO "${URL}"
tar xzf "${FILENAME}"

chmod +x buildkite-agent
cp -a buildkite-agent /usr/local/bin/

ETC="/usr/local/etc/buildkite"
mkdir -p "${ETC}/hooks"
mkdir -p "${ETC}/plugins"

# Install our hooks
cp -a /tmp/hooks/ "${ETC}/hooks/"

sed -i '' \
    -e "s/^[# ]*name=.*$/name=\"${BUILDKITE_AGENT_NAME}\"/" \
    -e "s/^[# ]*token=.*$/token=\"\"/" \
    -e "s|^[# ]*hooks-path=.*$|hooks-path=\"${ETC}/hooks\"|" \
    -e "s|^[# ]*plugins-path=.*$|plugins-path=\"${ETC}/plugins\"|" \
    buildkite-agent.cfg
tee -a buildkite-agent.cfg <<EOF
shell="$(which bash) -c"
git-fetch-flags="-v --prune --tags"

# Disable this mirrors path, as github does not seem to respond to us.  :(
#git-mirrors-path="/cache/repos"
experiment="output-redactor,ansi-timestamps,resolve-commit-after-checkout"
EOF
cp -a buildkite-agent.cfg "${ETC}/"
chown -R ${USERNAME}:${USERNAME} "${ETC}"

cat > /usr/local/bin/run-buildkite-job.sh <<EOF
#!/bin/sh

set -eu

if [ "\$#" -ne 1 ]; then
    echo "usage: run-buildkite-job.sh <job-id>" >&2
    exit 2
fi

if [ -z "\${BUILDKITE_AGENT_TOKEN:-}" ]; then
    echo "BUILDKITE_AGENT_TOKEN must be set" >&2
    exit 2
fi
if [ -z "\${BUILDKITE_AGENT_NAME:-}" ]; then
    echo "BUILDKITE_AGENT_NAME must be set" >&2
    exit 2
fi
if [ -z "\${BUILDKITE_AGENT_TAGS:-}" ]; then
    echo "BUILDKITE_AGENT_TAGS must be set" >&2
    exit 2
fi

JOB_ID="\$1"
AGENT_USER="${USERNAME}"
AGENT_HOME="\$(pw usershow "\${AGENT_USER}" | cut -d: -f9)"
SERIAL=/dev/ttyu0
[ -e "\${SERIAL}" ] || SERIAL=/dev/console
exec >> "\${SERIAL}" 2>&1

export HOME="\${AGENT_HOME}"
export PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
export BUILDKITE_PLUGIN_JULIA_CACHE_DIR=/cache/julia-buildkite-plugin
export BUILDKITE_AGENT_TOKEN
export BUILDKITE_AGENT_NAME
export BUILDKITE_AGENT_TAGS

SCRUB_STAMP=/cache/.sandboxed-buildkite-zfs-scrub-at
SCRUB_INTERVAL_SECONDS="\${KVM_CACHE_ZFS_SCRUB_INTERVAL_SECONDS:-604800}"
if ! zpool status -x cache; then
    echo "cache zpool is unhealthy; refusing to start Buildkite job \${JOB_ID}" >&2
    exit 1
fi
if [ "\${SCRUB_INTERVAL_SECONDS}" -gt 0 ] 2>/dev/null; then
    now=\$(date +%s)
    last=0
    if [ -r "\${SCRUB_STAMP}" ]; then
        last=\$(cat "\${SCRUB_STAMP}" 2>/dev/null || echo 0)
    fi
    case "\${last}" in
        ""|*[!0-9]*) last=0 ;;
    esac
    if [ \$((now - last)) -ge "\${SCRUB_INTERVAL_SECONDS}" ]; then
        echo "Starting periodic zpool scrub for cache"
        zpool scrub cache
        tmp="\${SCRUB_STAMP}.\$\$"
        printf '%s\\n' "\${now}" > "\${tmp}"
        mv "\${tmp}" "\${SCRUB_STAMP}"
    fi
fi

exec su -m "\${AGENT_USER}" -c "/usr/local/bin/buildkite-agent start --acquire-job '\${JOB_ID}' --name '\${BUILDKITE_AGENT_NAME}' --tags '\${BUILDKITE_AGENT_TAGS}' --config '${ETC}/buildkite-agent.cfg'"
EOF

chown root:wheel /usr/local/bin/run-buildkite-job.sh
chmod 555 /usr/local/bin/run-buildkite-job.sh

cd -
rm -rf /tmp/buildkite-install

chown -R ${USERNAME}:${USERNAME} "/cache"
