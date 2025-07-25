#!/bin/sh

set -e

if [ -z "${BUILDKITE_AGENT_QUEUES}" ]; then
    echo "-> Skipping buildkite-agent installation..."
    exit 0
fi

echo "-> Installing buildkite-agent"

# Based on https://raw.githubusercontent.com/buildkite/agent/main/install.sh and
# https://cgit.freebsd.org/ports/tree/devel/buildkite-agent
# We want to install buildkite in the same way as the port so that we can use it as
# a system service but we want to use buildkite's official binaries and distribution
# info to ensure consistency with other systems.
URL="https://github.com/buildkite/agent/releases/download/v3.39.0/buildkite-agent-freebsd-amd64-3.39.0.tar.gz"
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
    -e "s/^[# ]*token=.*$/token=\"${TOKEN}\"/" \
    -e "s|^[# ]*hooks-path=.*$|hooks-path=\"${ETC}/hooks\"|" \
    -e "s|^[# ]*plugins-path=.*$|plugins-path=\"${ETC}/plugins\"|" \
    buildkite-agent.cfg
tee -a buildkite-agent.cfg <<EOF
shell="$(which bash) -c"
git-fetch-flags="-v --prune --tags"
disconnect-after-job=true
disconnect-after-idle-timeout=3600

# Disable this mirrors path, as github does not seem to respond to us.  :(
#git-mirrors-path="/cache/repos"
experiment="output-redactor,ansi-timestamps,resolve-commit-after-checkout"
tags="${BUILDKITE_AGENT_TAGS}"
EOF
cp -a buildkite-agent.cfg "${ETC}/"
chown -R ${USERNAME}:${USERNAME} "${ETC}"

mkdir -p /usr/local/etc/rc.conf.d
cat > /usr/local/etc/rc.conf.d/buildkite <<EOF
buildkite_enable=YES
buildkite_token=${TOKEN}
buildkite_account=${USERNAME}
buildkite_config=${ETC}/buildkite-agent.cfg
buildkite_env="BUILDKITE_PLUGIN_JULIA_CACHE_DIR=/cache/julia-buildkite-plugin BUILDKITE_PLUGIN_CRYPTIC_SECRETS_MOUNT_POINT=/usr/home/${USERNAME}/secrets"
EOF
chown root:wheel /usr/local/etc/rc.conf.d/buildkite
chmod 600 /usr/local/etc/rc.conf.d/buildkite

cat > /etc/rc.d/buildkite <<EOF
#!/bin/sh

# PROVIDE: buildkite
# REQUIRE: LOGIN NETWORKING SERVERS
# KEYWORD:

. /etc/rc.subr

name=buildkite
rcvar=buildkite_enable
pidfile=/var/run/buildkite.pid

load_rc_config \${name}

start_cmd="\${name}_start"
stop_cmd=":"
buildkite_user=\${buildkite_account}
required_files="\${buildkite_config}"

buildkite_start() {
    exec >> /var/log/buildkite.log
    exec 2>&1
    set -x
    su ${USERNAME} -c "/usr/bin/env \
        \${buildkite_env} \
        HOME=\$(pw usershow \${buildkite_account} | cut -d: -f9) \
        BUILDKITE_AGENT_TOKEN=\${buildkite_token} \
        /usr/local/bin/buildkite-agent start --config \${buildkite_config}"
    halt -l -p
}


run_rc_command "\$1"
EOF

chown root:wheel /etc/rc.d/buildkite
chmod 555 /etc/rc.d/buildkite

cd -
rm -rf /tmp/buildkite-install

chown -R ${USERNAME}:${USERNAME} "/cache"
