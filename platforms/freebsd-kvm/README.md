# freebsd-kvm

This folder contains the configuration needed to build and deploy FreeBSD KVM images.
It is based heavily on the setup used for KVM-based Windows builds (see `../windows-kvm`).
By "based heavily," we really mean copy-pasta'd; eventually, both should be refactored to use a common setup.

## Images

There are two chunks of configuration here:

- `base-image`: This defines the rules necessary to create a base FreeBSD image.
  It downloads the official ISO, sets up user profiles, installs necessary tools, etc.
  Output is saved to `base-image/images/base.qcow2`.

- `buildkite-worker`: This builds one generic worker image at `buildkite-worker/images/worker.qcow2`.
  The scheduler creates per-job overlays from that image and injects the Buildkite token, agent name, and acquired job ID at runtime through guest-exec.
  Queue and tag matching stays scheduler-side, so all FreeBSD KVM runner groups can share the same worker image.

Build images from this directory with `make base`, `make worker`, or `make all`.
The worker target depends on the base target and rebuilds when the relevant packer inputs, setup scripts, hooks, or secrets change.

## System Version

The images here currently use *FreeBSD 13.4-RELEASE*.

Generally speaking, binaries built on FreeBSD version `x` are incompatible with FreeBSD version `x - 1`.
However, the opposite is not true: binaries built on older versions are forward-compatible.
Thus we want to use the oldest FreeBSD version we can to ensure support for as many versions as possible.
This often means that we end up staying on a version of FreeBSD after its official EOL.
In practice, this really only affects the availability of up-to-date software (should be fine) and where we need to go to fetch the ISO:

- Old versions: <http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/ISO-IMAGES/> (HTTP only, no HTTPS)
- Current releases: <https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/>
