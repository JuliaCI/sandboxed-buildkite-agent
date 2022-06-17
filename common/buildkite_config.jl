using TOML, Base.BinaryPlatforms, Scratch, LibGit2

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

    # Along with `num_cpus`, we can overlap a few of them in order
    # to oversubscribe our machine a bit.  Note that an overlap of `1`
    # will cause _2_ CPUs to be oversubscribed in your set in general,
    # as the first CPU in our group will overlap with the previous
    # cpuset, and our last CPU will overlap with the first CPU in the
    # next cpuset!
    cpu_overlap::Int

    # The platform that this will run as
    platform::Platform

    # winkvm only: the source image to use for building the agent-specific image
    source_image::String

    # A per-brg override for what `tempdir()` should return
    tempdir_path::Union{String,Nothing}

    # Whether this runner should be run in verbose mode
    verbose::Bool
end

function BuildkiteRunnerGroup(name::String, config::Dict; extra_tags::Dict{String,String} = Dict{String,String}())
    queues = Set(split(get(config, "queues", "default"), ","))
    num_agents = get(config, "num_agents", 1)
    tags = get(config, "tags", Dict{String,String}())
    start_rootless_docker = get(config, "start_rootless_docker", false)
    num_cpus = get(config, "num_cpus", 0)
    cpu_overlap = get(config, "cpu_overlap", 0)
    platform = parse(Platform, get(config, "platform", triplet(HostPlatform())))
    source_image = get(config, "source_image", "")
    tempdir_path = get(config, "tempdir", nothing)
    verbose = get(config, "verbose", false)

    # Encode some information about this runner
    merge!(tags, extra_tags)
    if !haskey(tags, "os")
        tags["os"] = os(platform)
    end
    if !haskey(tags, "arch")
        tags["arch"] = arch(platform)
    end
    if !haskey(tags, "config_gitsha")
        tags["config_gitsha"] = get_config_gitsha()[1:8]
    end
    if num_cpus != 0
        tags["cpuset_limited"] = "true"
        tags["num_cpus"] = string(num_cpus)
    else
        tags["num_cpus"] = string(Sys.CPU_THREADS)
    end

    return BuildkiteRunnerGroup(
        string(name),
        num_agents,
        queues,
        tags,
        start_rootless_docker,
        num_cpus,
        cpu_overlap,
        platform,
        source_image,
        tempdir_path,
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

# A convenient way to tag our runners with their current githash
function get_config_gitsha()
    LibGit2.with(GitRepo(dirname(@__DIR__))) do repo
        return string(LibGit2.GitHash(LibGit2.head(repo)))
    end
end

function Base.tempdir(brg::BuildkiteRunnerGroup)
    return something(brg.tempdir_path, tempdir())
end
