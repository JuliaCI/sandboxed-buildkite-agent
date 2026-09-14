# Refreshing an existing x86-64 worker

This procedure refreshes worker tools and adopts architecture-specific image
paths while retaining FreeBSD 13.4. It does not change Julia's FreeBSD baseline,
runner-group names, queue tags, or pipeline platform entries.

## Build a separate generation

From `platforms/freebsd-kvm`, choose a new permanent path on the worker host:

```sh
make all ARCH=x86_64 IMAGE_ROOT=/julia/freebsd-images/x86-refresh-01
make validate ARCH=x86_64 IMAGE_ROOT=/julia/freebsd-images/x86-refresh-01
```

Use the host's normal Packer credential file. `IMAGE_ROOT` only redirects image
outputs; templates, scripts, hooks and credentials still come from the checkout.
Record the checkout commit and build logs with the generation. Package versions
come from the configured repository at build time; rebuilding does not pin them
or update the FreeBSD base system.

The generation contains a base disk, a worker OS disk and a worker cache disk.
Check both worker disks before booting:

```sh
qemu-img info --backing-chain /julia/freebsd-images/x86-refresh-01/buildkite-worker/images/x86_64/worker.qcow2
qemu-img info --backing-chain /julia/freebsd-images/x86-refresh-01/buildkite-worker/images/x86_64/worker.qcow2-1
```

Keep every backing file at its recorded path. Do not move a generation after
building it, copy just the top-level worker disk, or rebuild an activated
generation in place. Ensure libvirt's QEMU process can traverse the staging
parents and access the images; host service-user access alone is insufficient.

## Canary before activation

Boot disposable OS and cache overlays against the staged generation using the
x86 libvirt template. Verify the guest reports FreeBSD 13.4, guest-agent
`guest-ping` and `guest-exec`/`guest-exec-status` work, and the installed
Buildkite agent, AWS CLI and job launcher run. Write a cache marker, export the
ZFS cache pool, shut down the guest, then boot a fresh OS overlay with the same
cache overlay and verify the marker remains. Destroy the trial domains and
remove only their disposable overlays afterwards.

For a scheduler canary, use an isolated checkout on a trial host, with its
`buildkite-worker/images/x86_64` link pointing to the staged worker directory.
Use separate cache/temp directories and runner names, and reserve CPU capacity
for the trial; do not run competing schedulers that each budget the whole host.

Also run an acquired Buildkite canary and a Julia build/test before broad use.
Exercise successful completion and cancellation, checking domain/overlay
cleanup and scheduler leases. A manual guest-agent smoke test alone does not
validate job acquisition, Julia or cancellation. Keep canary job routing
isolated from normal traffic until these checks pass.

## Activate during maintenance

The scheduler prefers `buildkite-worker/images/x86_64/worker.qcow2` as soon as
that file exists. Staging directly there can switch subsequent jobs before a
restart, so build outside the active tree and publish only while stopped.

On amdci6 the host scheduler also owns Windows workers. Arrange a maintenance
window for the whole scheduler, wait for active jobs to finish, and run
`bin/bk stop` from the repository root. Confirm the service has stopped and its
domains are gone before changing images. `stop` is not a graceful drain: inspect
its interrupted-job report and actual Buildkite state if a job raced the stop.

For the first migration from the legacy layout, run from the repository root:

```sh
image_link=platforms/freebsd-kvm/buildkite-worker/images/x86_64
test ! -e "$image_link" && test ! -L "$image_link" &&
    ln -s /julia/freebsd-images/x86-refresh-01/buildkite-worker/images/x86_64 "$image_link"
```

This publishes both worker disks together. If the destination already exists,
inspect it and retain the previous generation rather than overwriting it.
Leave the old `images/worker.qcow2`, `images/worker.qcow2-1` and their backing
files in place. Keep the existing FreeBSD group names and configuration.

Run `bin/bk start`, then check `bin/bk status`, logs, poller freshness and errors,
restart count, and active leases against libvirt domains. Monitor both FreeBSD
and Windows jobs. Cache overlays are recreated when their backing identity
changes, so expect cold caches after the switch.

## Roll back

Stop the scheduler using the same maintenance procedure. For the first migration,
remove only the `images/x86_64` symlink created above (verify it is that symlink).
The scheduler will again select the legacy worker/cache pair. For a subsequent
refresh, restore the previous generation's link instead. Start and recheck the
scheduler; rollback can also produce cold caches.

Retain old generations until no active or cached overlays reference them and the
new workers have passed real jobs. `make clean` only selects a root/architecture;
it does not detect references from guests or caches and is not a retirement tool.
