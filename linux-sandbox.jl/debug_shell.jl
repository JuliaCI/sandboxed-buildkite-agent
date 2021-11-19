#!/usr/bin/env julia
include("common.jl")

# Load the group name that we're going to impersonate
configs = read_configs()
group_name = get(ARGS, 1, configs[1].name)
config = only(filter(c -> c.name == group_name, configs))

# Run the debug shell
debug_shell(config)