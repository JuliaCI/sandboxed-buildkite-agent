#!/usr/bin/env julia
include("common.jl")

configs = read_configs()
check_configs(configs)

clear_launchctl_services()
generate_launchctl_script.(configs)
launch_launchctl_services(configs)
