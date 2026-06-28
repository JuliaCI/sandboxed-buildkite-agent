#!/bin/sh

join_file="$1"
shift

echo "$$" > "$join_file"
exec "$@"