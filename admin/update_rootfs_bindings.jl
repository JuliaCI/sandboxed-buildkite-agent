#!/usr/bin/env julia

include("bind_tarball.jl")

release = isempty(ARGS) ? get_latest_release("JuliaCI/rootfs-images") : ARGS[1]
@info("Updating JuliaCI/rootfs-images bindings", release)
update_bindings!(joinpath(@__DIR__, "..", "Artifacts.toml"), "JuliaCI/rootfs-images", release)
