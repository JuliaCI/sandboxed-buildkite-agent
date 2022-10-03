#!/bin/sh

# The sandbox runner will always mount our own cgroup at this special mountpoint
echo "$$" > /usr/lib/cpuset/self/tasks

# Sub off to the given process
exec "$@"
