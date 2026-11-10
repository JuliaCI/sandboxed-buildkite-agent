# This only exists so that we can avoid compile-time-checking of lazy artifact loading
artifact_lookup(name) = @artifact_str(name)

# A running job's cpuset and the load it is expected to put on each of those
# CPUs: its CPU request spread over the set.
struct PinnedCPUs
    cpus::Vector{Int}
    load::Float64
end

PinnedCPUs(cpus::AbstractVector{<:Integer}; request::Real=length(cpus)) =
    PinnedCPUs(collect(Int, cpus), isempty(cpus) ? 0.0 : request / length(cpus))

mutable struct LinuxSandboxBackend <: PlatformBackend
    logdir::String
    root::String
    cleanup_paths::Vector{String}
    # The CPUs jobs may be placed on: the scheduler cgroup's `cpuset.cpus.effective`.
    cpus::Vector{Int}
    # The cpuset of each running job, by job cgroup path.
    pinned::Dict{String,PinnedCPUs}
    pinned_lock::ReentrantLock
    # Whether job cgroups get the io controller (`io_accounting`), and whether
    # turning it off failed, so that they still do.
    io_accounting::Bool
    io_accounting_stuck::Bool

    LinuxSandboxBackend(logdir::String; io_accounting::Bool=true) =
        new(logdir, "", String[], Int[], Dict{String,PinnedCPUs}(), ReentrantLock(), io_accounting, false)
end

# The `n` least-loaded CPUs of `allowed`, given the running jobs' cpusets, so
# concurrent jobs get disjoint CPUs while there are enough. Once sets must
# overlap, a CPU under a wide, lightly charged set (a 4-CPU build on 16) is
# preferred over one under a set its job fills (an 8-CPU test on 8). Ties go to
# the CPU in fewer sets, then the lowest.
function choose_job_cpus(pinned, n::Integer, allowed::AbstractVector{<:Integer})
    load = Dict{Int,Float64}(cpu => 0.0 for cpu in allowed)
    use = Dict{Int,Int}(cpu => 0 for cpu in allowed)
    for p in pinned, cpu in p.cpus
        haskey(use, cpu) || continue
        load[cpu] += p.load
        use[cpu] += 1
    end
    chosen = sort(collect(keys(use)); by=cpu -> (load[cpu], use[cpu], cpu))
    return sort!(chosen[1:min(Int(n), length(chosen))])
end

# Every job runs on a cpuset of `cpus_limit` CPUs. Julia's `--threads auto`,
# libuv's available parallelism and `nproc` follow the CPU affinity, which the
# cpuset bounds, not `JULIA_CPU_THREADS`: an unconstrained job sees every host
# CPU (an i686 test process then starts a thread per CPU and runs out of
# address space). The cpuset bounds a job's width, not its share: overlapping
# sets are fine, and `cpu.weight` still divides the CPUs under contention.
# Unlike an affinity mask set by a wrapper, the kernel enforces it for every
# process of the job, and pinning a thread outside it fails instead of escaping.
function pin_job_cpus!(backend::LinuxSandboxBackend, key::String, n::Integer;
                       request::Real=n, allowed::AbstractVector{<:Integer}=backend.cpus)
    lock(backend.pinned_lock) do
        cpus = choose_job_cpus(values(backend.pinned), n, allowed)
        backend.pinned[key] = PinnedCPUs(cpus; request)
        return cpus
    end
end

unpin_job_cpus!(backend::LinuxSandboxBackend, key::String) =
    lock(() -> (delete!(backend.pinned, key); nothing), backend.pinned_lock)

# A cgroup CPU list such as "0-3,8,10-11".
function parse_cpu_list(text::AbstractString)
    cpus = Int[]
    for part in split(strip(text), ','; keepempty=false)
        bounds = split(part, '-')
        length(bounds) <= 2 || throw(ArgumentError("invalid CPU list '$(text)'"))
        append!(cpus, parse(Int, bounds[1]):parse(Int, bounds[end]))
    end
    return sort!(unique!(cpus))
end

format_cpu_list(cpus) = join(sort(collect(cpus)), ",")

function check_linux_sandbox_runner_configs(brgs::Vector{BuildkiteRunnerGroup})
    for brg in brgs
        tagtrue(brg, name) = get(brg.tags, name, "false") == "true"

        # Check that we self-identify as `sandbox.jl`
        if !tagtrue(brg, "sandbox_capable")
            error("Refusing to start up `sandbox.jl` runner '$(brg.name)' that does not self-identify through tags!")
        end
    end
    return nothing
end

# Each job gets a cgroup namespace rooted at its job cgroup. Only with nsdelegate
# does the kernel treat that namespace as a delegation boundary: without it, a job
# that mounts cgroup2 for a namespace of its own can still raise its own limits.
# systemd mounts cgroup2 with nsdelegate by default; only root can change it.
function check_cgroup_nsdelegate(; mounts_file::String="/proc/self/mounts",
                                 cgroup_mount::String="/sys/fs/cgroup")
    # The last mount at that path is the one that covers the others.
    fields = nothing
    for line in eachline(mounts_file)
        f = split(line)
        length(f) >= 4 && f[2] == cgroup_mount && (fields = f)
    end
    fields !== nothing && fields[3] == "cgroup2" ||
        error("No cgroup2 hierarchy is mounted at $(cgroup_mount)")
    "nsdelegate" in split(fields[4], ',') ||
        error("cgroup2 at $(cgroup_mount) is mounted without nsdelegate, so jobs could change ",
              "their own cgroup limits; remount it with `mount -o remount,nsdelegate $(cgroup_mount)`")
    return nothing
end

function check_linux_host_config()
    check_coredumps()
    check_zen_workaround()
    check_sysctl_params()
    check_cgroup_nsdelegate()
    return nothing
end

function setup_linux_host_config!()
    setup_coredumps()
    setup_zen_workaround()
    setup_sysctl_params()
    check_linux_host_config()
    return nothing
end

