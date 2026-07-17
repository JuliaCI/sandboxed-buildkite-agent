const SCHEDULER_CONFIG_TABLE = "scheduler"
const SCHEDULER_CONFIG_KEYS = Set([
    "logdir",
    "poll_interval",
    "error_sleep",
    "reservation_expiry_seconds",
    "assignment_timeout_seconds",
    "total_cpus",
])
const DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS = 6 * 60 * 60.0
const RUNNER_GROUP_CONFIG_KEYS = Set([
    "backend",
    "queues",
    "num_agents",
    "tags",
    "start_rootless_docker",
    "num_cpus",
    "job_cpus",
    "max_jobs",
    "priority",
    "platform",
    "guest",
    "source_dir",
    "tempdir",
    "cachedir",
    "sharedcache",
    "persistence_dir",
    "secrets_dir",
    "stack_key",
    "verbose",
])
const BACKEND_LINUX_SANDBOX = "linux-sandbox"
const BACKEND_MACOS_SEATBELT = "macos-seatbelt"
const BACKEND_KVM = "kvm"
const KNOWN_BACKENDS = Set([BACKEND_LINUX_SANDBOX, BACKEND_MACOS_SEATBELT, BACKEND_KVM])
const KVM_GUESTS = Set(["freebsd", "windows"])

function default_backend(host::Symbol = host_os())
    host == :linux && return BACKEND_LINUX_SANDBOX
    host == :macos && return BACKEND_MACOS_SEATBELT
    throw(ArgumentError("No default backend for host OS $(host)"))
end

function backend_valid_on_host(backend::AbstractString, host::Symbol)
    backend == BACKEND_LINUX_SANDBOX && return host == :linux
    backend == BACKEND_MACOS_SEATBELT && return host == :macos
    backend == BACKEND_KVM && return host == :linux
    return false
end

function parse_backend(name, host::Symbol)
    backend = string(name)
    if backend ∉ KNOWN_BACKENDS
        throw(ArgumentError("Unknown backend '$(backend)'; expected one of $(join(sort(collect(KNOWN_BACKENDS)), ", "))"))
    end
    if !backend_valid_on_host(backend, host)
        throw(ArgumentError("Backend '$(backend)' is not valid on host OS $(host)"))
    end
    return backend
end

struct SchedulerConfig
    logdir::String
    poll_interval::Float64
    error_sleep::Float64
    reservation_expiry_seconds::Int
    assignment_timeout_seconds::Float64
    total_cpus::Int
end

SchedulerConfig(logdir::String, poll_interval::Real, error_sleep::Real,
                reservation_expiry_seconds::Integer) =
    SchedulerConfig(logdir, Float64(poll_interval), Float64(error_sleep),
        Int(reservation_expiry_seconds), DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS,
        Sys.CPU_THREADS)

SchedulerConfig(logdir::String, poll_interval::Real, error_sleep::Real,
                reservation_expiry_seconds::Integer,
                assignment_timeout_seconds::Real) =
    SchedulerConfig(logdir, Float64(poll_interval), Float64(error_sleep),
        Int(reservation_expiry_seconds), Float64(assignment_timeout_seconds),
        Sys.CPU_THREADS)

