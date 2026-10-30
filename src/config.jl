const SCHEDULER_CONFIG_TABLE = "scheduler"
const SCHEDULER_CONFIG_KEYS = Set([
    "logdir",
    "poll_interval",
    "error_sleep",
    "reservation_expiry_seconds",
    "assignment_timeout_seconds",
    "total_cpus",
    "total_mem_gib",
    "min_mem_available_gib",
])
const DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS = 12 * 60 * 60.0
const RUNNER_GROUP_CONFIG_KEYS = Set([
    "backend",
    "queues",
    "tags",
    "start_rootless_docker",
    "size",
    "max_slots",
    "max_threads",
    "max_mem_gib",
    "priority",
    "platform",
    "guest",
    "tempdir",
    "cachedir",
    "sharedcache",
    "persistence_dir",
    "secrets_dir",
    "stack_key",
    "verbose",
])
# Keys of earlier config formats, with what replaced them.
const REMOVED_RUNNER_GROUP_CONFIG_KEYS = Dict(
    "num_agents" => "`max_slots`",
    "max_jobs" => "`max_slots`",
    "num_cpus" => "the `sched_cpus` tag on pipeline steps (or `cpus` in a fixed `size`)",
    "job_cpus" => "the `sched_cpus` tag on pipeline steps (or `cpus` in a fixed `size`)",
    "threads" => "the `sched_threads` tag on pipeline steps (or `threads` in a fixed `size`)",
    "mem_gib" => "the `sched_mem_gib` tag on pipeline steps (or `mem_gib` in a fixed `size`)",
    "default" => "required `sched_*` tags on pipeline steps (or a fixed `size`)",
)
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
    total_mem_gib::Int
    # Admit nothing while the host's MemAvailable is below this; 0 disables it.
    min_mem_available_gib::Int
end

host_mem_gib() = Int(fld(Sys.total_physical_memory(), 1024^3))

SchedulerConfig(logdir::String, poll_interval::Real, error_sleep::Real,
                reservation_expiry_seconds::Integer,
                assignment_timeout_seconds::Real=DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS,
                total_cpus::Integer=Sys.CPU_THREADS) =
    SchedulerConfig(logdir, Float64(poll_interval), Float64(error_sleep),
        Int(reservation_expiry_seconds), Float64(assignment_timeout_seconds),
        Int(total_cpus), host_mem_gib(), 0)

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

    total_mem_gib = Int(get(config, "total_mem_gib", host_mem_gib()))
    if total_mem_gib < 1 || total_mem_gib > host_mem_gib()
        throw(ArgumentError("Scheduler config `total_mem_gib` must be between 1 and the host's memory ($(host_mem_gib()) GiB)"))
    end
    min_mem_available_gib = Int(get(config, "min_mem_available_gib", 0))
    if min_mem_available_gib < 0 || min_mem_available_gib >= total_mem_gib
        throw(ArgumentError("Scheduler config `min_mem_available_gib` must be between 0 and `total_mem_gib`"))
    end

    return SchedulerConfig(
        path_config("logdir", nothing, "agent-logs"),
        poll_interval,
        error_sleep,
        reservation_expiry_seconds,
        assignment_timeout_seconds,
        total_cpus,
        total_mem_gib,
        min_mem_available_gib,
    )
end

# The size of one job: what it is charged against the host's pools (`cpus`;
# for KVM also the guest RAM plus overhead), the parallelism it is told to use
# (`JULIA_CPU_THREADS`, KVM vCPUs), and its memory (Linux `memory.max`, KVM
# guest RAM; 0 is unlimited on Linux).
struct JobSize
    cpus::Int
    threads::Int
    mem_gib::Int
end

const JOB_SIZE_KEYS = Set(["cpus", "threads", "mem_gib"])

struct BuildkiteRunnerGroup
    # Group name, such as "surrogatization"
    name::String

    # Scheduler backend used to run this group.
    backend::String

    # The queues this group serves, each through its own Buildkite stack.
    queues::Vector{String}

    # Any extra tags to be applied
    tags::Dict{String,String}

    # Whether the linux-sandbox backend starts rootless docker for jobs.
    start_rootless_docker::Bool

    # A fixed size for all of the group's jobs, which then ignore `sched_*`
    # tags (launchers, the secure queue, macOS's whole host); `nothing` makes
    # the tags required.
    size::Union{JobSize,Nothing}
    # KVM only: bounds on the vCPUs and guest RAM a tagged job can ask for
    # (host and image facts, not policy); 0 is unbounded.
    max_threads::Int
    max_mem_gib::Int
    # Persistent worker identities (cache directories, KVM cache disks); a disk
    # budget. Concurrency is bounded by the host's CPU and memory pools.
    max_slots::Int
    priority::Int

    # The platform that this will run as
    platform::Platform

    # KVM guest OS ("windows" or "freebsd"); only set for the kvm backend.
    guest::Union{String,Nothing}

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

function parse_queues(name, value)
    names = value isa AbstractString ? split(value, ",") :
        value isa AbstractVector ? value :
        throw(ArgumentError("Runner group '$(name)' must set `queues` to a string or an array of strings"))
    queues = unique(filter(!isempty, [String(strip(string(queue))) for queue in names]))
    isempty(queues) && throw(ArgumentError("Runner group '$(name)' must serve at least one queue"))
    return queues
end

