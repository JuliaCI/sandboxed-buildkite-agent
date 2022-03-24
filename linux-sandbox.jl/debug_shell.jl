#!/usr/bin/env julia
include("common.jl")

# Load the group name that we're going to impersonate
configs = read_configs()
check_configs(configs)
name_pattern = get(ARGS, 1, configs[1].name)


# Find first agent that matches the given agent_name
function find_agent_name(name_pattern::AbstractString)
    agent_idx = 0
    hostname = readchomp(`hostname`)
    for brg in configs
        for _ in 1:brg.num_agents
            agent_name = string(brg.name, "-", hostname, ".", agent_idx)
            if contains(agent_name, name_pattern)
                return brg, agent_name
            end
            agent_idx += 1
        end
    end
    return nothing, nothing
end

config, agent_name = find_agent_name(name_pattern)
debug_shell(config; agent_name)
