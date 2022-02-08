#!/usr/bin/env julia
include("common.jl")

# Load TOML configs
configs = read_configs()

clear_systemd_configs(systemd_unit_name_stem)
generate_systemd_script(configs[1])
launch_systemd_services(configs, systemd_unit_name)