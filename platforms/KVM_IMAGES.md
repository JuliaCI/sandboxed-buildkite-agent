# KVM image refresh, rollout and rollback

Windows and FreeBSD use `kvm-images.mk` for image staging, builds, validation and
cleanup. Run Make from the respective `windows-kvm` or `freebsd-kvm` directory.
FreeBSD additionally requires `ARCH=x86_64` or `ARCH=aarch64` on every invocation.

## Build and validate

Choose a new permanent root for each generation, distinct for each guest OS:

```sh
# From windows-kvm:
make all IMAGE_ROOT=/julia/windows-images/generation-01
make validate IMAGE_ROOT=/julia/windows-images/generation-01

# From freebsd-kvm:
make all ARCH=x86_64 IMAGE_ROOT=/julia/freebsd-images/generation-01
make validate ARCH=x86_64 IMAGE_ROOT=/julia/freebsd-images/generation-01
```

`base` and `worker` can also be built separately. `worker` depends on the base
image. Templates, provisioning scripts, hooks and credentials come from the
checkout; `IMAGE_ROOT` only redirects outputs. Relative roots are resolved from
the platform directory before entering a Packer template directory.

The worker image sets the guest hostname, which buildkite-agent reports to
Buildkite, to the build host's short name (`hostname -s`). Windows cannot be
renamed per job without a reboot, so this is baked in; pass
`GUEST_HOSTNAME=<name>` when building an image for another host. Names are
limited to 15 letters, digits or hyphens.

| Output | Windows | FreeBSD |
|---|---|---|
| Base | `base-image/images/base.qcow2` | `base-image/images/<arch>/base.qcow2` |
| Worker OS | `buildkite-worker/images/worker.qcow2` | `buildkite-worker/images/<arch>/worker.qcow2` |
| Worker cache | Worker OS path plus `-1` | Worker OS path plus `-1` |

Paths in this table are relative to `IMAGE_ROOT`. Its default is the platform
directory, preserving existing runtime locations. For a refresh of a deployed
host, always build a separate generation outside those active locations.

Builds refuse to overwrite existing output directories. If changed inputs make
an existing generation stale, build a new generation. Both stages use private,
short QMP socket paths under `/tmp`, cleaned up when Packer exits. Validation
evaluates the templates with their real inputs and a temporary output location,
so it works even after images have been built. Worker validation needs an
existing base image; it does not boot that image.

`make clean IMAGE_ROOT=...` removes only the selected generation's image output
directories (and only the selected architecture for FreeBSD). It does not check
for references from guests or caches. Use it only for unreferenced generations.
Windows `cleanall` additionally removes the extracted virtio driver inputs.

## Refresh

For either guest OS, build a new base and worker with `make all` as above.

Windows also supports refreshing tools and hardening from an existing base,
without reinstalling Windows:

```sh
# From windows-kvm:
make refresh IMAGE_ROOT=/julia/windows-images/generation-02 \
    SOURCE_IMAGE=/julia/windows-images/generation-01/base-image/images/base.qcow2
make worker IMAGE_ROOT=/julia/windows-images/generation-02
make validate IMAGE_ROOT=/julia/windows-images/generation-02
```

`SOURCE_IMAGE` must exist; relative paths are resolved from the platform
directory. `validate-refresh` evaluates the refresh template with the same
arguments. Refresh produces the normal base output in the new generation,
without modifying the source. It does not install Windows updates or reset the
evaluation license; use a full base build when those are needed. FreeBSD has no
incremental `refresh` target; use `make all` with a new root.

## Roll out

1. Inspect **both** staged worker disks with `qemu-img info --backing-chain`.
   Keep the generation at its final path and ensure libvirt's QEMU process can
   access every backing file. Record the image generation and checkout commit.
2. Boot disposable overlays and check guest-agent execution, installed tools
   and cache persistence across fresh OS overlays. Run an acquired Buildkite
   canary and a Julia build/test, including cancellation and cleanup, before
   admitting normal traffic. An isolated canary scheduler needs separate runner
   names, cache/temp directories and an explicit CPU budget.
3. Record the current image selection and scheduler commit for rollback. Arrange
   maintenance for **all groups** owned by the host scheduler, wait for active
   jobs to finish, then run `bin/bk stop` from the repository root. This stops
   jobs rather than draining them; inspect its interrupted-job report and actual
   Buildkite state if a job raced the stop. Confirm the service and its domains
   are stopped before changing image selection.
4. Select the staged worker OS/cache pair at the runtime paths below. Switch
   both while stopped. A directory symlink can select the pair as a unit when
   that directory is already managed as a link. For an initial migration from
   physical files, archive the old worker pair and verify the archived backing
   chains resolve before replacing them with links. Preserve their base/backing
   files and record how to restore the original layout. Do not rebuild or move
   backing files as part of activation.
5. Run `bin/bk start`. Check service restart count, fresh successful pollers,
   logs and active leases against libvirt domains, then watch the first jobs
   complete. Image publication takes effect when the paths change; a scheduler
   restart alone does not select a generation.

Runtime paths are relative to the scheduler checkout:

| Guest | Worker OS | Worker cache |
|---|---|---|
| Windows | `platforms/windows-kvm/buildkite-worker/images/worker.qcow2` | Same path plus `-1` |
| FreeBSD | `platforms/freebsd-kvm/buildkite-worker/images/<arch>/worker.qcow2` | Same path plus `-1` |

FreeBSD always uses the architecture-qualified directory. Publish the worker
pair together, normally by pointing that directory at an immutable generation.

Both guests use fresh OS overlays per job and persistent cache overlays.
Changing the cache backing identity recreates those overlays, so expect cold
caches after an image switch.

Each Windows slot re-clones the Buildkite git mirror of
`JuliaLang/julia` (about 1 GB) on its first job per pipeline and trust level,
and those jobs can start together, so the clones share the
host's uplink and can exceed a job's timeout. A job cancelled that way can
leave a half-written mirror behind. Switch at a quiet time and watch the first
round of jobs on every slot, not only the first job on the host. Pre-seeding
the mirror into the worker cache image would remove the cold clone entirely.

## Roll back and retire

Stop the scheduler using the same maintenance procedure, then restore the
previous worker OS/cache selection as a pair. Restore the previous scheduler
commit as well if it changed during the rollout and is part of the failure.
For FreeBSD, repoint the architecture directory to the retained rollback pair.
An unqualified `images/worker.qcow2` is never selected.

Start the scheduler and repeat the rollout health checks and a canary job.
Rollback can also produce cold caches; retaining images does not preserve the
cache overlays replaced after a switch.

Keep old generations until the new workers have passed real jobs and rollback
is no longer needed. Before deleting one, check that no live domain, retained
image or cache overlay references it. `make clean` does not perform that check.

## Tests

From the repository root, run `python3 platforms/tests/test_kvm_images.py`.
These exercise Make's staging, refusal to overwrite, socket cleanup and Windows
refresh flow using a Packer stand-in. Real Packer validation and guest smoke tests
are separate checks; these tests do not install or boot an operating system.
