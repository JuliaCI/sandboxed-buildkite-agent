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
  The scheduler creates per-job overlays from that image and injects the Buildkite token, agent name, agent tags, and acquired job ID at runtime through guest-exec.
  Queue and tag values come from `config.toml` at runtime, so all FreeBSD KVM runner groups can share the same worker image.

Build images from this directory with `make base`, `make worker`, or `make all`.
The worker target depends on the base target and rebuilds when the relevant packer inputs, setup scripts, hooks, or secrets change.

## System Version

The images here currently use *FreeBSD 15.1-RELEASE*, downloaded from the official
release mirror. Its `disc1` media installs the base system from the bundled
offline package repository.
