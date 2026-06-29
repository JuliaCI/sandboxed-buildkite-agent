#!/bin/sh
pkg install -y zstd gnupg

# Install the AWS cli (this is v1, which is a python package)
pkg install -y py311-awscli
