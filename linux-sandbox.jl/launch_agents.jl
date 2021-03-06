#!/usr/bin/env julia
include("common.jl")

# Load TOML configs
configs = read_configs()

# Ensure that all our configs are good
check_configs(configs)

clear_systemd_configs()
generate_systemd_script.(configs)
launch_systemd_services(configs)
