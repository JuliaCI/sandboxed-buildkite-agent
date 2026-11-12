#!/bin/sh
set -e
sysrc clear_tmp_enable=YES
sed -i '' -e 's/^#PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
