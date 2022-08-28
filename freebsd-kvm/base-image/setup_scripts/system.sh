#!/bin/sh
set -e
sysrc clear_tmp_enable=YES
sed -i '' -e 's/^PermitRootLogin yes/#PermitRootLogin no/' /etc/ssh/sshd_config
sed -i '' -e 's/^#UsePAM yes/UsePAM no/' /etc/ssh/sshd_config
