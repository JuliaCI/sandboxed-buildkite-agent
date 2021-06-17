# Sandboxed Buildkite setups

This repository showcases how to sandbox Buildkite agents on various platforms using a variety of technologies.
Each agent will have the hooks and secrets defined within the `hooks` and `secrets` directories within them.

The configurations include:

* `linux-sandbox.jl`:  Uses [`Sandbox.jl`](https://github.com/staticfloat/Sandbox.jl/) to provide a nestable usernamespaces-based sandbox.  This is the preferred sandboxing type on Linux, as it allows for very lightweight, flexible and nested sandboxing.  In particular, this allows for a user to easily provide their own rootfs image for certain steps of the build, thanks to the nestable sandboxing.  See the [`sandbox-buildkite-plugin` repository](https://github.com/staticfloat/sandbox-buildkite-plugin) for more.
