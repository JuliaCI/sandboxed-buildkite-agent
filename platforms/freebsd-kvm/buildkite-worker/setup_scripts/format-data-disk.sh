#!/bin/sh
set -e

echo "-> Formatting external disk"
glabel label -v cache /dev/vtbd1
zpool create cache /dev/label/cache
zpool list cache >/dev/null
