# windows-kvm

This directory builds Windows Server 2022 base and worker images. The base stage
installs Windows, updates and tools. The worker stage adds the job launcher and
cache disk. All Windows runner groups share a worker image; the scheduler
injects the Buildkite token, name, tags and acquired job ID at runtime.

See [KVM image refresh, rollout and rollback](../KVM_IMAGES.md) for the shared Windows/FreeBSD
staging, validation, activation and rollback workflow. Run `make base`,
`make worker` or `make all` here, using a new `IMAGE_ROOT` for each refresh.

Image builds require Packer and its QEMU plugin, `qemu-system-x86_64`, access to
`/dev/kvm`, `7z`, and `xorriso` or `mkisofs`. Libvirt is required by the scheduler
at runtime. `make validate` evaluates the base and worker templates without
requiring libvirt or KVM access; the worker template needs an existing base image.

The templates build on the q35 machine type with the NIC behind a PCIe root port,
matching `buildkite-worker/kvm_machine.xml.template`; keep the two in sync, or
every job guest installs its NIC anew at boot (see "Guest networking" in the
shared guide).

Windows can refresh tools from an existing base using `make refresh` with an
explicit `SOURCE_IMAGE` and a new `IMAGE_ROOT`; see the shared guide for the full
sequence and its OS-update/evaluation-license limitations. The old
`images-refresh` and `publish` workflow is retired; existing files remain usable
as explicit source images.
