#!/bin/sh
echo "-> Formatting external disk"
dd if=/dev/zero of=/dev/ada1 bs=1m
glabel label -v data /dev/ada1
zpool create exdisk /dev/label/data