function check_linux_sandbox_configs(brgs::Vector{BuildkiteRunnerGroup})
    check_linux_sandbox_runner_configs(brgs)
    check_linux_host_config()
    return nothing
end

function setup_linux_sandbox_configs!(brgs::Vector{BuildkiteRunnerGroup})
    check_linux_sandbox_runner_configs(brgs)
    setup_linux_host_config!()
    return nothing
end

check_config(::LinuxSandboxBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    check_linux_sandbox_configs(brgs)

setup_config!(::LinuxSandboxBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    setup_linux_sandbox_configs!(brgs)

function scheduler_cgroup_root(;
                               cgroup_file::String="/proc/self/cgroup",
                               cgroup_mount::String="/sys/fs/cgroup")
    for line in eachline(cgroup_file)
        if startswith(line, "0::")
            rel = chomp(line[4:end])
            return rel == "/" ? cgroup_mount : string(cgroup_mount, rel)
        end
    end
    error("Unable to resolve scheduler cgroup root from $(cgroup_file)")
end

function cgroup_controllers(root::String)
    controllers_path = joinpath(root, "cgroup.controllers")
    isfile(controllers_path) || error("$(root) is not a cgroup-v2 directory")
    return Set(split(strip(read(controllers_path, String))))
end

function require_cgroup_controllers(root::String, controllers)
    missing_controllers = setdiff(controllers, cgroup_controllers(root))
    if !isempty(missing_controllers)
        error("Linux scheduler unit needs Delegate=$(join(controllers, ' ')) (missing: $(join(sort(collect(missing_controllers)), ' '))); run `sba reinstall`")
    end
    return nothing
end

# The scheduler and its backend tasks get the weight of ten CPUs, so job load
# cannot starve polling, process supervision and cgroup teardown.
const SUPERVISOR_CPU_WEIGHT = 1000

# cgroup v2's default weight is 100; a job gets that much per requested CPU, so
# under contention CPU time is shared in proportion to requests while idle CPUs
# remain available to any job. Jobs of groups that charge no CPUs weigh as one.
job_cpu_weight(cpus::Integer) = clamp(100 * max(Int(cpus), 1), 1, 10_000)

const JOB_CGROUP_CONTROLLERS = ["cpu", "cpuset", "memory"]
# Enabled where the scheduler's cgroup has them, for the resource records
# (`pids.peak`, `io.stat`), without explicit limits or weights: no `pids.max`,
# `io.max` or `io.weight` is set. io is accounting but not free of effects:
# with BFQ's group scheduling, job cgroups share a disk in proportion to their
# default weights, and cgroup writeback attributes each job's dirty pages to it
# and balances their writeback per cgroup. `io_accounting = false` turns it off.
const JOB_CGROUP_ACCOUNTING_CONTROLLERS = ["pids", "io"]

# Enable those of them `root` offers (io only with `io_accounting`); returns
# the ones enabled. Not enabling io does not disable it: a cgroup that
# outlived a restart keeps it, see `disable_io_accounting!`.
function enable_accounting_controllers!(root::String; io_accounting::Bool=true)
    enabled = String[]
    wanted = filter(c -> io_accounting || c != "io", JOB_CGROUP_ACCOUNTING_CONTROLLERS)
    for controller in intersect(wanted, cgroup_controllers(root))
        try
            write(joinpath(root, "cgroup.subtree_control"), "+$(controller)\n")
            push!(enabled, controller)
        catch err
            @warn("Unable to enable the $(controller) controller for job cgroups; records go without it",
                root, exception=err)
        end
    end
    return enabled
end

# Enables the job cgroups' controllers below `root` and returns the CPUs jobs
# may be placed on. Without the cpuset controller jobs would run unconstrained
# (see `pin_job_cpus!`), so its absence stops the scheduler.
# Turn io off for job cgroups created from now on, for `io_accounting =
# false`. Whether it worked: the kernel refuses while a child cgroup still
# uses the controller, so this goes after the stale job cgroups are removed.
function disable_io_accounting!(root::String)
    control = joinpath(root, "cgroup.subtree_control")
    enabled() = "io" in split(read(control, String))
    try
        enabled() || return true
        write(control, "-io\n")
        return !enabled()
    catch err
        @warn("Unable to disable the io controller for job cgroups", root, exception=err)
        return false
    end
end

function setup_job_cgroups!(root::String; io_accounting::Bool=true)
    require_cgroup_controllers(root, JOB_CGROUP_CONTROLLERS)
    supervisor = joinpath(root, "supervisor")
    mkpath(supervisor)
    write(joinpath(supervisor, "cgroup.procs"), string(getpid(), "\n"))
    write(joinpath(root, "cgroup.subtree_control"),
        join(string.("+", JOB_CGROUP_CONTROLLERS), " ") * "\n")
    enabled = split(read(joinpath(root, "cgroup.subtree_control"), String))
    missing_controllers = setdiff(JOB_CGROUP_CONTROLLERS, enabled)
    isempty(missing_controllers) ||
        error("Unable to enable the $(join(missing_controllers, ", ")) controller(s) for job cgroups in $(root)")
    enable_accounting_controllers!(root; io_accounting)
    write(joinpath(supervisor, "cpu.weight"), string(SUPERVISOR_CPU_WEIGHT, "\n"))
    cpus = parse_cpu_list(read(joinpath(root, "cpuset.cpus.effective"), String))
    isempty(cpus) && error("The scheduler's cgroup $(root) has no CPUs in cpuset.cpus.effective")
    return cpus
end

has_swap_accounting(cgroup::String) = isfile(joinpath(cgroup, "memory.swap.max"))

function create_job_cgroup(root::String, name::String; cpus::Integer=0, mem_bytes::Integer=0,
                           cpuset::AbstractVector{<:Integer}=Int[])
    job_root = joinpath(root, name)
    mkpath(job_root)
    try
        write(joinpath(job_root, "cpu.weight"), string(job_cpu_weight(cpus), "\n"))
        isempty(cpuset) || write(joinpath(job_root, "cpuset.cpus"), format_cpu_list(cpuset) * "\n")
        if mem_bytes > 0
            write(joinpath(job_root, "memory.max"), string(mem_bytes, "\n"))
            # Without this, a job over its limit swaps instead of being OOM-killed,
            # and its paging slows down every other job on the host.  Kernels booted
            # without swap accounting (5.4 on the POWER9 hosts) have no
            # `memory.swap.*` files; there the job may still swap past its limit.
            if has_swap_accounting(root)
                write(joinpath(job_root, "memory.swap.max"), "0\n")
            end
            # No `memory.oom.group`: the job's agent shares this cgroup, and killing
            # it along with the job loses the job's log and exit status. The kernel
            # picks the largest process instead, and the agent reports the failure.
        end
    catch
        # Nothing runs in it yet, so it can be removed right away.
        remove_job_cgroup(job_root)
        rethrow()
    end
    return job_root
end

# Integer counters from a cgroup file of "key value" lines (`memory.stat`,
# `memory.events`); empty if the file is missing.
function cgroup_counters(path::AbstractString, file::AbstractString)
    counters = Dict{String,Int}()
    filepath = joinpath(path, file)
    isfile(filepath) || return counters
    for line in eachline(filepath)
        fields = split(line)
        length(fields) == 2 || continue
        value = tryparse(Int, fields[2])
        value === nothing || (counters[fields[1]] = value)
    end
    return counters
end

cgroup_memory_events(path::AbstractString) = cgroup_counters(path, "memory.events")

# Record OOM kills before the cgroup and its counters disappear.
function log_job_oom_events(path::AbstractString; log_path::Union{Nothing,String}=nothing)
    events = cgroup_memory_events(path)
    get(events, "oom_kill", 0) > 0 || get(events, "oom", 0) > 0 || return nothing
    limit = try
        strip(read(joinpath(path, "memory.max"), String))
    catch
        "unknown"
    end
    @warn("Job hit its memory limit", cgroup=path, memory_max=limit,
        oom=get(events, "oom", 0), oom_kill=get(events, "oom_kill", 0))
    if log_path !== nothing
        try
            open(log_path, "a") do log
                println(log, "sandboxed-buildkite-agent: the job hit its memory limit ",
                    "(memory.max=$(limit)); the kernel OOM-killed $(get(events, "oom_kill", 0)) process(es).")
            end
        catch
        end
    end
    return nothing
end

const LINUX_CGROUP_REMOVE_TIMEOUT = 5.0
# How long killing a job's processes may take before its teardown counts as failed.
const LINUX_CGROUP_KILL_TIMEOUT = 10.0

#
# Job resource usage
#

# What a cgroup v2 directory says about the processes in it, for the records'
# details: the job cgroup on Linux, a guest's whole domain on KVM. Counters are
# cumulative since the cgroup was created. Gauges have a kernel-kept peak only
# on newer kernels (`memory.peak` 5.19+, `pids.peak` 6.1+); elsewhere the
# sampled maximum stands in, and the record says which it is. Files a kernel
# lacks leave their fields out. Only file reads, so cheap enough every sample.
mutable struct CgroupPeaks
    memory_current::Union{Nothing,Int}
    anon::Union{Nothing,Int}
    file::Union{Nothing,Int}
    shmem::Union{Nothing,Int}
    kernel::Union{Nothing,Int}
    pids::Union{Nothing,Int}
end

CgroupPeaks() = CgroupPeaks(nothing, nothing, nothing, nothing, nothing, nothing)

# Update the sampled maxima; `stat` is `memory.stat` if already read.
function sample_cgroup_peaks!(peaks::CgroupPeaks, path::AbstractString;
                              stat=try_read(() -> cgroup_counters(path, "memory.stat"), Dict{String,Int}()))
    peaks.memory_current = maxpeak(peaks.memory_current, try_read(() -> cgroup_bytes(path, "memory.current"), nothing))
    peaks.anon = maxpeak(peaks.anon, get(stat, "anon", nothing))
    peaks.file = maxpeak(peaks.file, get(stat, "file", nothing))
    peaks.shmem = maxpeak(peaks.shmem, get(stat, "shmem", nothing))
    isempty(stat) || (peaks.kernel = maxpeak(peaks.kernel,
        sum(get(stat, key, 0) for key in UNRECLAIMABLE_KERNEL_STATS)))
    peaks.pids = maxpeak(peaks.pids, try_read(() -> cgroup_bytes(path, "pids.current"), nothing))
    return peaks
end

# A PSI file's "some" and "full" totals, in seconds.
function cgroup_pressure_totals(path::AbstractString, file::AbstractString)
    totals = Dict{String,Float64}()
    filepath = joinpath(path, file)
    isfile(filepath) || return totals
    for line in eachline(filepath)
        m = match(r"^(some|full) .*total=(\d+)", line)
        m === nothing || (totals[m[1]] = round(parse(Int, m[2]) / 1e6; digits=1))
    end
    return totals
end

const CGROUP_IO_FIELDS = Dict("rbytes" => "read_bytes", "wbytes" => "write_bytes",
                              "rios" => "read_ops", "wios" => "write_ops")

# `io.stat`'s read and write bytes and operations, summed over devices.
function cgroup_io_totals(path::AbstractString)
    totals = Dict{String,Int}()
    filepath = joinpath(path, "io.stat")
    isfile(filepath) || return totals
    for line in eachline(filepath), field in split(line)[2:end]
        parts = split(field, '='; limit=2)
        length(parts) == 2 || continue
        key, value = parts
        name = get(CGROUP_IO_FIELDS, key, nothing)
        n = tryparse(Int, value)
        (name === nothing || n === nothing) && continue
        totals[name] = get(totals, name, 0) + n
    end
    return totals
end

function cgroup_usage(path::AbstractString, peaks::CgroupPeaks)
    usage = Dict{String,Any}()
    set!(key, value) = value === nothing || (usage[key] = value)
    peak = try_read(() -> cgroup_bytes(path, "memory.peak"), nothing)
    set!("memory_peak_bytes", something(peak, peaks.memory_current, Some(nothing)))
    haskey(usage, "memory_peak_bytes") &&
        (usage["memory_peak_source"] = peak === nothing ? "sampled" : "memory.peak")
    set!("memory_current_bytes", try_read(() -> cgroup_bytes(path, "memory.current"), nothing))
    set!("peak_anon_bytes", peaks.anon)
    set!("peak_file_bytes", peaks.file)
    set!("peak_shmem_bytes", peaks.shmem)
    set!("peak_kernel_bytes", peaks.kernel)
    events = try_read(() -> cgroup_memory_events(path), Dict{String,Int}())
    isempty(events) || (usage["memory_events"] = events)
    pids = try_read(() -> cgroup_bytes(path, "pids.peak"), nothing)
    set!("pids_peak", something(pids, peaks.pids, Some(nothing)))
    haskey(usage, "pids_peak") && (usage["pids_peak_source"] = pids === nothing ? "sampled" : "pids.peak")
    cpu = try_read(() -> cgroup_counters(path, "cpu.stat"), Dict{String,Int}())
    haskey(cpu, "usage_usec") && (usage["cpu_seconds"] = round(cpu["usage_usec"] / 1e6; digits=1))
    haskey(cpu, "throttled_usec") && (usage["cpu_throttled_seconds"] = round(cpu["throttled_usec"] / 1e6; digits=1))
    set!("cpu_nr_throttled", get(cpu, "nr_throttled", nothing))
    io = try_read(() -> cgroup_io_totals(path), Dict{String,Int}())
    for (key, value) in io
        usage["io_" * key] = value
    end
    for resource in ("cpu", "memory", "io")
        totals = try_read(() -> cgroup_pressure_totals(path, "$(resource).pressure"), Dict{String,Float64}())
        for (kind, seconds) in totals
            usage["$(resource)_pressure_$(kind)_seconds"] = seconds
        end
    end
    return usage
end

# The job cgroup as a `ResourceSource` (see resources.jl). CPU from `cpu.stat`,
# waiting from `cpu.pressure` ("some": time with runnable work stalled, by the
# host or by the job's own CPU affinity). Memory from `memory.stat`: what reclaim
# cannot free is anon and shmem (jobs run without swap where the kernel enforces
# it) plus unreclaimable kernel memory. Page cache is reclaimed under
# `memory.max`, and `memory.peak` (Linux 5.19+) includes it, so for an I/O-heavy
# job it can approach the limit; it is still reported, as it catches spikes
# between samples.
#
# The record is published in a per-slot directory of the scheduler's log
# directory, mounted read-only at `LIVE_MOUNT` in the job's sandbox. The job
# never gets write access to it: the scheduler writes there as itself, on the
# host.
const LIVE_MOUNT = "/sandboxed-buildkite-agent"
const LIVE_RECORD_NAME = "resources"

live_resources_path(logdir::AbstractString, agent_name::AbstractString) =
    joinpath(logdir, "live", agent_name)

# The main unreclaimable kernel components in `memory.stat` (others, such as
# `vmalloc`, are not counted), not the aggregate `kernel`, which also counts
# reclaimable slab. Counters a kernel lacks count as zero.
const UNRECLAIMABLE_KERNEL_STATS = ("kernel_stack", "pagetables", "sec_pagetables",
                                    "percpu", "slab_unreclaimable")

mutable struct CgroupResourceSource <: ResourceSource
    cgroup::String
    # Directory for the live record, or `nothing`.
    live_dir::Union{Nothing,String}
    # Peaks in bytes, for the record's details: anon + shmem and the kernel
    # components above; the cgroup's own peaks (`cgroup_usage`) have the rest.
    peak_anon_shmem::Int
    peak_kernel::Int
    peaks::CgroupPeaks
end

CgroupResourceSource(cgroup::AbstractString; live_dir=nothing) =
    CgroupResourceSource(String(cgroup), live_dir, 0, 0, CgroupPeaks())

# A single-value cgroup file in bytes; `nothing` if missing or "max".
function cgroup_bytes(path::AbstractString, file::AbstractString)
    filepath = joinpath(path, file)
    isfile(filepath) || return nothing
    return tryparse(Int, strip(read(filepath, String)))
end

# The "total=" of a PSI file's "some" line, in microseconds.
function cgroup_pressure_total(path::AbstractString, file::AbstractString)
    filepath = joinpath(path, file)
    isfile(filepath) || return nothing
    for line in eachline(filepath)
        startswith(line, "some ") || continue
        m = match(r"total=(\d+)", line)
        return m === nothing ? nothing : parse(Int, m[1])
    end
    return nothing
end

# The cgroup can disappear under a read at teardown.
function try_read(f, default)
    try
        return f()
    catch
        return default
    end
end

resource_platform(::CgroupResourceSource) = "linux"

function sample_resources(source::CgroupResourceSource)
    cgroup = source.cgroup
    stat = try_read(() -> cgroup_counters(cgroup, "memory.stat"), Dict{String,Int}())
    isempty(stat) && return nothing
    anon_shmem = get(stat, "anon", 0) + get(stat, "shmem", 0)
    kernel = sum(get(stat, key, 0) for key in UNRECLAIMABLE_KERNEL_STATS)
    source.peak_anon_shmem = max(source.peak_anon_shmem, anon_shmem)
    source.peak_kernel = max(source.peak_kernel, kernel)
    sample_cgroup_peaks!(source.peaks, cgroup; stat)
    cpu = get(try_read(() -> cgroup_counters(cgroup, "cpu.stat"), Dict{String,Int}()),
              "usage_usec", nothing)
    pressure = try_read(() -> cgroup_pressure_total(cgroup, "cpu.pressure"), nothing)
    return ResourceSample(;
        cpu_seconds = cpu === nothing ? nothing : cpu / 1e6,
        wait_seconds = pressure === nothing ? nothing : pressure / 1e6,
        needed_bytes = anon_shmem + kernel,
        total_bytes = try_read(() -> cgroup_bytes(cgroup, "memory.current"), nothing),
        swap_bytes = try_read(() -> cgroup_bytes(cgroup, "memory.swap.current"), nothing))
end

resource_oom_kills(source::CgroupResourceSource) =
    try_read(() -> get(cgroup_memory_events(source.cgroup), "oom_kill", nothing), nothing)

function resource_details(source::CgroupResourceSource)
    cgroup = source.cgroup
    return merge!(cgroup_usage(cgroup, source.peaks), Dict{String,Any}(
        "peak_anon_shmem_bytes" => source.peak_anon_shmem,
        "peak_kernel_bytes" => source.peak_kernel,
        # "0" where the scheduler forbids swap, "max" or missing (no swap
        # accounting, as on 5.4) where the job may swap.
        "swap_max" => try_read(() -> strip(read(joinpath(cgroup, "memory.swap.max"), String)), nothing),
    ))
end

function publish_resources(source::CgroupResourceSource, content::AbstractString)
    source.live_dir === nothing && return nothing
    publish_file_atomically(joinpath(source.live_dir, LIVE_RECORD_NAME), content)
end

"""
    kill_cgroup(path; timeout, use_cgroup_kill=true)

SIGKILL every process in the cgroup `path` and below, and wait until none is
left. Returns whether the cgroup was confirmed empty within `timeout` seconds.
Kernels before 5.14 (5.4 on the POWER9 hosts) have no `cgroup.kill`; there the
processes listed in `cgroup.procs` are killed one by one, repeatedly, since a
process can fork between the listing and the kill.
"""
function kill_cgroup(path::String; timeout::Real=LINUX_CGROUP_KILL_TIMEOUT,
                     use_cgroup_kill::Bool=true)
    isdir(path) || return true
    kill_path = joinpath(path, "cgroup.kill")
    if use_cgroup_kill && isfile(kill_path)
        try
            write(kill_path, "1\n")
        catch err
            @warn("Unable to write cgroup.kill; killing the cgroup's processes one by one",
                path, exception=(err, catch_backtrace()))
        end
    end
    deadline = time() + Float64(timeout)
    while true
        pids = cgroup_pids(path)
        isempty(pids) && return true
        foreach(pid -> ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGKILL), pids)
        time() >= deadline && return false
        sleep(0.05)
    end
end

function remove_cgroup_tree(path::String)
    isdir(path) || return nothing
    for child in readdir(path; join=true)
        isdir(child) && remove_cgroup_tree(child)
    end
    rm(path)
    return nothing
end

"""
    remove_job_cgroup(path; timeout, kill_timeout)

Kill the processes of a job cgroup and remove it. Returns whether the cgroup is
gone; when it is not, processes of the job may still run, and the caller must
not hand its CPUs or slot to another job.
"""
function remove_job_cgroup(path::String; timeout::Real=LINUX_CGROUP_REMOVE_TIMEOUT,
                           kill_timeout::Real=LINUX_CGROUP_KILL_TIMEOUT)
    isdir(path) || return true
    emptied = try
        kill_cgroup(path; timeout=kill_timeout)
    catch err
        @error("Unable to kill job cgroup", path, exception=(err, catch_backtrace()))
        false
    end
    if !emptied
        @error("Processes of a job survived being killed", path, pids=cgroup_pids(path))
        return false
    end

    deadline = time() + Float64(timeout)
    last_error = nothing
    while isdir(path)
        try
            remove_cgroup_tree(path)
            return true
        catch err
            last_error = (err, catch_backtrace())
            time() >= deadline && break
            sleep(0.1)
        end
    end
    isdir(path) || return true
    @error("Unable to remove job cgroup", path, exception=last_error)
    return false
end

# Jobs of a previous scheduler; one that survives would run unaccounted, so
# the scheduler does not start.
function cleanup_job_cgroups(root::String; kill_timeout::Real=LINUX_CGROUP_KILL_TIMEOUT)
    isempty(root) && return nothing
    isdir(root) || return nothing
    survivors = String[]
    for name in sort(readdir(root))
        startswith(name, "job-") || continue
        path = joinpath(root, name)
        isdir(path) || continue
        @warn("Removing stale Linux job cgroup", path)
        remove_job_cgroup(path; kill_timeout) || push!(survivors, path)
    end
    isempty(survivors) ||
        error("Refusing to launch Linux jobs; stale job cgroups survived cleanup: $(join(survivors, ", "))")
    return nothing
end

function cleanup_linux_host_path(path::AbstractString)
    try
        Base.Filesystem.prepare_for_deletion(path)
        rm(path; force=true, recursive=true)
    catch err
        @warn("Unable to clean host path", path, exception=(err, catch_backtrace()))
    end
    return nothing
end

function wrap_command_in_cgroup_join_file(join_file::String, cmd::Cmd)
    wrapper_path = joinpath(@__DIR__, "assets", "host_cgroup_wrapper.sh")
    wrapped_cmd = Cmd(
        Cmd(vcat([wrapper_path, join_file], cmd.exec));
        dir=cmd.dir,
        ignorestatus=cmd.ignorestatus,
    )
    if cmd.env === nothing
        return wrapped_cmd
    end
    return setenv(wrapped_cmd, cmd.env)
end

function Sandbox.SandboxConfig(brg::BuildkiteRunnerGroup;
                       agent_name::String,
                       cache_path::String,
                       shared_cache_path::Union{String,Nothing},
                       temp_path::String,
                       live_path::Union{Nothing,String} = nothing,
                       alloc::Allocation = Allocation(Sys.CPU_THREADS),
                       visible_cpus::Integer = Sys.CPU_THREADS,
                       rootfs_dir::String = @artifact_str("buildkite-agent-rootfs", brg.platform),
                       verbose::Bool = brg.verbose,
                       )
    repo_root = REPO_ROOT

    # Set read-only mountings for rootfs and hooks
    ro_maps = Dict(
        # Mount in rootfs
        "/" => rootfs_dir,

        # Mount in hooks
        "/hooks" => joinpath(repo_root, "agent", "hooks"),

        # Mount in an up-to-date agent binary (served from our artifact!), rather
        # than relying on the ancient apt-installed copy baked into the rootfs.
        # The agent is a statically-linked Go binary, so the bare binary suffices.
        "/usr/bin/buildkite-agent" => artifact_lookup("buildkite-agent/buildkite-agent"),

        # Mount in a machine-id file that will be consistent across runs, but unique to each agent
        "/etc/machine-id" => joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id"),
    )
    live_path === nothing || (ro_maps[LIVE_MOUNT] = live_path)
    # Set read-write mountings for our `/cache` directory
    rw_maps = Dict(
        "/cache" => cache_path,
        # A subdirectory of the outer sandbox's persistence dir, which holds the
        # live upper and work dirs of the job's root overlay; nested sandboxes
        # must not see those, but need an overlay-capable filesystem too.
        "/persist" => joinpath(agent_persist_dir(brg, agent_name), "nested"),
        "/tmp" => temp_path,
    )

    if shared_cache_path !== nothing
        rw_maps["/sharedcache"] = shared_cache_path
    end

    # Environment mappings
    env_maps = Dict(
        # The job's cache pool, which tools and plugins use as
        # `${XDG_CACHE_HOME}/<name>` (see "Cache isolation" in the README).
        "XDG_CACHE_HOME" => "/cache",
        # julia-buildkite-plugin v1 only reads its own variable (v2 prefers it
        # too); it names the same directory as `${XDG_CACHE_HOME}/julia-buildkite-plugin`.
        # Remove once no pipeline uses v1.
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => "/cache/julia-buildkite-plugin",
        "BUILDKITE_PLUGIN_JULIA_ARCH" => brg.tags["arch"],
        "HOME" => "/root",
		"SHELL" => "/bin/bash",

        # For anyone who wants to do nested sandboxing, tell them to store
        # persistent data here instead of in `/tmp`, since that's an overlayfs
        "SANDBOX_PERSISTENCE_DIR" => "/persist",
        "FORCE_SANDBOX_MODE" => "unprivileged",

        # Give the job a sane, `/usr/local/bin`-first PATH. Without this the
        # agent starts with no PATH and hands jobs a minimal `:/usr/bin`; the
        # JuliaCI sandbox plugin then *appends* `/usr/local/bin` which conflicts
        # with our rootfs images putting a toolchain in `/usr/local`.
        "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    )

    # Jobs of unpinned groups (no `cpus_limit`) get no cpuset and run on every
    # CPU of the scheduler's cgroup, `visible_cpus` of them; that is the width
    # they are told, and what `nproc` reports inside the sandbox.
    for (name, value) in allocation_env(alloc;
            cpus_limit=alloc.cpus_limit > 0 ? alloc.cpus_limit : visible_cpus)
        env_maps[name] = value
    end

    return SandboxConfig(
        ro_maps,
        rw_maps,
        env_maps;
        stdin,
        stdout,
        stderr,
        # Jobs stay `root` inside the sandbox so that they can mount filesystems
        # and nest sandboxes of their own (the sandbox plugin, BinaryBuilder).
        # uid=Sandbox.getuid(),
        # gid=Sandbox.getgid(),
        verbose=verbose,
        multiarch=[brg.platform],
    )
end

function host_paths_to_create(::LinuxSandboxBackend, brg, config)
    paths = String[
        joinpath(config.mounts["/cache"].host_path, "build"),
        # A bind-mount source has to exist; it goes away with the rest of the
        # persistence dir in `host_paths_to_cleanup`.
        config.mounts["/persist"].host_path,
        config.mounts["/tmp"].host_path,
    ]

    if haskey(config.mounts, "/sharedcache")
        push!(paths, config.mounts["/sharedcache"].host_path)
    end

    return paths
end

function host_paths_to_cleanup(::LinuxSandboxBackend, brg, config, agent_name)
    return String[
        # We clean out our `/cache/build` directory every time
        joinpath(config.mounts["/cache"].host_path, "build"),

        # We clean out our persistent state dir, because we don't actually want persistence,
        # but we can't handle having some things live on a `tmp` mount and others not.
        agent_persist_dir(brg, agent_name),

        # We clean out our `/tmp` directory every time
        config.mounts["/tmp"].host_path,
    ]
end

const linux_persist_root_lock = ReentrantLock()
const linux_persist_root_cache = Dict{Tuple{String,Tuple{Vararg{String}}},Tuple{String,Bool}}()

function linux_persistence_hints(brg)
    persistence_hints = String[]
    if persistence_dir(brg) !== nothing
        push!(persistence_hints, persistence_dir(brg))
    end
    push!(persistence_hints, cachedir(brg))
    return persistence_hints
end

function linux_persist_root_info(rootfs_dir::String, persistence_hints::Vector{String};
                                 finder=Sandbox.find_persist_dir_root)
    key = (rootfs_dir, Tuple(persistence_hints))
    return lock(linux_persist_root_lock) do
        get!(linux_persist_root_cache, key) do
            persist_root, userxattr = finder(rootfs_dir, persistence_hints)
            if persist_root === nothing
                error("""
                    No usable persistence directory: none of the candidate paths are on a
                    filesystem that can host an overlayfs upperdir.
                    Tried (in order): $(join(persistence_hints, ", ")).""")
            end
            return (persist_root, userxattr)
        end
    end
end

function linux_persist_root_info(brg)
    persistence_hints = linux_persistence_hints(brg)
    rootfs_dir = @artifact_str("buildkite-agent-rootfs", brg.platform)
    return linux_persist_root_info(rootfs_dir, persistence_hints)
end

function agent_persist_info(brg, agent_name)
    # Once we've found a good persistence root, go into an agent-specific location.
    persist_root, userxattr = linux_persist_root_info(brg)
    return joinpath(persist_root, string("persist-", agent_name)), userxattr
end

function agent_persist_dir(brg, agent_name)
    return first(agent_persist_info(brg, agent_name))
end

# Per-slot `/tmp` and `/persist`, the latter only where its root is one of the
# group's own (a fallback root found among the host's mounts is not).
function slot_scratch_roots(::LinuxSandboxBackend, brg::BuildkiteRunnerGroup)
    roots = [(joinpath(tempdir(brg), "agent-tempdirs"), "")]
    persist_root = first(linux_persist_root_info(brg))
    registered = normpath.(filter(!isnothing, [persistence_dir(brg), cachedir(brg)]))
    normpath(persist_root) in registered && push!(roots, (persist_root, "persist-"))
    return roots
end

function cleanup(backend::LinuxSandboxBackend)
    cleanup_job_cgroups(backend.root)
    if !backend.io_accounting && !isempty(backend.root)
        backend.io_accounting_stuck = !disable_io_accounting!(backend.root)
        backend.io_accounting_stuck && @error(
            "io_accounting is off, but the io controller stays enabled for job cgroups; their I/O is still accounted",
            root=backend.root, subtree_control=try_read(() -> strip(read(
                joinpath(backend.root, "cgroup.subtree_control"), String)), nothing))
    end
    cleanup_linux_host_path.(backend.cleanup_paths)
    return nothing
end

io_accounting_stuck(backend::LinuxSandboxBackend) = backend.io_accounting_stuck

function setup_backend!(backend::LinuxSandboxBackend, slots)
    backend.root = scheduler_cgroup_root()
    backend.cpus = setup_job_cgroups!(backend.root; backend.io_accounting)
    backend.cleanup_paths = linux_startup_cleanup_paths(slots)
    return nothing
end

mutable struct LinuxSandboxHandle
    backend::LinuxSandboxBackend
    slot::Slot
    job::Job
    plan::CachePlan
    alloc::Allocation
    config::SandboxConfig
    agent_name::String
    log_path::String
    cgroup_path::String
    # The job cgroup's `cpuset.cpus`; empty for jobs without a CPU limit.
    cpuset::Vector{Int}
    launch::LaunchGate
    resources::ResourceSampler{CgroupResourceSource}
end

function job_cgroup_name(slot::Slot, job::Job)
    slot_name = safe_path_component(slot.name, "unknown-slot")
    job_id = safe_path_component(job.id, "unknown-job")
    return string("job-", slot_name, "-", job_id)
end

function linux_agent_temp_path(slot::Slot)
    return joinpath(tempdir(slot.brg), "agent-tempdirs", slot.name)
end

function linux_startup_cleanup_paths(slots)
    paths = String[]
    for slot in slots
        push!(paths, linux_agent_temp_path(slot))
        try
            push!(paths, agent_persist_dir(slot.brg, slot.name))
        catch err
            @warn("Unable to resolve Linux persistence dir for cleanup",
                slot=slot.name, exception=(err, catch_backtrace()))
        end
    end
    return sort(unique(paths))
end

function prepare(backend::LinuxSandboxBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    mkpath(plan.cache_pool)
    plan.ccache_pool === nothing || mkpath(plan.ccache_pool)
    isempty(backend.root) && error("LinuxSandboxBackend has not been set up")

    agent_name = slot.name
    temp_path = linux_agent_temp_path(slot)
    live_path = live_resources_path(backend.logdir, agent_name)
    rm(live_path; recursive=true, force=true)
    mkpath(live_path)
    log_path = job_log_path(backend.logdir, agent_name, job)
    cgroup_path = joinpath(backend.root, job_cgroup_name(slot, job))
    cpuset = alloc.cpus_limit > 0 ? pin_job_cpus!(backend, cgroup_path, alloc.cpus_limit; request=alloc.cpus) : Int[]
    local config
    try
        # The job is told the width it got: fewer CPUs than its limit only when
        # the scheduler's cgroup has fewer CPUs than `total_cpus`.
        if !isempty(cpuset) && length(cpuset) != alloc.cpus_limit
            @warn("Job gets fewer CPUs than its limit", slot=slot.name, job=job.id,
                cpus_limit=alloc.cpus_limit, cpuset=format_cpu_list(cpuset))
            alloc = with_cpus_limit(alloc, length(cpuset))
        end
        config = SandboxConfig(slot.brg;
            agent_name,
            cache_path=plan.cache_pool,
            shared_cache_path=plan.ccache_pool,
            temp_path,
            live_path,
            alloc,
            visible_cpus=length(backend.cpus),
        )
        create_job_cgroup(backend.root, job_cgroup_name(slot, job);
            cpus=alloc.cpus,
            mem_bytes=gib_bytes(alloc.mem_limit_gib),
            cpuset)
    catch
        unpin_job_cpus!(backend, cgroup_path)
        rethrow()
    end
    handle = LinuxSandboxHandle(backend, slot, job, plan, alloc, config, agent_name, log_path, cgroup_path, cpuset,
        LaunchGate(),
        ResourceSampler(CgroupResourceSource(cgroup_path; live_dir=live_path);
            context=job_resource_context(; job, slot=slot.name, group=slot.brg.name,
                queue=job_queue(slot.brg, job), alloc)))

    try
        cleanup_host_paths(handle)
        mkpath.(host_paths_to_create(backend, slot.brg, config))
        write_machine_id(agent_name)
        mkpath(dirname(log_path))
        return handle
    catch
        reap(handle)
        rethrow()
    end
end

function write_machine_id(agent_name::String)
    machine_id_path = joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id")
    mkpath(dirname(machine_id_path))
    write(machine_id_path, bytes2hex(sha1(agent_name))[1:32])
end

function cleanup_host_paths(handle::LinuxSandboxHandle)
    for path in host_paths_to_cleanup(handle.backend, handle.slot.brg, handle.config, handle.agent_name)
        cleanup_linux_host_path(path)
    end
end

# The job's agent (or, for tests, `cmd`) in the sandbox, joining the job cgroup.
function sandbox_command(handle::LinuxSandboxHandle; cmd::Union{Nothing,Cmd}=nothing)
    brg = handle.slot.brg
    # Not `with_executor`: its clean-up removes the persistence dir, with the
    # `/persist` bind source in it, before the command runs. `prepare` and
    # `reap` own that dir.
    exe = UnprivilegedUserNamespacesExecutor()
    exe.persistence_dir, exe.userxattr = agent_persist_info(brg, handle.agent_name)
    cmd = something(cmd, buildkite_agent_start_command(brg;
        agent_binary="/usr/bin/buildkite-agent",
        hooks_path="/hooks",
        cache_path="/cache",
        agent_name=handle.agent_name,
        job=handle.job,
    ))
    sandbox_cmd = Sandbox.build_executor_command(exe, handle.config, cmd)
    return wrap_command_in_cgroup_join_file(
        joinpath(handle.cgroup_path, "cgroup.procs"),
        sandbox_cmd,
    )
end

function run_job(handle::LinuxSandboxHandle, deadline::Union{Nothing,Float64}, job_token::Function)
    sampler = start_resource_sampler(handle.resources)
    try
        open(handle.log_path, "a") do log
            println(log, job_start_banner(handle.job, handle.plan))
            # The sandbox passes its environment on to the agent.
            cmd = addenv(sandbox_command(handle), "BUILDKITE_AGENT_TOKEN" => job_token())
            commit_launch!(handle.launch)
            proc = run_with_secret(pipeline(cmd; stdout=log, stderr=log),
                "the Linux sandbox of job $(handle.job.id)")
            return wait_process_exit(proc, deadline,
                "running Linux sandbox job $(handle.job.id)")
        end
    finally
        close(sampler)
    end
end

# PIDs of the `buildkite-agent start` processes in a job cgroup (and below it,
# should the sandbox create children), as seen from the host.
function cgroup_agent_pids(cgroup_path::AbstractString; proc_root::AbstractString="/proc")
    return filter(cgroup_pids(cgroup_path)) do pid
        argv = try
            split(read(joinpath(proc_root, string(pid), "cmdline"), String), '\0')
        catch
            return false
        end
        return length(argv) >= 2 && basename(argv[1]) == "buildkite-agent" && argv[2] == "start"
    end
end

function cgroup_pids(cgroup_path::AbstractString)
    pids = Int[]
    isdir(cgroup_path) || return pids
    for (dir, _, files) in walkdir(cgroup_path)
        "cgroup.procs" in files || continue
        for line in eachline(joinpath(dir, "cgroup.procs"))
            pid = tryparse(Int, strip(line))
            pid === nothing || push!(pids, pid)
        end
    end
    return pids
end

function parent_pid(pid::Integer; proc_root::AbstractString="/proc")
    stat = try
        read(joinpath(proc_root, string(pid), "stat"), String)
    catch
        return nothing
    end
    # the fields after the parenthesised command name: state, ppid, ...
    fields = split(stat[something(findlast(')', stat), 0)+1:end])
    return length(fields) >= 2 ? tryparse(Int, fields[2]) : nothing
end

"""
    cgroup_job_pids(cgroup_path)

The processes of the job in `cgroup_path`: everything in the cgroup except its
Buildkite agents and the processes above them (the sandbox that runs the agent).
"""
function cgroup_job_pids(cgroup_path::AbstractString; proc_root::AbstractString="/proc")
    pids = cgroup_pids(cgroup_path)
    keep = Set{Int}()
    for pid in cgroup_agent_pids(cgroup_path; proc_root)
        while pid !== nothing && pid in pids && !(pid in keep)
            push!(keep, pid)
            pid = parent_pid(pid; proc_root)
        end
    end
    return filter(!in(keep), pids)
end

function stop_job(handle::LinuxSandboxHandle; force::Bool=false, kill_delay::Real=STOP_KILL_DELAY,
                  agent_pids::Function=cgroup_agent_pids, job_pids::Function=cgroup_job_pids,
                  kill_timeout::Real=LINUX_CGROUP_KILL_TIMEOUT)
    committed = close_launch_gate!(handle.launch)
    if force
        isempty(cgroup_pids(handle.cgroup_path)) && return :ended
        # Not confirmed empty is not the same as nothing killed.
        return kill_cgroup(handle.cgroup_path; timeout=kill_timeout) ? :stopped : :unconfirmed
    end
    committed || return :not_acquired
    agents = agent_pids(handle.cgroup_path)
    isempty(agents) && return :no_agent
    try
        for pid in agents
            ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGQUIT)
        end
        # The agent would now wait up to its cancel grace period for the job to exit (on a
        # cancel signal, Julia's test runner dumps the core of every worker first). A stopped
        # job is retried by the operator, so kill it instead: the agent then reports it and exits.
        sleep(kill_delay)
        for _ in 1:5
            pids = job_pids(handle.cgroup_path)
            isempty(pids) && break
            foreach(pid -> ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGKILL), pids)
            sleep(0.2)
        end
    catch err
        # The agent was signalled, so the job may be stopped all the same.
        @warn("Unable to finish stopping the Buildkite job", cgroup=handle.cgroup_path,
            exception=(err, catch_backtrace()))
        return :unconfirmed
    end
    return :stopped
end

# Returns `false` while processes of the job may survive; the job keeps its
# CPUs and paths until a later call confirms they are gone.
function reap(handle::LinuxSandboxHandle)
    # First, so that it happens on every attempt, including those that cannot
    # confirm the cgroup gone; and before removing the live record, so no late
    # sample recreates it.
    stop_resources!(handle.resources)
    live_dir = handle.resources.source.live_dir
    live_dir === nothing || rm(live_dir; recursive=true, force=true)
    log_job_oom_events(handle.cgroup_path; log_path=handle.log_path)
    remove_job_cgroup(handle.cgroup_path) || return false
    unpin_job_cpus!(handle.backend, handle.cgroup_path)
    cleanup_host_paths(handle)
    return true
end
