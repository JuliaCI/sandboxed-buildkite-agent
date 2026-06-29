#!/usr/bin/env julia

include("bind_tarball.jl")

release = isempty(ARGS) ? get_latest_release("buildkite/agent") : ARGS[1]
@info("Updating buildkite/agent bindings", release)
update_bindings!(joinpath(@__DIR__, "..", "Artifacts.toml"), "buildkite/agent", release)
