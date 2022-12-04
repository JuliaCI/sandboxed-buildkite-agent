#!/bin/sh

echo "-> Formatting external disk"
dd if=/dev/zero of=/dev/vtbd1 bs=1m
glabel label -v data /dev/vtbd1
zpool create exdisk /dev/label/data
