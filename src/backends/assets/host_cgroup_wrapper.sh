#!/bin/sh

join_file="$1"
shift

echo "$$" > "$join_file"
# When the host as a whole runs out of memory, the kernel kills the process
# with the highest badness: let that be one of a job's, not the scheduler or a
# host service. Raising the score needs no privileges and is inherited by the
# whole job.
echo 500 > /proc/self/oom_score_adj
exec "$@"
