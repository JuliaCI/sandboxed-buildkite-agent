#!/bin/sh
set -e
VERSION="1.21.3"
echo "-> Installing Telegraf ${VERSION}"
URL="https://dl.influxdata.com/telegraf/releases/telegraf-${VERSION}_freebsd_amd64.tar.gz"
mkdir /tmp/telegraf-install
cd /tmp/telegraf-install
curl -LO "{URL}"
tar xzf "$(basename "${URL}")"
cd "telegraf-${VERSION}"
install -D /usr/local/bin ./usr/bin/telegraf
# TODO
