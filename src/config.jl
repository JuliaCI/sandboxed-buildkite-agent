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
    "metrics_dir",
    "io_accounting",
    "cache_retention",
    "disk_check_interval",
    "disk_high_water_percent",
    "disk_low_water_percent",
    "disks",
    "cache_max_age_days",
    "cache_retired_days",
    "ccache_max_size_gb",
])
const DISK_CONFIG_KEYS = Set(["high_water_percent", "low_water_percent"])
const DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS = 12 * 60 * 60.0
const RUNNER_GROUP_CONFIG_KEYS = Set([
    "backend",
    "queues",
    "tags",
    "default",
    "max_slots",
    "max_cpus",
    "max_mem_gib",
    "priority",
    "min_job_age",
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

# Eviction thresholds of one filesystem; `nothing` takes the scheduler-wide value.
struct DiskThresholds
    high_water_percent::Union{Nothing,Float64}
    low_water_percent::Union{Nothing,Float64}
end

# How the scheduler keeps its cache roots from filling their filesystems; see
# retention.jl.
struct RetentionConfig
    # Whether pools are evicted and reset; leases and last-use stamps are kept
    # either way.
    enabled::Bool
    # Seconds between free-space checks.
    check_interval::Float64
    defaults::DiskThresholds
    # Overrides by a path on the filesystem they apply to.
    disks::Dict{String,DiskThresholds}
    # Pools are reset after this many days (staggered per pool); 0 never.
    max_age_days::Float64
    # Pipelines whose pools were not used for this many days are evicted first.
    retired_days::Float64
    # `max_size` sba writes into a shared pool's `ccache/ccache.conf`; 0 none.
    ccache_max_size_gb::Int
end

RetentionConfig(; enabled::Bool=true, check_interval::Real=60.0,
                defaults::DiskThresholds=DiskThresholds(85.0, 75.0),
                disks::AbstractDict=Dict{String,DiskThresholds}(),
                max_age_days::Real=14.0, retired_days::Real=7.0,
                ccache_max_size_gb::Integer=50) =
    RetentionConfig(enabled, Float64(check_interval), defaults,
        Dict{String,DiskThresholds}(disks), Float64(max_age_days), Float64(retired_days),
        Int(ccache_max_size_gb))

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
    # node_exporter textfile directory for `sandboxed_buildkite_agent.prom`;
    # `nothing` writes no metrics.
    metrics_dir::Union{Nothing,String}
    # Whether Linux job cgroups get the io controller, for their records' I/O
    # figures; off undoes that on a host where cgroup writeback misbehaves.
    io_accounting::Bool
    retention::RetentionConfig
end

SchedulerConfig(logdir::String, poll_interval::Float64, error_sleep::Float64,
                reservation_expiry_seconds::Int, assignment_timeout_seconds::Float64,
                total_cpus::Int, total_mem_gib::Int, min_mem_available_gib::Int,
                metrics_dir::Union{Nothing,String}=nothing, io_accounting::Bool=true) =
    SchedulerConfig(logdir, poll_interval, error_sleep, reservation_expiry_seconds,
        assignment_timeout_seconds, total_cpus, total_mem_gib, min_mem_available_gib,
        metrics_dir, io_accounting, RetentionConfig())

host_mem_gib() = Int(fld(Sys.total_physical_memory(), 1024^3))

# Memory sizes are given in GiB and written to the kernel in bytes; a larger
# value would wrap around (2^34 GiB is 0 bytes, which leaves `memory.max` unset).
const MAX_MEM_GIB = typemax(Int) ÷ 1024^3
gib_bytes(gib::Integer) = Base.checked_mul(Int(gib), 1024^3)

# The host's logical CPUs: the default and the upper bound of `total_cpus`.
# On Apple Silicon, Julia 1.10's `Sys.CPU_THREADS` counts only the performance
# cores (4 of an M2's 8), so ask the OS for all of them.
function host_cpu_count()
    Sys.isapple() || return Sys.CPU_THREADS
    count = tryparse(Int, strip(read(`sysctl -n hw.logicalcpu`, String)))
    return count === nothing || count < 1 ? Sys.CPU_THREADS : count
end

SchedulerConfig(logdir::String, poll_interval::Real, error_sleep::Real,
                reservation_expiry_seconds::Integer,
                assignment_timeout_seconds::Real=DEFAULT_ASSIGNMENT_TIMEOUT_SECONDS,
                total_cpus::Integer=host_cpu_count()) =
    SchedulerConfig(logdir, Float64(poll_interval), Float64(error_sleep),
        Int(reservation_expiry_seconds), Float64(assignment_timeout_seconds),
        Int(total_cpus), host_mem_gib(), 0)

# 5% of physical memory, so that a host needs no floor of its own. It must stay
# below `total_mem_gib`; macOS has no MemAvailable, so no brake.
function default_min_mem_available_gib(total_mem_gib::Integer; host::Symbol=host_os())
    host == :linux || return 0
    return clamp(cld(host_mem_gib(), 20), 0, total_mem_gib - 1)
end

function SchedulerConfig(config::Dict; config_dir::AbstractString = pwd())
    unknown_keys = setdiff(string.(collect(keys(config))), SCHEDULER_CONFIG_KEYS)
    isempty(unknown_keys) ||
        throw(ArgumentError("Unknown scheduler config key(s): $(join(sort(unknown_keys), ", "))"))

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

    host_cpus = host_cpu_count()
    total_cpus = Int(get(config, "total_cpus", host_cpus))
    if total_cpus < 1 || total_cpus > host_cpus
        throw(ArgumentError("Scheduler config `total_cpus` must be between 1 and the host's logical CPUs ($(host_cpus))"))
    end

    total_mem_gib = Int(get(config, "total_mem_gib", host_mem_gib()))
    if total_mem_gib < 1 || total_mem_gib > host_mem_gib()
        throw(ArgumentError("Scheduler config `total_mem_gib` must be between 1 and the host's memory ($(host_mem_gib()) GiB)"))
    end
    min_mem_available_gib = Int(get(config, "min_mem_available_gib",
        default_min_mem_available_gib(total_mem_gib)))
    if min_mem_available_gib < 0 || min_mem_available_gib >= total_mem_gib
        throw(ArgumentError("Scheduler config `min_mem_available_gib` must be between 0 and `total_mem_gib`"))
    end

    metrics_dir = haskey(config, "metrics_dir") ?
        abspath(config_dir, string(config["metrics_dir"])) : nothing

    io_accounting = get(config, "io_accounting", true)
    io_accounting isa Bool ||
        throw(ArgumentError("Scheduler config `io_accounting` must be true or false"))

    retention = parse_retention_config(config)

    return SchedulerConfig(
        path_config("logdir", nothing, "agent-logs"),
        poll_interval,
        error_sleep,
        reservation_expiry_seconds,
        assignment_timeout_seconds,
        total_cpus,
        total_mem_gib,
        min_mem_available_gib,
        metrics_dir,
        io_accounting,
        retention,
    )
end

function parse_percent(value, what)
    value isa Real && isfinite(value) && 0 < value <= 100 ||
        throw(ArgumentError("$(what) must be a percentage above 0 and at most 100"))
    return Float64(value)
end

function parse_disk_thresholds(config::AbstractDict, what::AbstractString; prefix::AbstractString="")
    high = haskey(config, "$(prefix)high_water_percent") ?
        parse_percent(config["$(prefix)high_water_percent"], "$(what) `$(prefix)high_water_percent`") : nothing
    low = haskey(config, "$(prefix)low_water_percent") ?
        parse_percent(config["$(prefix)low_water_percent"], "$(what) `$(prefix)low_water_percent`") : nothing
    return DiskThresholds(high, low)
end

function check_water_marks(high::Float64, low::Float64, what::AbstractString)
    low <= high ||
        throw(ArgumentError("$(what): the low-water mark ($(low)%) must not be above the high-water mark ($(high)%)"))
    return nothing
end

function parse_retention_config(config::AbstractDict)
    enabled = get(config, "cache_retention", true)
    enabled isa Bool ||
        throw(ArgumentError("Scheduler config `cache_retention` must be true or false"))
    check_interval = get(config, "disk_check_interval", 60)
    check_interval isa Real && isfinite(check_interval) && check_interval > 0 ||
        throw(ArgumentError("Scheduler config `disk_check_interval` must be a positive number of seconds"))
    given = parse_disk_thresholds(config, "Scheduler config"; prefix="disk_")
    defaults = DiskThresholds(something(given.high_water_percent, 85.0),
        something(given.low_water_percent, 75.0))
    check_water_marks(defaults.high_water_percent, defaults.low_water_percent, "Scheduler config")

    disks = Dict{String,DiskThresholds}()
    tables = get(config, "disks", Dict{String,Any}())
    tables isa AbstractDict ||
        throw(ArgumentError("Scheduler config `disks` must be a table of tables, one per filesystem path"))
    for (path, table) in tables
        what = "Scheduler config `disks.\"$(path)\"`"
        isabspath(path) || throw(ArgumentError("$(what): the path must be absolute"))
        table isa AbstractDict || throw(ArgumentError("$(what) must be a table"))
        unknown = setdiff(string.(collect(keys(table))), DISK_CONFIG_KEYS)
        isempty(unknown) ||
            throw(ArgumentError("$(what) has unknown key(s): $(join(sort(unknown), ", "))"))
        thresholds = parse_disk_thresholds(table, what)
        check_water_marks(something(thresholds.high_water_percent, defaults.high_water_percent),
            something(thresholds.low_water_percent, defaults.low_water_percent), what)
        disks[normpath(path)] = thresholds
    end

    max_age_days = get(config, "cache_max_age_days", 14)
    max_age_days isa Real && isfinite(max_age_days) && max_age_days >= 0 ||
        throw(ArgumentError("Scheduler config `cache_max_age_days` must be a non-negative number of days"))
    retired_days = get(config, "cache_retired_days", 7)
    retired_days isa Real && isfinite(retired_days) && retired_days > 0 ||
        throw(ArgumentError("Scheduler config `cache_retired_days` must be a positive number of days"))
    ccache_max_size_gb = get(config, "ccache_max_size_gb", 50)
    ccache_max_size_gb isa Integer && ccache_max_size_gb >= 0 ||
        throw(ArgumentError("Scheduler config `ccache_max_size_gb` must be a non-negative integer"))
    return RetentionConfig(; enabled, check_interval, defaults, disks, max_age_days,
        retired_days, ccache_max_size_gb)
end

# The size of one job, as a request and a limit per resource. `cpus` is charged
# against the host's CPUs; `cpus_limit` is how many CPUs the job may run on (its
# cpuset, `SBA_CPUS_LIMIT`, KVM vCPUs). `mem_gib` is what the job typically
# uses, charged against `total_mem_gib` for native jobs (KVM guests are charged
# their RAM plus overhead); `mem_limit_gib` is its Linux `memory.max` or KVM
# guest RAM (0 is unlimited on Linux). Limits default to their request.
struct JobSize
    cpus::Int
    cpus_limit::Int
    mem_gib::Int
    mem_limit_gib::Int
end

JobSize(cpus::Integer, cpus_limit::Integer, mem_gib::Integer) =
    JobSize(cpus, cpus_limit, mem_gib, mem_gib)

const JOB_SIZE_KEYS = Set(["cpus", "cpus_limit", "mem_gib", "mem_limit_gib"])

struct BuildkiteRunnerGroup
    # Group name, such as "surrogatization"
    name::String

    # Scheduler backend used to run this group.
    backend::String

    # The queues this group serves, each through its own Buildkite stack.
    queues::Vector{String}

    # Any extra tags to be applied
    tags::Dict{String,String}

    # The size of jobs whose step sets no `sched_*` tags, per queue
    # (`queue_defaults`) or for the whole group (`default`); without either,
    # such jobs are failed. On macOS, `default` is the whole host, and every
    # untagged job gets it.
    default::Union{JobSize,Nothing}
    queue_defaults::Dict{String,JobSize}
    # KVM only: bounds on the vCPUs and guest RAM a tagged job can ask for
    # (host and image facts, not policy); 0 is unbounded.
    max_cpus::Int
    max_mem_gib::Int
    # At most this many jobs at once; 0 is unbounded, which only a group whose
    # every job is charged CPUs or memory may be (the host's CPU and memory then
    # bound it). Slots are created as needed and keep their caches.
    max_slots::Int
    priority::Int
    # Seconds a job must have been scheduled on Buildkite before this group
    # takes it, so that hosts with a lower value get the job first.
    min_job_age::Float64

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

function parse_job_size(name, config, backend::AbstractString; total_cpus::Integer,
                        table::AbstractString="default")
    config isa AbstractDict ||
        throw(ArgumentError("Runner group '$(name)' must make `$(table)` a table"))
    unknown = setdiff(string.(collect(keys(config))), JOB_SIZE_KEYS)
    isempty(unknown) ||
        throw(ArgumentError("Runner group '$(name)' has unknown `$(table)` key(s): $(join(sort(unknown), ", "))"))
    haskey(config, "cpus") ||
        throw(ArgumentError("Runner group '$(name)' must set `cpus` in its `$(table)`"))
    cpus = Int(config["cpus"])
    0 <= cpus <= total_cpus ||
        throw(ArgumentError("Runner group '$(name)' must give jobs between 0 and `total_cpus=$(total_cpus)` CPUs"))
    backend == BACKEND_LINUX_SANDBOX || cpus >= 1 ||
        throw(ArgumentError("Runner group '$(name)' with backend '$(backend)' must give jobs at least 1 CPU"))
    cpus_limit = Int(get(config, "cpus_limit", cpus))
    mem_gib = Int(get(config, "mem_gib", 0))
    mem_limit_gib = Int(get(config, "mem_limit_gib", mem_gib))
    for (key, value) in (("cpus_limit", cpus_limit), ("mem_gib", mem_gib), ("mem_limit_gib", mem_limit_gib))
        haskey(config, key) && value < 1 &&
            throw(ArgumentError("Runner group '$(name)' must set `$(key)` to at least 1"))
    end
    for (key, value) in (("mem_gib", mem_gib), ("mem_limit_gib", mem_limit_gib))
        value <= MAX_MEM_GIB ||
            throw(ArgumentError("Runner group '$(name)' sets `$(key)` above $(MAX_MEM_GIB) GiB"))
    end
    for (limit, request, l, r) in (("cpus_limit", "cpus", cpus_limit, cpus),
                                   ("mem_limit_gib", "mem_gib", mem_limit_gib, mem_gib))
        l < r && throw(ArgumentError("Runner group '$(name)' sets `$(limit)` below `$(request)` in its `$(table)`"))
    end
    backend == BACKEND_KVM && mem_limit_gib < 1 &&
        throw(ArgumentError("KVM runner group '$(name)' must set the guest's `mem_gib` or `mem_limit_gib` in its `$(table)`"))
    return JobSize(cpus, cpus_limit, mem_gib, mem_limit_gib)
end

# `[group.default]` holds the size keys for the whole group, and/or one table per
# queue (`[group.default.build]`). Each table is a complete size: a queue's table
# does not inherit keys from the group's.
function parse_job_defaults(name, config, backend::AbstractString, queues::Vector{String};
                            total_cpus::Integer)
    config isa AbstractDict ||
        throw(ArgumentError("Runner group '$(name)' must make `default` a table"))
    keys_ = string.(collect(keys(config)))
    unknown = setdiff(keys_, JOB_SIZE_KEYS, queues)
    isempty(unknown) ||
        throw(ArgumentError("Runner group '$(name)' has unknown `default` key(s): $(join(sort(unknown), ", ")); expected $(join(sort(collect(JOB_SIZE_KEYS)), ", ")) or a table per queue ($(join(queues, ", ")))"))
    queue_defaults = Dict{String,JobSize}()
    for queue in intersect(keys_, queues)
        queue_defaults[queue] = parse_job_size(name, config[queue], backend; total_cpus,
            table="default.$(queue)")
    end
    group_config = Dict(key => config[key] for key in intersect(keys_, JOB_SIZE_KEYS))
    default = !isempty(group_config) || isempty(queue_defaults) ?
        parse_job_size(name, group_config, backend; total_cpus) : nothing
    return default, queue_defaults
end

function BuildkiteRunnerGroup(name::String, config::Dict;
                              extra_tags::Dict{String,String} = Dict{String,String}(),
                              config_dir::AbstractString = pwd(),
                              host::Symbol = host_os(),
                              total_cpus::Integer = host_cpu_count(),
                              total_mem_gib::Integer = host_mem_gib())
    unknown_keys = setdiff(string.(collect(keys(config))), RUNNER_GROUP_CONFIG_KEYS)
    isempty(unknown_keys) ||
        throw(ArgumentError("Runner group '$(name)' has unknown key(s): $(join(sort(unknown_keys), ", "))"))

    backend_value = haskey(config, "backend") ? config["backend"] : default_backend(host)
    backend = parse_backend(backend_value, host)
    queues = parse_queues(name, get(config, "queues", ["build", "test"]))

    # Untagged macOS jobs get the whole host, its CPUs and its memory: the
    # seatbelt does not isolate concurrent jobs, so only steps that declare a
    # size with `sched_*` tags share a Mac.
    if backend == BACKEND_MACOS_SEATBELT
        haskey(config, "default") &&
            throw(ArgumentError("macOS runner group '$(name)' cannot set `default`: its untagged jobs get the whole host"))
        default, queue_defaults = JobSize(total_cpus, total_cpus, total_mem_gib), Dict{String,JobSize}()
    elseif haskey(config, "default")
        default, queue_defaults =
            parse_job_defaults(name, config["default"], backend, queues; total_cpus)
    else
        default, queue_defaults = nothing, Dict{String,JobSize}()
    end
    defaults = default === nothing ? collect(values(queue_defaults)) :
        [default; collect(values(queue_defaults))]

    max_cpus = Int(get(config, "max_cpus", 0))
    max_mem_gib = Int(get(config, "max_mem_gib", 0))
    for (key, value) in (("max_cpus", max_cpus), ("max_mem_gib", max_mem_gib))
        haskey(config, key) || continue
        backend == BACKEND_KVM ||
            throw(ArgumentError("Runner group '$(name)' sets `$(key)`, which only applies to backend '$(BACKEND_KVM)'"))
        value >= 1 || throw(ArgumentError("Runner group '$(name)' must set `$(key)` to at least 1"))
        key == "max_mem_gib" && value > MAX_MEM_GIB &&
            throw(ArgumentError("Runner group '$(name)' sets `$(key)` above $(MAX_MEM_GIB) GiB"))
    end
    if backend == BACKEND_KVM
        largest = max_mem_gib > 0 ? max_mem_gib : maximum(size -> size.mem_limit_gib, defaults; init=0)
        kvm_reserved_mem_gib(largest) <= total_mem_gib ||
            throw(ArgumentError("Runner group '$(name)' could reserve $(kvm_reserved_mem_gib(largest)) GiB for one guest ($(largest) GiB plus host overhead), exceeding scheduler `total_mem_gib=$(total_mem_gib)`"))
    else
        # Native jobs are charged their memory request; a default larger than
        # the host would leave every untagged job of the group unrunnable.
        largest = maximum(size -> size.mem_gib, defaults; init=0)
        largest <= total_mem_gib ||
            throw(ArgumentError("Runner group '$(name)' has a `default` with `mem_gib=$(largest)`, exceeding scheduler `total_mem_gib=$(total_mem_gib)`: its untagged jobs could never run"))
    end

    # The host's CPUs and memory bound how many jobs of a group run, unless its
    # untagged jobs are charged neither (only Linux allows `cpus = 0`): then
    # only slots do. Tagged jobs always request both.
    charged = all(size -> size.cpus > 0 || size.mem_gib > 0, defaults)
    max_slots = if haskey(config, "max_slots")
        value = Int(config["max_slots"])
        value >= 1 ||
            throw(ArgumentError("Runner group '$(name)' must set `max_slots` to at least 1"))
        value
    elseif charged
        0
    else
        throw(ArgumentError("Runner group '$(name)' must set `max_slots`: its `default` charges neither CPUs nor memory, so nothing else bounds how many of its jobs run"))
    end
    priority = Int(get(config, "priority", 10))
    min_job_age = get(config, "min_job_age", 0)
    min_job_age isa Real && isfinite(min_job_age) && min_job_age >= 0 ||
        throw(ArgumentError("Runner group '$(name)' must set `min_job_age` to a non-negative number of seconds"))
    tags = get(config, "tags", Dict{String,String}())
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
    # julia-buildkite's Linux test steps on release branches require this tag.
    # Linux jobs run in a cgroup cpuset of `cpus_limit` CPUs (see
    # `pin_job_cpus!`), except untagged jobs of a default without a CPU limit;
    # KVM guests see only their vCPUs.
    if backend == BACKEND_KVM ||
            (backend == BACKEND_LINUX_SANDBOX && all(size -> size.cpus_limit > 0, defaults))
        tags["cpuset_limited"] = "true"
    end

    return BuildkiteRunnerGroup(
        string(name),
        backend,
        queues,
        tags,
        default,
        queue_defaults,
        max_cpus,
        max_mem_gib,
        max_slots,
        priority,
        Float64(min_job_age),
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

# Read only the [scheduler] table.  Deliberately skips building the runner
# groups so `sba status`/`sba logs` keep working when a group is misconfigured.
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
configured_tempdir(brg::BuildkiteRunnerGroup) = brg.tempdir_path
default_size(brg::BuildkiteRunnerGroup, queue::AbstractString) =
    get(brg.queue_defaults, queue, brg.default)
