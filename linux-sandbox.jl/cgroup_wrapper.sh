#!/bin/sh

# The sandbox runner will always mount our own cgroup at this special mountpoint
echo "$$" > /sys/fs/cgroup/cpuset/self/tasks

# Sub off to the given process
exec "$@"
