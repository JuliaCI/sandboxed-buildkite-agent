# windows-kvm

This folder contains the configuration needed to build and deploy a windows KVM images for builds and debugging.  There are three chunks of configuration here:

* `base-image`: This defines the rules necessary to create a base Windows image.  It downloads the Windows Server evaluation ISO, sets up necessary tools, installs updates, etc... (see the scripts in [`setup_scripts`](./base-image/setup_scripts/)), and saves out to a `.qcow2` file.

* `buildkite-worker`:  This builds a second image that uses the output of `base-image` as a backing store, so that per-agent buildkite configuration can be stored in a separate image.  The configuration of `buildkite-worker` images is that the buildkite agent will disconnect after each job, then run its `agent-shutdown` hook, which will cause the machine to restart.  When the VM restarts, the systemd unit that restarts it will reset the buildkite worker qcow2 image back to its pristine state, and this is quite fast because the per-agent image is quite small (hundreds of MB).

* `debug`: This builds a second image similar to `buildkite-worker`, but without `buildkite-agent` actually installed.  It also does not reset to pristine after every boot.  It is intended for interactive debugging.

## Image build & boot performance notes (2026-06)

Measured on amdci6 (NVMe-backed `/data`):

* A full `make build` of the base image takes ~60 min, dominated by the
  serial Windows-Update pass (the eval ISO is frozen at the 2021 RTM build
  and Microsoft does not refresh it, so every rebuild installs ~4 years of
  cumulative updates).  Throwing CPUs at the build VM does not help
  (2 cpus: 62 min, 8 cpus: 59 min).
* `make refresh` (added 2026-06) re-runs the software/hardening stages on a
  copy of the existing base image without reinstalling Windows: ~15-30 min.
  Use it to pick up tool or setup-script changes.  It does NOT install
  Windows updates and does NOT reset the 180-day eval license, so do a full
  `make build` at least every ~5 months (and for monthly CU pickup, unless
  the LCU gets slipstreamed into the ISO some day).
* Worker VMs cold-boot to SSH-usable in ~12 s; `virsh save`/`virsh restore`
  resumes a pre-booted VM in ~7 s and can skip agent start delays entirely.
  If integrating that into the recycle units: the XML needs
  `<cpu migratable='on'/>` (invtsc blocks `virsh save`), a fresh overlay on
  an unchanged backing image per restore, the saved state re-taken after
  host qemu upgrades, and `virsh domtime --sync` right after restore (the
  guest clock is otherwise frozen at save time; qemu-guest-agent and its
  virtio channel are in place for this).
