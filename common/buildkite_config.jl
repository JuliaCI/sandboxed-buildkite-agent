using TOML, Base.BinaryPlatforms, Scratch

struct BuildkiteRunnerGroup
    # Group name, such as "surrogatization"
    name::String

    # Number of agents to spawn
    num_agents::Int

    # All the queues this runner will subscribe to
    queues::Set{String}

    # Any extra tags to be applied
    tags::Dict{String,String}

    # Whether this runner should spin up a rootless docker instance
    # NOTE: this only works with `linux-sandbox.jl` runners!
    start_rootless_docker::Bool

    # Whether to lock workers to CPUs.  Zero if unused.
    # NOTE: This only works with `linux-sandbox.jl` runners!
    num_cpus::Int

    # winkvm only: the source image to use for building the agent-specific image
    source_image::String

    # Whether this runner should be run in verbose mode
    verbose::Bool
end

function BuildkiteRunnerGroup(name::String, config::Dict; extra_tags::Dict{String,String} = Dict{String,String}())
    queues = Set(split(get(config, "queues", "default"), ","))
    num_agents = get(config, "num_agents", 1)
    tags = get(config, "tags", Dict{String,String}())
    start_rootless_docker = get(config, "start_rootless_docker", false)
    num_cpus = get(config, "num_cpus", 0)
    source_image = get(config, "source_image", "")
    verbose = get(config, "verbose", false)

    # Encode some information about this runner
    merge!(tags, extra_tags)
    if !haskey(tags, "os")
        tags["os"] = os(HostPlatform())
    end
    if !haskey(tags, "arch")
        tags["arch"] = arch(HostPlatform())
    end

    return BuildkiteRunnerGroup(
        string(name),
        num_agents,
        queues,
        tags,
        start_rootless_docker,
        num_cpus,
        source_image,
        verbose,
    )
end

function read_configs(config_file::String="config.toml"; kwargs...)
    config = TOML.parsefile(config_file)

    # Parse out each of the groups
    return map(sort(collect(keys(config)))) do group_name
        return BuildkiteRunnerGroup(group_name, config[group_name]; kwargs...)
    end
end
