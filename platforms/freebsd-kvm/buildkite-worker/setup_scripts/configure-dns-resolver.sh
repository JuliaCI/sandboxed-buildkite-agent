#!/bin/sh
set -e
# The nameserver set by DHCP is the host machine's IP. For whatever reason, it takes
# a full 30 seconds to report NXDOMAIN for invalid domains, which interacts poorly
# with Julia's Downloads tests, which set a timeout. There are a few complementary ways
# we could paper over this, among them:
#   - Use Google's DNS server, 8.8.8.8, either before or after the host. The former is
#     significantly faster.
#   - Reduce the amount of time the resolver waits for a response, e.g. `timeout:1` to
#     wait only 1 second. The default is 5 seconds, with exponential backoff.
#   - Reduce the number of times the resolver sends a query to each nameserver, e.g.
#     `attempts:1` to give up after a single query to each nameserer. Default is 2.
# We'll only do the first of these as the resolver option changes could potentially
# make things less robust to brief network hiccups.
cat > /etc/resolvconf.conf <<EOF
prepend_nameservers=8.8.8.8
EOF
resolvconf -u
