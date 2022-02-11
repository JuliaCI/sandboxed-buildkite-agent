#!/usr/bin/env julia
include("common.jl")

# Load TOML configs
configs = read_configs()

# Build packer images for each config (they will be linked to the underlying images)
build_packer_images(configs)