# windows-kvm

This folder contains the configuration needed to build and deploy Windows KVM images for builds and debugging.  There are three chunks of configuration here:

* `base-image`: This defines the rules necessary to create a base Windows image.  It downloads the Windows Server evaluation ISO, sets up necessary tools, installs updates, etc... (see the scripts in [`setup_scripts`](./base-image/setup_scripts/)), and saves out to `base-image/images/base.qcow2`.

* `buildkite-worker`: This builds one generic worker image at `buildkite-worker/images/worker.qcow2`.  The scheduler creates per-job overlays from that image and injects the Buildkite token, agent name, and acquired job ID at runtime through guest-exec.  Queue and tag matching stays scheduler-side, so all Windows KVM runner groups can share the same worker image.

* `debug`: This builds a second image similar to `buildkite-worker`, but without `buildkite-agent` actually installed.  It also does not reset to pristine after every boot.  It is intended for interactive debugging.

Build images from this directory with `make base`, `make worker`, or `make all`.
The worker target depends on the base target and rebuilds when the relevant packer inputs, setup scripts, hooks, or secrets change.

## Image build & boot performance notes (2026-06)

Measured on amdci6 (NVMe-backed `/data`):

* A full `make base` of the base image takes ~60 min, dominated by the
  serial Windows-Update pass (the eval ISO is frozen at the 2021 RTM build
  and Microsoft does not refresh it, so every rebuild installs ~4 years of
  cumulative updates).  Throwing CPUs at the build VM does not help
  (2 cpus: 62 min, 8 cpus: 59 min).
* `make refresh` (added 2026-06) re-runs the software/hardening stages on a
  copy of the existing base image without reinstalling Windows: ~15-30 min.
  Use it to pick up tool or setup-script changes.  It does NOT install
  Windows updates and does NOT reset the 180-day eval license, so do a full
  `make base` at least every ~5 months (and for monthly CU pickup, unless
  the LCU gets slipstreamed into the ISO some day).
* Worker VMs cold-boot to SSH-usable in ~12 s; `virsh save`/`virsh restore`
  resumes a pre-booted VM in ~7 s and can skip agent start delays entirely.
  If integrating that into the recycle units: the XML needs
  `<cpu migratable='on'/>` (invtsc blocks `virsh save`), a fresh overlay on
  an unchanged backing image per restore, the saved state re-taken after
  host qemu upgrades, and `virsh domtime --sync` right after restore (the
  guest clock is otherwise frozen at save time; qemu-guest-agent and its
  virtio channel are in place for this).
  CRITICAL: the persistent cache disk (`vdb` → `C:\cache`) must NOT be part
  of the saved state.  A `virsh save` captures the guest's in-RAM NTFS
  metadata/page-cache for every attached disk; since the cache disk is
  shared and mutated by every job, restoring a save taken before those
  writes resurrects a stale in-guest view of a disk that moved underneath
  it — i.e. NTFS corruption of the git mirrors.  Take the save with only the
  throwaway OS overlay attached and hot-plug the cache disk fresh after each
  restore (the OS overlay is safe — it is recreated per boot regardless).