function SchedulerConfig(config::Dict; config_dir::AbstractString = pwd())
    unknown_keys = setdiff(string.(collect(keys(config))), SCHEDULER_CONFIG_KEYS)
    if !isempty(unknown_keys)
        @warn("Ignoring unknown scheduler config key(s)", keys=sort(unknown_keys))
    end

    function path_config(key, default, scratch_name)
        value = if haskey(config, key)
            string(config[key])
        elseif default === nothing
            string(@get_scratch!(scratch_name))
        else
            string(default)
        end
        if startswith(value, "@scratch/")
            value = replace(value, "@scratch/" => string(@get_scratch!(scratch_name), "/"))
        elseif !isabspath(value)
            value = abspath(joinpath(config_dir, value))
        end
        return value
    end

    poll_interval = Float64(get(config, "poll_interval", 15.0))
    if !isfinite(poll_interval) || poll_interval <= 0
        throw(ArgumentError("Scheduler config `poll_interval` must be positive"))
    end

    error_sleep = Float64(get(config, "error_sleep", 10.0))
    if !isfinite(error_sleep) || error_sleep < 0
        throw(ArgumentError("Scheduler config `error_sleep` must be non-negative"))
    end

    reservation_expiry_seconds = Int(get(config, "reservation_expiry_seconds", 300))
    if reservation_expiry_seconds < 1 || reservation_expiry_seconds > 3600
        throw(ArgumentError("Scheduler config `reservation_expiry_seconds` must be between 1 and 3600"))
    end

    assignment_timeout_seconds = Float64(get(config, "assignment_timeout_seconds",
        DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS))
    if !isfinite(assignment_timeout_seconds) || assignment_timeout_seconds <= 0
        throw(ArgumentError("Scheduler config `assignment_timeout_seconds` must be positive"))
    end

    total_cpus = Int(get(config, "total_cpus", Sys.CPU_THREADS))
    if total_cpus < 1 || total_cpus > Sys.CPU_THREADS
        throw(ArgumentError("Scheduler config `total_cpus` must be between 1 and Sys.CPU_THREADS ($(Sys.CPU_THREADS))"))
    end

    return SchedulerConfig(
        path_config("logdir", nothing, "agent-logs"),
        poll_interval,
        error_sleep,
        reservation_expiry_seconds,
        assignment_timeout_seconds,
        total_cpus,
    )
end

struct BuildkiteRunnerGroup
    # Group name, such as "surrogatization"
    name::String

    # Scheduler backend used to run this group.
    backend::String

    # The queue this runner will subscribe to (exactly one; Buildkite cluster
    # agents cannot listen to multiple queues)
    queues::Set{String}

    # Any extra tags to be applied
    tags::Dict{String,String}

    # Whether the linux-sandbox backend starts rootless docker for jobs.
    start_rootless_docker::Bool

    # Scheduler resource cost and concurrency controls.
    job_cpus::Int
    max_jobs::Int
    priority::Int

    # The platform that this will run as
    platform::Platform

    # KVM guest OS ("windows" or "freebsd"); only set for the kvm backend.
    guest::Union{String,Nothing}

    # Optional host directory mounted read-only in FreeBSD KVM guests.
    source_dir_path::Union{String,Nothing}

    # Path overrides; `nothing` selects the default (scratch space or repo).
    tempdir_path::Union{String,Nothing}
    cache_path::Union{String,Nothing}
    shared_cache_path::Union{String,Nothing}
    persistence_dir::Union{String,Nothing}
    secrets_path::Union{String,Nothing}

    # Stacks API registration key override.
    stack_key::Union{String,Nothing}

    # Whether this runner should be run in verbose mode
    verbose::Bool
end

