#!/bin/sh
set -e

pkg install -y zstd gnupg

# Install AWS CLI v1 using the Python flavor provided by this repository.
pkg install -y -g 'py[0-9]*-awscli'
