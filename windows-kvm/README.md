# windows-kvm

This folder contains the configuration needed to build and deploy a windows KVM images for builds and debugging.  There are three chunks of configuration here:

* `base-image`: This defines the rules necessary to create a base Windows image.  It downloads the Windows Server evaluation ISO, sets up necessary tools, installs updates, etc... (see the scripts in [`setup_scripts`](./base-image/setup_scripts/)), and saves out to a `.qcow2` file.

* `buildkite-worker`:  This builds a second image that uses the output of `base-image` as a backing store, so that per-agent buildkite configuration can be stored in a separate image.  The configuration of `buildkite-worker` images is that the buildkite agent will disconnect after each job, then run its `agent-shutdown` hook, which will cause the machine to restart.  When the VM restarts, the systemd unit that restarts it will reset the buildkite worker qcow2 image back to its pristine state, and this is quite fast because the per-agent image is quite small (hundreds of MB).

* `debug`: This builds a second image similar to `buildkite-worker`, but without `buildkite-agent` actually installed.  It also does not reset to pristine after every boot.  It is intended for interactive debugging.
