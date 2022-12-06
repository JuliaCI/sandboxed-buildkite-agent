#!/bin/sh

echo "-> Formatting external disk"
glabel label -v data /dev/vtbd1
zpool create exdisk /dev/label/data
