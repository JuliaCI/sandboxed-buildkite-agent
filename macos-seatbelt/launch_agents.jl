#!/usr/bin/env julia
include("common.jl")

# Load the group name that we're going to impersonate
configs = read_configs()

clear_launchctl_services()
generate_launchctl_script.(configs)
launch_launchctl_services(configs)