function BuildkiteRunnerGroup(name::String, config::Dict;
                              extra_tags::Dict{String,String} = Dict{String,String}(),
                              config_dir::AbstractString = pwd(),
                              host::Symbol = host_os(),
                              total_cpus::Integer = Sys.CPU_THREADS)
    unknown_keys = setdiff(string.(collect(keys(config))), RUNNER_GROUP_CONFIG_KEYS)
    if !isempty(unknown_keys)
        @warn("Ignoring unknown runner group config key(s)", runner_group=name,
            keys=sort(unknown_keys))
    end
    if haskey(config, "num_agents")
        throw(ArgumentError("Runner group '$(name)' uses removed key `num_agents`; replace it with `max_jobs`"))
    end
    if haskey(config, "num_cpus")
        throw(ArgumentError("Runner group '$(name)' uses removed key `num_cpus`; replace it with `job_cpus`"))
    end

    backend_value = haskey(config, "backend") ? config["backend"] : default_backend(host)
    backend = parse_backend(backend_value, host)
    queues = Set(filter(!isempty, strip.(split(get(config, "queues", "default"), ","))))
    # Buildkite cluster agents can only listen to a single queue; fail at config
    # parse time rather than as an agent that silently can't connect.
    if length(queues) != 1
        throw(ArgumentError("Runner group '$(name)' must specify exactly one queue, got: '$(get(config, "queues", "default"))'"))
    end
    haskey(config, "job_cpus") ||
        throw(ArgumentError("Runner group '$(name)' must set required `job_cpus`"))
    job_cpus = Int(config["job_cpus"])
    job_cpus >= 0 ||
        throw(ArgumentError("Runner group '$(name)' must set `job_cpus` to a non-negative integer"))
    job_cpus <= total_cpus ||
        throw(ArgumentError("Runner group '$(name)' has `job_cpus=$(job_cpus)`, exceeding scheduler `total_cpus=$(total_cpus)`"))
    if backend in (BACKEND_KVM, BACKEND_MACOS_SEATBELT) && job_cpus < 1
        throw(ArgumentError("Runner group '$(name)' with backend '$(backend)' must set `job_cpus` to at least 1"))
    end
    max_jobs = if haskey(config, "max_jobs")
        Int(config["max_jobs"])
    elseif job_cpus == 0
        throw(ArgumentError("Runner group '$(name)' sets `job_cpus = 0`; `max_jobs` is required"))
    else
        max(1, fld(Int(total_cpus), job_cpus))
    end
    max_jobs >= 1 ||
        throw(ArgumentError("Runner group '$(name)' must set `max_jobs` to at least 1"))
    priority = Int(get(config, "priority", 10))
    tags = get(config, "tags", Dict{String,String}())
    start_rootless_docker = get(config, "start_rootless_docker", false)
    platform = parse(Platform, get(config, "platform", triplet(HostPlatform())))
    guest = get(config, "guest", nothing)
    guest = guest === nothing ? nothing : string(guest)
    source_dir_path = get(config, "source_dir", nothing)
    if source_dir_path !== nothing
        source_dir_path = string(source_dir_path)
        isabspath(source_dir_path) ||
            throw(ArgumentError("Runner group '$(name)' has non-absolute `source_dir`: $(source_dir_path)"))
    end
    tempdir_path = get(config, "tempdir", nothing)
    cache_path = get(config, "cachedir", nothing)
    shared_cache_path = get(config, "sharedcache", nothing)
    persistence_dir = get(config, "persistence_dir", nothing)
    # A relative `secrets_dir` is resolved against the directory containing the
    # `config.toml` (passed in as `config_dir`), so configs can use e.g.
    # `secrets_dir = "../secrets-secure"` and stay checkout-location independent.
    secrets_path = get(config, "secrets_dir", nothing)
    if secrets_path !== nothing && !isabspath(secrets_path)
        secrets_path = abspath(joinpath(config_dir, secrets_path))
    end
    stack_key = get(config, "stack_key", nothing)
    if stack_key !== nothing
        stack_key = string(stack_key)
        if isempty(stack_key) || !occursin(r"^[A-Za-z0-9_-]{1,80}$", stack_key)
            throw(ArgumentError("Runner group '$(name)' has invalid `stack_key`; expected 1-80 characters matching [A-Za-z0-9_-]"))
        end
    end
    verbose = get(config, "verbose", false)

    if backend == BACKEND_KVM
        if guest === nothing || guest ∉ KVM_GUESTS
            throw(ArgumentError("KVM runner group '$(name)' must set `guest` to one of $(join(sort(collect(KVM_GUESTS)), ", "))"))
        end
        if source_dir_path !== nothing && guest != "freebsd"
            throw(ArgumentError("KVM runner group '$(name)' sets `source_dir`, which is only supported for FreeBSD guests"))
        end
    elseif guest !== nothing
        throw(ArgumentError("Runner group '$(name)' sets `guest`, but `guest` is only valid for backend '$(BACKEND_KVM)'"))
    elseif source_dir_path !== nothing
        throw(ArgumentError("Runner group '$(name)' sets `source_dir`, but it is only valid for FreeBSD KVM runners"))
    end

    if shared_cache_path !== nothing
        if startswith(shared_cache_path, "@scratch/")
            shared_cache_path = replace(shared_cache_path, "@scratch/" => string(@get_scratch!("sharedcache"), "/"))
        end
        if !isabspath(shared_cache_path)
            throw(ArgumentError("Invalid shared cache path '$(shared_cache_path)', must be an absolute path or start with '@scratch/'"))
        end
    end

    # Encode some information about this runner
    merge!(tags, extra_tags)
    if !haskey(tags, "os")
        tags["os"] = something(guest, os(platform))
    end
    if !haskey(tags, "arch")
        tags["arch"] = arch(platform)
    end
    if !haskey(tags, "config_gitsha")
        tags["config_gitsha"] = get_config_gitsha()[1:8]
    end
    if backend in (BACKEND_LINUX_SANDBOX, BACKEND_KVM)
        # Transitional: remove once julia-buildkite no longer queries this tag.
        tags["cpuset_limited"] = "true"
    end

    return BuildkiteRunnerGroup(
        string(name),
        backend,
        queues,
        tags,
        start_rootless_docker,
        job_cpus,
        max_jobs,
        priority,
        platform,
        guest,
        source_dir_path,
        tempdir_path,
        cache_path,
        shared_cache_path,
        persistence_dir,
        secrets_path,
        stack_key,
        verbose,
    )