function parse_job_size(name, config, backend::AbstractString; total_cpus::Integer)
    config isa AbstractDict ||
        throw(ArgumentError("Runner group '$(name)' must make `size` a table"))
    unknown = setdiff(string.(collect(keys(config))), JOB_SIZE_KEYS)
    isempty(unknown) ||
        throw(ArgumentError("Runner group '$(name)' has unknown `size` key(s): $(join(sort(unknown), ", "))"))
    haskey(config, "cpus") ||
        throw(ArgumentError("Runner group '$(name)' must set `cpus` in its `size`"))
    cpus = Int(config["cpus"])
    0 <= cpus <= total_cpus ||
        throw(ArgumentError("Runner group '$(name)' must give jobs between 0 and `total_cpus=$(total_cpus)` CPUs"))
    backend == BACKEND_LINUX_SANDBOX || cpus >= 1 ||
        throw(ArgumentError("Runner group '$(name)' with backend '$(backend)' must give jobs at least 1 CPU"))
    threads = Int(get(config, "threads", cpus))
    mem_gib = Int(get(config, "mem_gib", 0))
    haskey(config, "threads") && threads < 1 &&
        throw(ArgumentError("Runner group '$(name)' must set `threads` to at least 1"))
    haskey(config, "mem_gib") && mem_gib < 1 &&
        throw(ArgumentError("Runner group '$(name)' must set `mem_gib` to at least 1"))
    backend == BACKEND_KVM && mem_gib < 1 &&
        throw(ArgumentError("KVM runner group '$(name)' must set the guest's `mem_gib` in its `size`"))
    return JobSize(cpus, threads, mem_gib)
end

function BuildkiteRunnerGroup(name::String, config::Dict;
                              extra_tags::Dict{String,String} = Dict{String,String}(),
                              config_dir::AbstractString = pwd(),
                              host::Symbol = host_os(),
                              total_cpus::Integer = Sys.CPU_THREADS,
                              total_mem_gib::Integer = host_mem_gib())
    for (key, replacement) in REMOVED_RUNNER_GROUP_CONFIG_KEYS
        haskey(config, key) &&
            throw(ArgumentError("Runner group '$(name)' uses removed key `$(key)`; see $(replacement) in the README"))
    end
    unknown_keys = setdiff(string.(collect(keys(config))), RUNNER_GROUP_CONFIG_KEYS)
    if !isempty(unknown_keys)
        @warn("Ignoring unknown runner group config key(s)", runner_group=name,
            keys=sort(unknown_keys))
    end

    backend_value = haskey(config, "backend") ? config["backend"] : default_backend(host)
    backend = parse_backend(backend_value, host)
    queues = parse_queues(name, get(config, "queues", ["build", "test"]))

    # macOS jobs get the whole host: the seatbelt does not isolate concurrent jobs.
    if backend == BACKEND_MACOS_SEATBELT
        haskey(config, "size") &&
            throw(ArgumentError("macOS runner group '$(name)' cannot set `size`: its jobs get the whole host"))
        size = JobSize(total_cpus, total_cpus, 0)
    else
        size = haskey(config, "size") ?
            parse_job_size(name, config["size"], backend; total_cpus) : nothing
    end

    max_threads = Int(get(config, "max_threads", 0))
    max_mem_gib = Int(get(config, "max_mem_gib", 0))
    for (key, value) in (("max_threads", max_threads), ("max_mem_gib", max_mem_gib))
        haskey(config, key) || continue
        backend == BACKEND_KVM ||
            throw(ArgumentError("Runner group '$(name)' sets `$(key)`, which only applies to backend '$(BACKEND_KVM)'"))
        value >= 1 || throw(ArgumentError("Runner group '$(name)' must set `$(key)` to at least 1"))
    end
    if backend == BACKEND_KVM
        largest = max_mem_gib > 0 ? max_mem_gib : size === nothing ? 0 : size.mem_gib
        kvm_reserved_mem_gib(largest) <= total_mem_gib ||
            throw(ArgumentError("Runner group '$(name)' could reserve $(kvm_reserved_mem_gib(largest)) GiB for one guest ($(largest) GiB plus host overhead), exceeding scheduler `total_mem_gib=$(total_mem_gib)`"))
    end

    max_slots = if haskey(config, "max_slots")
        Int(config["max_slots"])
    elseif size !== nothing && size.cpus == 0
        throw(ArgumentError("Runner group '$(name)' gives jobs no CPUs; `max_slots` is required"))
    elseif backend == BACKEND_MACOS_SEATBELT
        1
    else
        Int(total_cpus)
    end
    max_slots >= 1 ||
        throw(ArgumentError("Runner group '$(name)' must set `max_slots` to at least 1"))
    priority = Int(get(config, "priority", 10))
    tags = get(config, "tags", Dict{String,String}())
    start_rootless_docker = get(config, "start_rootless_docker", false)
    platform = parse(Platform, get(config, "platform", triplet(HostPlatform())))
    guest = get(config, "guest", nothing)
    guest = guest === nothing ? nothing : string(guest)
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
        length(queues) == 1 ||
            throw(ArgumentError("Runner group '$(name)' serves several queues, each with its own stack; it cannot set `stack_key`"))
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
    elseif guest !== nothing
        throw(ArgumentError("Runner group '$(name)' sets `guest`, but `guest` is only valid for backend '$(BACKEND_KVM)'"))
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
        # Transitional: jobs are no longer pinned to cpusets, but julia-buildkite
        # still requires this tag on its Linux test steps. Remove it once no
        # queued job queries it.
        tags["cpuset_limited"] = "true"
    end

    return BuildkiteRunnerGroup(
        string(name),
        backend,
        queues,
        tags,
        start_rootless_docker,
        size,
        max_threads,
        max_mem_gib,
        max_slots,
        priority,
        platform,
        guest,
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
                total_cpus=scheduler_config.total_cpus,
                total_mem_gib=scheduler_config.total_mem_gib, kwargs...)
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
