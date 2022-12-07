# freebsd-kvm

This folder contains the configuration needed to build and deploy FreeBSD KVM images for builds and debugging.
It is based heavily on the setup used for KVM-based Windows builds (see `../windows-kvm`).
By "based heavily," we really mean copy-pasta'd; eventually, both should be refactored to use a common setup.

## Images

There are three chunks of configuration here:

- `base-image`: This defines the rules necessary to create a base FreeBSD image.
  It downloads the official ISO, sets up user profiles, installs necessary tools, etc.
  Output is saved to a `.qcow2` file.

- `buildkite-worker`: This builds a second image that uses the output of `base-image` as a backing store, so that per-agent buildkite configuration can be stored in a separate image.
  The configuration of `buildkite-worker` images is such that the buildkite agent will disconnect after each job, then run its `agent-shutdown` hook, which will cause the machine to restart.
  When the VM restarts, the systemd unit that restarts it will reset the buildkite worker qcow2 image back to its pristine state, and this is quite fast because the per-agent image is quite small (hundreds of MB).

- `debug`: This builds a third image similar to `buildkite-worker`, but without `buildkite-agent` actually installed.
  It also does not reset to pristine after every boot.
  It is intended for interactive debugging.

## System Version

The images here currently use *FreeBSD 12.2-RELEASE*, which is officially EOL upstream.

Generally speaking, binaries built on FreeBSD version `x` are incompatible with FreeBSD version `x - 1`.
However, the opposite is not true: binaries built on older versions are forward-compatible.
Thus we want to use the oldest FreeBSD version we can to ensure support for as many versions as possible.
This often means that we end up staying on a version of FreeBSD after its official EOL.
In practice, this really only affects the availability of up-to-date software (should be fine) and where we need to go to fetch the ISO:

- Old versions: <http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/ISO-IMAGES/> (HTTP only, no HTTPS)
- Current releases: <https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/>
