# Disable git's commit-graph machine-wide.
#
# The buildkite git-mirror lives on the persistent cache disk (C:\cache\repos)
# and the VM is recycled with `virsh destroy` (an abrupt power-off).  git's
# split commit-graph (objects/info/commit-graphs/) is rewritten on every mirror
# fetch and is NOT crash-safe: a torn graph makes a later
#   git clone --reference <mirror> --dissociate
# fail at checkout with "fatal: unable to parse commit <sha>" even though the
# objects themselves are intact -- verified on a live mirror (cat-file + full
# fsck clean, only the graph was bad), and it self-heals on the next fetch,
# which is why it looks intermittent.
#
# The mirror only uses the commit-graph as a traversal optimization it doesn't
# need, so disable it system-wide: git neither writes a graph (nothing to tear)
# nor reads one (clones parse commits straight from the sound objects).
Write-Output " -> Disabling git commit-graph (not crash-safe under VM recycle)"
git config --system core.commitGraph false
git config --system fetch.writeCommitGraph false
git config --system gc.writeCommitGraph false
