#!/usr/bin/env julia
include("common.jl")

# Load TOML configs
configs = read_configs()
check_configs(configs)

# Build packer images for each config (they will be linked to the underlying images)
build_packer_images(configs)

# Clear out any systemd configs that belong to us
clear_systemd_configs()

# Generate our systemd scripts, and launch them!
generate_systemd_script.(configs)
launch_systemd_services(configs)