end

function scheduler_config_from(parsed::AbstractDict, config_file, config_dir)
    if !haskey(parsed, SCHEDULER_CONFIG_TABLE)
        throw(ArgumentError("Missing required [$(SCHEDULER_CONFIG_TABLE)] table in $(config_file)"))
    end
    return SchedulerConfig(parsed[SCHEDULER_CONFIG_TABLE]; config_dir)
end

# Parse the config file once: the [scheduler] table plus one runner group per
# remaining table.
function read_config(config_file::String="config.toml"; kwargs...)
    config = TOML.parsefile(config_file)
    config_dir = dirname(abspath(config_file))
    scheduler_config = scheduler_config_from(config, config_file, config_dir)
    group_names = filter(!=(SCHEDULER_CONFIG_TABLE), sort(collect(keys(config))))
    brgs = [BuildkiteRunnerGroup(name, config[name]; config_dir,
                total_cpus=scheduler_config.total_cpus, kwargs...)
            for name in group_names]
    return scheduler_config, brgs
end

read_configs(config_file::String="config.toml"; kwargs...) =
    read_config(config_file; kwargs...)[2]

# Read only the [scheduler] table.  Deliberately skips building the runner
# groups so `bk status`/`bk logs` keep working when a group is misconfigured.
function read_scheduler_config(config_file::String="config.toml")
    config = TOML.parsefile(config_file)
    config_dir = dirname(abspath(config_file))
    return scheduler_config_from(config, config_file, config_dir)
end

# A convenient way to tag our runners with their current githash
function get_config_gitsha()
    LibGit2.with(GitRepo(REPO_ROOT)) do repo
        return string(LibGit2.GitHash(LibGit2.head(repo)))
    end
end

function Base.tempdir(brg::BuildkiteRunnerGroup)
    return something(brg.tempdir_path, tempdir())
end

cachedir(brg::BuildkiteRunnerGroup) = brg.cache_path === nothing ? @get_scratch!("agent-cache") : brg.cache_path
has_shared_cache(brg::BuildkiteRunnerGroup) = brg.shared_cache_path !== nothing
sharedcachedir(brg::BuildkiteRunnerGroup) = brg.shared_cache_path === nothing ? @get_scratch!("sharedcache") : brg.shared_cache_path
persistence_dir(brg::BuildkiteRunnerGroup) = brg.persistence_dir
secrets_dir(brg::BuildkiteRunnerGroup) = something(brg.secrets_path, repo_path("agent", "secrets"))
stack_key_override(brg::BuildkiteRunnerGroup) = brg.stack_key
rootless_docker_enabled(brg::BuildkiteRunnerGroup) = brg.start_rootless_docker
configured_tempdir(brg::BuildkiteRunnerGroup) = brg.tempdir_path
