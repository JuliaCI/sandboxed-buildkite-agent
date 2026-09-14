# KVM image generations

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

## Activate and roll back

Make does not deploy images. Before activation, inspect both worker disks with
`qemu-img info --backing-chain`, and ensure every backing file stays at its final
path. Copying only the worker OS disk is insufficient. Ensure libvirt's QEMU
process can traverse the generation's parent directories and access the files.

Use disposable overlays for guest-agent, installed-tool and persistent-cache
smoke tests. Then run an acquired Buildkite canary and a Julia build/test,
including cancellation and cleanup checks, before broad use.

Arrange maintenance for all groups owned by the host scheduler, wait for active
jobs to finish, then stop it with `bin/bk stop` from the repository root. The
command stops jobs; it is not a graceful drain. Inspect its interrupted-job
report and actual Buildkite state if a job raced the stop. Confirm the scheduler
and its domains are stopped before changing image selection.

Publish the worker OS/cache pair together while stopped, retaining the previous
generation and its backing paths for rollback. The runtime image locations in
the table remain unchanged; a directory symlink can select a staged generation.
On existing installations, inspect backing references before replacing any
physical directory with such a link. Do not move files still referenced by
active or cached overlays. FreeBSD's first migration from the legacy layout is
covered in [the x86 refresh procedure](freebsd-kvm/X86_REFRESH.md).

Start with `bin/bk start` and check service restart count, fresh successful
pollers, logs and active leases against libvirt domains. Both KVM guests use
fresh OS overlays per job and persistent cache overlays. Changing the cache
backing identity recreates those overlays, so expect cold caches after a switch
or rollback. Roll back while stopped by restoring the previous image selection,
then start and repeat the health checks.

## Tests

From the repository root, run `python3 platforms/tests/test_kvm_images.py`.
These exercise Make's staging, refusal to overwrite, socket cleanup and Windows
refresh flow using a Packer stand-in. Real Packer validation and guest smoke tests
are separate checks; these tests do not install or boot an operating system.
