#!/usr/bin/env julia
include("common.jl")

configs = read_configs()
check_configs(configs)

# Load the group name that we're going to impersonate
group_name = get(ARGS, 1, configs[1].name)
config = only(filter(c -> c.name == group_name, configs))
debug_shell(config)
