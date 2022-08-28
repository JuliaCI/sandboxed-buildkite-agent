#!/bin/sh
set -e
pw useradd -n ${USER} -s $(which bash) -m -w yes
pw groupmod wheel -m ${USER}
echo "${PASSWORD}" | pw usermod ${USER} -h 0
