# windows-kvm

This directory builds Windows Server 2022 base and worker images. The base stage
installs Windows, updates and tools. The worker stage adds the job launcher and
cache disk. All Windows runner groups share a worker image; the scheduler
injects the Buildkite token, name, tags and acquired job ID at runtime.

See [KVM image generations](../KVM_IMAGES.md) for the shared Windows/FreeBSD
staging, validation, activation and rollback workflow. Run `make base`,
`make worker` or `make all` here, using a new `IMAGE_ROOT` for each refresh.

Image builds require Packer and its QEMU plugin, `qemu-system-x86_64`, access to
`/dev/kvm`, `7z`, and `xorriso` or `mkisofs`. Libvirt is required by the scheduler
at runtime. `make validate` evaluates the base and worker templates without
requiring libvirt or KVM access; the worker template needs an existing base image.

## Refresh an existing base

To update tools and hardening without reinstalling Windows:

```sh
make refresh IMAGE_ROOT=/julia/windows-images/generation-02 \
    SOURCE_IMAGE=/julia/windows-images/generation-01/base-image/images/base.qcow2
make worker IMAGE_ROOT=/julia/windows-images/generation-02
make validate IMAGE_ROOT=/julia/windows-images/generation-02
```

`SOURCE_IMAGE` must name an existing base image. Relative paths are resolved
from this directory. `validate-refresh` evaluates the refresh template with the
same `SOURCE_IMAGE` and `IMAGE_ROOT` arguments without booting the guest.

Refresh copies the source and produces the normal `base-image/images/base.qcow2`
inside the new generation. It refuses to replace an existing output directory.
The old `images-refresh` and `publish` targets/layout are retired; existing files
are left in place. Point `SOURCE_IMAGE` directly at the retained base image.

Refresh does not install Windows updates or reset the evaluation license.
Use a full base build when OS updates or license renewal require it. Neither
workflow changes the configured Windows Server release.
