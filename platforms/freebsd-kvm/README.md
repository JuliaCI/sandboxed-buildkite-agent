# freebsd-kvm

This folder contains the configuration needed to build and deploy FreeBSD KVM images.
It is based heavily on the setup used for KVM-based Windows builds (see `../windows-kvm`).
By "based heavily," we really mean copy-pasta'd; eventually, both should be refactored to use a common setup.

Both x86-64 and AArch64 images can be built.
The Make variable `ARCH` must be provided and set to either `x86_64` or `aarch64`.
Images are stored in separate architecture directories.
Note that the FreeBSD version may differ depending on the architecture; see below.

## Images

There are two chunks of configuration here:

- `base-image`: This defines the rules necessary to create a base FreeBSD image.
  It downloads the official ISO, sets up user profiles, installs necessary tools, etc.
  Output is saved to `base-image/images/<arch>/base.qcow2`.

- `buildkite-worker`: This builds one generic worker image at `buildkite-worker/images/<arch>/worker.qcow2`.
  The scheduler creates per-job overlays from that image and injects the Buildkite token, agent name, agent tags, and acquired job ID at runtime through guest-exec.
  Queue and tag values come from `config.toml` at runtime, so all FreeBSD KVM runner groups can share the same worker image.

Build images from this directory for a given architecture with `make base ARCH=<arch>`, `make worker ARCH=<arch>`, or `make all ARCH=<arch>`.
The worker target depends on the base target and rebuilds when the relevant packer inputs, setup scripts, hooks, or secrets change.

`make clean ARCH=<arch>` only removes that architecture's images.
Do not rebuild or clean images while active guests or cached overlays use them.

### Existing x86-64 hosts

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
In practice, this really only affects the availability of up-to-date software (should be fine) and where we need to go to fetch the ISO:

- Old versions: <https://archive.freebsd.org/old-releases/ISO-IMAGES/>
- Current releases: <https://download.freebsd.org/releases/ISO-IMAGES/>
