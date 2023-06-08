# Sandboxed Buildkite setups

This repository showcases how to sandbox Buildkite agents on various platforms using a variety of technologies.
Each agent will have the hooks and secrets defined within the `hooks` and `secrets` directories within them.

The configurations include:

* `linux-sandbox.jl`:  Uses [`Sandbox.jl`](https://github.com/staticfloat/Sandbox.jl/) to provide a nestable usernamespaces-based sandbox.  This is the preferred sandboxing type on Linux, as it allows for very lightweight, flexible and nested sandboxing.  In particular, this allows for a user to easily provide their own rootfs image for certain steps of the build, thanks to the nestable sandboxing.  See the [`sandbox-buildkite-plugin` repository](https://github.com/staticfloat/sandbox-buildkite-plugin) for more.

* `macos-seatbelt`: Uses the builtin macOS sandboxing API ([referred to as Seatbelt](https://www.chromium.org/developers/design-documents/sandbox/osx-sandboxing-design/)) to provide a restricted environment that disallows writes (and even some reads) to the rest of the system.  This is the only sandboxing type supported for macOS guests, as it's quite lightweight.  No rootfs support exists at this point, all compilers and toolchains must be globally installed.

* `windows-kvm`: Uses [packer](https://www.packer.io/) to create KVM virtual machines that contain windows agents ready to run workloads, and launch docker containers within via nested virtualization.  Docker images will be built to contain compilers and toolchains within the VMs.  Each VM uses a qcow2 backing image system whereby all modifications made to the image are discarded after a reboot (which occurs after each CI run).

* `freebsd-kvm`: Similarly to Windows, uses [packer](https://www.packer.io/) to create KVM virtual machines that contain FreeBSD agents ready to run workloads. Each VM uses a qcow2 backing image and all modifications made to the image are discarded after reboot, which occurs after each CI run.
