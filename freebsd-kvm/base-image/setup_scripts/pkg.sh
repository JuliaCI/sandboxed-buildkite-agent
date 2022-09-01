#!/bin/sh
set -e
env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
pkg upgrade -q -y
pkg install -q -y bash ca_root_nss ccache cmake curl gcc git gmake m4 pkgconf python sudo
