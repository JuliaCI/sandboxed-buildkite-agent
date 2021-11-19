#!/usr/bin/env julia
include("common.jl")

# Load the group name that we're going to impersonate
configs = read_configs()

clear_systemd_configs()
generate_systemd_script.(configs)
launch_systemd_services(configs)