#!/bin/sh

set -e

if [ -z "${BUILDKITE_AGENT_QUEUE}" ]; then
    echo "-> Skipping buildkite-agent installation..."
    exit 0
fi

echo "-> Installing buildkite-agent"

# Based on https://raw.githubusercontent.com/buildkite/agent/main/install.sh and
# https://cgit.freebsd.org/ports/tree/devel/buildkite-agent
# We want to install buildkite in the same way as the port so that we can use it as
# a system service but we want to use buildkite's official binaries and distribution
# info to ensure consistency with other systems.

INFO="$(curl -s "https://buildkite.com/agent/releases/latest?platform=freebsd&arch=amd64&system=freebsd&machine=amd64")"
VERSION="$(echo "${INFO}" | grep '^version=' | cut -d'=' -f2)"
FILENAME="$(echo "${INFO}" | grep '^filename=' | cut -d'=' -f2)"
URL="$(echo "${INFO}" | grep '^url=' | cut -d'=' -f2)"

mkdir -p /tmp/buildkite-install
cd /tmp/buildkite-install
curl -LO "${URL}"
tar xzf "${FILENAME}"

chmod +x buildkite-agent
install -D /usr/local/bin buildkite-agent

ETC="/usr/local/etc/buildkite"
mkdir -p "${ETC}/hooks"
mkdir -p "${ETC}/plugins"

sed -i '' \
    -e "s/^[# ]*name=.*$/name=\"${BUILDKITE_AGENT_NAME}\"/" \
    -e "s/^[# ]*token=.*$/token=\"${TOKEN}\"/" \
    -e "s|^[# ]*hooks-path=.*$|hooks-path=\"${ETC}/hooks\"|" \
    -e "s|^[# ]*plugins-path=.*$|plugins-path=\"${ETC}/plugins\"|" \
    buildkite-agent.cfg
tee -a buildkite-agent.cfg <<EOF
shell="$(which bash) -c"
git-fetch-flags="-v --prune --tags"
EOF
install -D "${ETC}" buildkite-agent.cfg

echo "#!/bin/sh\nshutdown -p now" > "${ETC}/hooks/agent-shutdown.sh"

mkdir -p /usr/local/etc/rc.conf.d
cat > /usr/local/etc/rc.conf.d/buildkite <<EOF
buildkite_enable=YES
buildkite_token=${TOKEN}
buildkite_account=${USERNAME}
buildkite_config=${ETC}/buildkite-agent.cfg
buildkite_options=--disconnect-after-job
EOF
chown root:wheel /usr/local/etc/rc.conf.d/buildkite
chmod 600 /usr/local/etc/rc.conf.d/buildkite

curl "https://cgit.freebsd.org/ports/plain/devel/buildkite-agent/files/buildkite.in" | \
    sed -i '' -e 's|%%PREFIX%%|/usr/local|' -e "s|%%ETCDIR%%|${ETC}|" > \
    /etc/rc.d/buildkite
chown root:wheel /etc/rc.d/buildkite
chmod 555 /etc/rc.d/buildkite

cd -
rm -rf /tmp/buildkite-install
