#!/bin/sh

set -e

# NOTE: We could get a more recent version with `pkg install telegraf`, which would also
# set up the system service stuff for us but then we'd be on a different version than
# other platforms here :/
VERSION="1.21.3"

echo "-> Installing Telegraf ${VERSION}"
URL="https://dl.influxdata.com/telegraf/releases/telegraf-${VERSION}_freebsd_amd64.tar.gz"
mkdir /tmp/telegraf-install
cd /tmp/telegraf-install
curl -LO "{URL}"
tar xzf "$(basename "${URL}")"
cd "telegraf-${VERSION}"
install -D /usr/local/bin ./usr/bin/telegraf

curl "https://cgit.freebsd.org/ports/tree/net-mgmt/telegraf/files/telegraf.in" | \
    sed -i '' \
        -e 's|%%PREFIX%%|/usr/local|' \
        -e 's|%%LOCALBASE%%|/usr/local|' \
        -e 's|%%TELEGRAF_USER%%|telegraf|' \
        -e 's|%%TELEGRAF_GROUP%%|telegraf|' \
        -e 's|%%TELEGRAF_LOGDIR%%|/var/log/telegraf|' > \
    /etc/rc.d/telegraf

cat > /usr/local/etc/telegraf.conf <<EOF
[global_tags]
  project= "julia"
[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "60s"
  flush_jitter = "10s"
  precision = ""
  hostname = "${BUILDKITE_AGENT_NAME}"
  omit_hostname = false
[[outputs.influxdb]]
  urls = ["http://[fd37:5040::dc82:d3f5:c8b7:c381]:8086"]
  content_encoding = "gzip"
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = true
  report_active = true
[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]
[[inputs.diskio]]
[[inputs.kernel]]
[[inputs.mem]]
[[inputs.swap]]
[[inputs.system]]
  fielddrop = ["uptime_format"]
[[inputs.net]]
EOF

echo "telegraf_enable=YES" > /usr/local/etc/rc.conf.d/telegraf

if [ -e "$(dirname "${0}")/../secrets/wireguard_keys/${SANITIZED_HOSTNAME}.key" ]; then
    service onestart telegraf
fi
