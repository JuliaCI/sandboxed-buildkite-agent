#!/usr/bin/env bash
#
# Heal a corrupt git-mirror before the agent checks out against it.
#
# Windows CI VMs are recycled by tearing the VM down with `virsh destroy` (an
# immediate power-off) at the end of every job.  That is fast and fine for the OS
# disk, which is a throwaway copy-on-write overlay -- but the cache disk
# (C:\cache, which holds the buildkite git-mirrors under C:\cache\repos) is
# *persistent* across recycles.  The disk runs with a writeback host cache and
# git does not fsync its object writes, so a power-off with writes still in
# flight can leave a torn packfile or loose object in a mirror.  The next job
# clones with `git clone --reference <mirror> --dissociate`, which borrows
# objects straight from that mirror without re-fetching them, so checkout then
# dies on the damaged object, e.g.:
#
#     fatal: unable to parse commit <sha>
#     warning: Clone succeeded, but checkout failed.
#
# Running this in the `environment` hook means it fires *before* the checkout
# phase: we validate the mirror left behind by the previous job and rebuild it if
# it is damaged, turning a hard build failure into one slow re-clone.
#
# Windows-only -- that is where the destroy-on-recycle hazard lives; elsewhere
# this is a no-op.  Cost on a healthy mirror is a single connectivity-only fsck
# (~2-5s on the julia repo).  We deliberately skip the per-object hash check
# (a full `git fsck`) to keep every job cheap; connectivity-only still walks
# every object reachable from the refs, which is what catches a torn
# commit/tree/pack of the kind that breaks `--reference` clones.

# This file is *sourced* from `environment`, which runs under `set -euo pipefail`.
# Keep all the work in a function invoked via `|| true` so nothing here can ever
# fail a build; the worst case is that we leave the mirror untouched.
_heal_git_mirror() {
    [[ "$(uname 2>/dev/null)" == MINGW* ]] || return 0
    command -v git >/dev/null 2>&1 || return 0
    [[ -n "${BUILDKITE_GIT_MIRRORS_PATH:-}" ]] || return 0
    [[ -n "${BUILDKITE_REPO:-}" ]] || return 0

    local mirrors_root
    mirrors_root="$(cygpath -u "${BUILDKITE_GIT_MIRRORS_PATH}" 2>/dev/null || echo "${BUILDKITE_GIT_MIRRORS_PATH}")"
    [[ -d "${mirrors_root}" ]] || return 0

    # Find the bare mirror for the repo this job is about to check out by matching
    # its stored origin URL, rather than reproducing the agent's dir-naming scheme.
    local dir mirror=""
    for dir in "${mirrors_root}"/*/; do
        [[ -d "${dir}objects" ]] || continue
        if [[ "$(git -C "${dir}" config --get remote.origin.url 2>/dev/null)" == "${BUILDKITE_REPO}" ]]; then
            mirror="${dir%/}"
            break
        fi
    done
    [[ -n "${mirror}" ]] || return 0   # not mirrored yet; the agent will create it

    if git -C "${mirror}" fsck --connectivity-only --no-dangling --no-progress >/dev/null 2>&1; then
        return 0
    fi

    echo "+++ :adhesive_bandage: git mirror failed fsck -- rebuilding it" >&2
    echo "    ${mirror}" >&2
    echo "This is almost always a torn write from the previous job's power-off" >&2
    echo "recycle; removing the mirror so buildkite-agent re-clones it cleanly." >&2
    rm -rf "${mirror}" "${mirror}.lock"
}

_heal_git_mirror || true
unset -f _heal_git_mirror 2>/dev/null || true
