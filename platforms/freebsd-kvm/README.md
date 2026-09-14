# freebsd-kvm

This folder contains the configuration needed to build and deploy FreeBSD KVM images.
It is based heavily on the setup used for KVM-based Windows builds (see `../windows-kvm`).
By "based heavily," we really mean copy-pasta'd; eventually, both should be refactored to use a common setup.

Both x86-64 and AArch64 images can be built.
The Make variable `ARCH` must be provided and set to either `x86_64` or `aarch64`.
Images are stored in separate architecture directories.
Note that the FreeBSD version may differ depending on the architecture; see below.

## Host requirements

Install Packer with its QEMU plugin and the QEMU system emulator for the target
architecture (including the virtio-gpu-pci display module for ARM Packer
builds). Native builds use KVM and need read/write access to `/dev/kvm`.
The ARM scheduler requires libvirt 8.6 or newer for stateless firmware.
The scheduler additionally needs access to libvirt's `qemu:///system` connection
and its `default` NAT network (normally via the `libvirt` group).

ARM hosts need the stateless UEFI ROM from Ubuntu's `qemu-efi-aarch64` package
(`/usr/share/AAVMF/AAVMF_CODE.fd`) or Arch's `edk2-aarch64` package
(`/usr/share/edk2/aarch64/QEMU_EFI.fd`). The scheduler detects either path.
Packer defaults to the Ubuntu path; set `PKR_VAR_firmware` for another location.
Both image building and runtime boot the disk's fallback `EFI/BOOT/BOOTAA64.EFI`
loader, without persisting or sharing UEFI variables between jobs.

For an emulated development build on another architecture:

```sh
PKR_VAR_firmware=/usr/share/edk2/aarch64/QEMU_EFI.fd \
make all ARCH=aarch64 ACCELERATOR=tcg
```

Use `PKR_VAR_iso_url=file:/path/to/disc1.iso.xz` for a downloaded installer;
the release checksum is still verified. Tune `PKR_VAR_boot_wait` for the
installer menu and `PKR_VAR_memory` for the build host. Serial logs are saved
alongside the Packer images. Runtime scheduler VMs require native KVM; the TCG
option is only for image development.
`make validate ARCH=<arch>` evaluates both Packer templates with their inputs.

## Images

There are two chunks of configuration here:

- `base-image`: This defines the rules necessary to create a base FreeBSD image.
  It downloads the official ISO, sets up user profiles, installs necessary tools, etc.
  Output is saved to `base-image/images/<arch>/base.qcow2`.

- `buildkite-worker`: This builds one generic worker image at `buildkite-worker/images/<arch>/worker.qcow2`.
  The scheduler creates per-job overlays from that image and injects the Buildkite token, agent name, agent tags, and acquired job ID at runtime through guest-exec.
  Queue and tag values come from `config.toml` at runtime, so FreeBSD KVM runner groups for the same architecture can share a worker image.

Build images from this directory for a given architecture with `make base ARCH=<arch>`, `make worker ARCH=<arch>`, or `make all ARCH=<arch>`.
The worker target depends on the base target and detects changes to the relevant
Packer inputs, setup scripts, hooks, or secrets. Builds do not force replacement
of existing output directories: those files may back active guests or persistent
caches. If inputs change after a build, select a fresh `IMAGE_ROOT` for the new
generation. Failed builds can also leave output directories; clean them only
when they have never been activated and no overlays reference them.

Set `IMAGE_ROOT` to build a separate generation without publishing it to the
scheduler's image directory. Relative paths are resolved from this directory:

```sh
make all ARCH=x86_64 IMAGE_ROOT=/julia/freebsd-images/x86-refresh-01
```

Both `base-image/images/<arch>` and `buildkite-worker/images/<arch>` are created
under that root. Keep the root at its final location because worker images
reference the base image by absolute path. Validation and `clean` use the same
`IMAGE_ROOT`; the default is this directory, preserving the existing layout.
Make allocates a private temporary QMP socket directory under `/tmp` for each
Packer build, so long image paths do not exceed Unix socket path limits.

`make clean ARCH=<arch>` only removes that architecture's images from the selected root.
Do not rebuild or clean images while active guests or cached overlays use them.

### Existing x86-64 hosts

See [the x86 refresh procedure](X86_REFRESH.md) for staging, canary checks,
activation and rollback without changing the FreeBSD 13.4 baseline.

The scheduler continues to use `buildkite-worker/images/worker.qcow2` (and its
`-1` cache disk) when no `images/x86_64/worker.qcow2` has been staged. Keep the
legacy base image and all backing paths in place. New builds use the architecture
directory; stage both worker disks and their backing images before restarting
the scheduler. Inspect `qemu-img info --backing-chain` before retiring old files.
Existing runner group names can be retained; ARM groups must advertise
`os="freebsd"` and `arch="aarch64"`.

## System Version

The images here currently use FreeBSD 13.4-RELEASE on x86-64 and FreeBSD 14.1-RELEASE on AArch64.

Generally speaking, binaries built on FreeBSD version `x` are incompatible with FreeBSD version `x - 1`.
However, the opposite is not true: binaries built on older versions are forward-compatible.
Thus we want to use the oldest FreeBSD version we can to ensure support for as many versions as possible.
This often means that we end up staying on a version of FreeBSD after its official EOL.
Package repositories change independently of these release baselines. Validate
the installed tools on the selected release when rebuilding, and keep working
images/backing chains for rollback. Upgrading the guest OS to obtain packages
also raises the baseline for binaries built there. The ISO locations are:

- Old versions: <https://archive.freebsd.org/old-releases/ISO-IMAGES/>
- Current releases: <https://download.freebsd.org/releases/ISO-IMAGES/>
