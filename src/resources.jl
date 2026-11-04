#
# Job resource usage
#

# What a job used, to size its requests. While a job runs, the scheduler samples
# it from the host and, after every sample, publishes the record so far where the
# agent's `pre-exit` hook (`agent/hooks/pre-exit`) can read it; the hook copies it
# into the job log and the build meta-data `sba/<job id>`. That is the only place
# the record is reported, so it misses what happens after the last sample the
# hook sees; the hook waits up to 10 s for one taken after the job's command
# ended (by the record's `sampled_at_ms`).
#
# The sampling, aggregation, record and summary are the same on every platform
# (`ResourceSampler`). A backend provides a `ResourceSource`: where the readings
# come from and how the record reaches the job. A source implements
#
#   resource_platform(source)::String
#       The record's `platform`: "linux", "windows-kvm", "freebsd-kvm", "macos".
#   sample_resources(source)::Union{Nothing,ResourceSample}
#       One reading, or `nothing` if there is none (the job is not there yet or
#       any more). May update the source's own state, e.g. platform peaks.
#   publish_resources(source, content::String)
#       Make `content` (the summary line, a newline, the JSON record, a newline)
#       readable by the hook, replacing the previous content. May throw; the
#       sampler ignores the error and publishes again after the next sample.
#
# and optionally
#
#   resource_details(source)::Dict{String,Any}
#       The record's `details`: the platform's own figures, e.g. raw peaks.
#   resource_host_cpus(source)::Union{Nothing,Int}
#       The host's CPU count if the CPU readings are host-wide rather than the
#       job's (macOS); the busy histogram then covers the whole host.
#   resource_needed_lower_bound(source)::Bool
#       Whether `needed_bytes` can miss memory the job could not do without
#       (FreeBSD), so that it only bounds the need from below.
#   resource_oom_kills(source)::Union{Nothing,Int}
#       How many of the job's processes the kernel has OOM-killed so far, or
#       `nothing` where the platform does not count them (only Linux does).
#   interrupt_resources(source)
#       Called by `stop_resources!` before it waits for a sample in progress,
#       from another task: make that sample finish now, e.g. by killing the
#       command it waits for. Sources whose samples cannot block need not.
#
# Telemetry must never fail or hold up the job: the sampler catches whatever a
# sample throws, and a source bounds how long its calls can take. The sampler
# holds its lock around every call but `interrupt_resources`, so a source needs
# no locking of its own, and no call happens after `stop_resources!` returns.
abstract type ResourceSource end

resource_details(::ResourceSource) = Dict{String,Any}()
resource_host_cpus(::ResourceSource) = nothing
resource_needed_lower_bound(::ResourceSource) = false
resource_oom_kills(::ResourceSource) = nothing
interrupt_resources(::ResourceSource) = nothing

# Bumped when a core field changes meaning; new fields do not need it.
const RESOURCE_RECORD_SCHEMA = 1

struct ResourceSample
    # Cumulative CPU time of the job (busy vCPU time for a VM), and cumulative
    # time its runnable work waited for a host CPU, in seconds. Any fixed origin
    # will do: the sampler only uses differences from its first reading.
    # `nothing` if unavailable, for this sample or (`wait_seconds`) the platform.
    cpu_seconds::Union{Nothing,Float64}
    wait_seconds::Union{Nothing,Float64}
    # Memory at the time of the sample, in bytes: what the job could not have
    # done without (no page cache or other reclaimable memory), everything
    # charged to it, and swapped out.
    needed_bytes::Union{Nothing,Int}
    total_bytes::Union{Nothing,Int}
    swap_bytes::Union{Nothing,Int}
    # When the memory figures were observed (`time()`), if not just now: some
    # guests report them late.
    memory_at::Union{Nothing,Float64}
end

ResourceSample(; cpu_seconds=nothing, wait_seconds=nothing, needed_bytes=nothing,
               total_bytes=nothing, swap_bytes=nothing, memory_at=nothing) =
    ResourceSample(cpu_seconds, wait_seconds, needed_bytes, total_bytes, swap_bytes, memory_at)

# Sampled every second for the first 10 s, so that short jobs get a record, then
# every 10 s.
const JOB_RESOURCE_SAMPLE_INTERVAL = 10.0
const JOB_RESOURCE_FAST_INTERVAL = 1.0
const JOB_RESOURCE_FAST_SAMPLES = 10

mutable struct ResourceSampler{S<:ResourceSource}
    source::S
    # Host, job, slot, group, queue and requested size, copied into every record.
    context::Dict{String,Any}
    # Held for a whole sample, so stopping cannot interleave with a sampler
    # callback (a Timer may run one more callback after `close`).
    lock::ReentrantLock
    stopped::Bool
    # Samples that threw; the first one is logged.
    failures::Int
    # Wall-clock start for the record, and monotonic `time_ns()` stamps for
    # durations and rates.
    started_at::Union{Nothing,Float64}
    started_ns::UInt64
    last_sample_ns::UInt64
    samples::Int
    # Wall-clock time of the last sample, which the hook compares with the end
    # of the job's command; the number of samples with memory figures and when
    # the last of them was observed.
    sampled_at::Union{Nothing,Float64}
    memory_samples::Int
    memory_at::Union{Nothing,Float64}
    # CPU and wait readings: the first, and the last and when it was taken.
    cpu_first::Union{Nothing,Float64}
    cpu_first_ns::UInt64
    cpu_last::Union{Nothing,Float64}
    cpu_last_ns::UInt64
    wait_first::Union{Nothing,Float64}
    wait_last::Union{Nothing,Float64}
    # Seconds spent at each number of busy CPUs (index 1 = none), from the
    # rate between consecutive readings rounded to the nearest integer. Sized
    # for `cpus_limit` (or `cpus`), or the host for host-wide readings, and
    # grown for more: jobs without a CPU limit can use more than they asked.
    busy::Vector{Float64}
    peak_needed::Union{Nothing,Int}
    peak_total::Union{Nothing,Int}
    peak_swap::Union{Nothing,Int}
end

function ResourceSampler(source::ResourceSource; context=Dict{String,Any}())
    width = something(resource_host_cpus(source),
                      max(get(context, "cpus_limit", 0), get(context, "cpus", 0), 1))
    busy = zeros(Float64, width + 1)
    return ResourceSampler(source, Dict{String,Any}(context), ReentrantLock(), false, 0,
        nothing, UInt64(0), UInt64(0), 0, nothing, 0, nothing,
        nothing, UInt64(0), nothing, UInt64(0), nothing, nothing, busy, nothing, nothing, nothing)
end

job_resource_context(; job::Job, slot::AbstractString, group::AbstractString,
                     queue::AbstractString, alloc::Allocation,
                     host::AbstractString=get_short_hostname()) = Dict{String,Any}(
    "host" => host, "job" => job.id, "pipeline_id" => job.pipeline_id, "slot" => slot,
    "group" => group, "queue" => queue, "cpus" => alloc.cpus, "cpus_limit" => alloc.cpus_limit,
    "mem_gib" => alloc.mem_gib, "mem_limit_gib" => alloc.mem_limit_gib)

maxpeak(peak, value) = value === nothing ? peak : peak === nothing ? value : max(peak, value)

# Take one sample; the caller holds `sampler.lock`.
# `now` is taken before the reading, so a record never claims to be later than
# its readings.
function sample_resources_locked!(sampler::ResourceSampler; now_ns::UInt64=time_ns(),
                                  now::Float64=time())
    s = sample_resources(sampler.source)
    s === nothing && return false
    sampler.samples += 1
    sampler.last_sample_ns = now_ns
    sampler.sampled_at = now
    if s.needed_bytes !== nothing || s.total_bytes !== nothing || s.swap_bytes !== nothing
        sampler.memory_samples += 1
        sampler.memory_at = something(s.memory_at, now)
    end
    sampler.peak_needed = maxpeak(sampler.peak_needed, s.needed_bytes)
    sampler.peak_total = maxpeak(sampler.peak_total, s.total_bytes)
    sampler.peak_swap = maxpeak(sampler.peak_swap, s.swap_bytes)
    if s.wait_seconds !== nothing
        sampler.wait_first === nothing && (sampler.wait_first = s.wait_seconds)
        sampler.wait_last = s.wait_seconds
    end
    cpu = s.cpu_seconds
    cpu === nothing && return true
    if sampler.cpu_last === nothing
        sampler.cpu_first, sampler.cpu_first_ns = cpu, now_ns
    else
        elapsed = (now_ns - sampler.cpu_last_ns) / 1e9
        rate = (cpu - sampler.cpu_last) / elapsed
        if elapsed > 0 && isfinite(rate)
            level = round(Int, max(rate, 0))
            level < length(sampler.busy) || append!(sampler.busy, zeros(level + 1 - length(sampler.busy)))
            sampler.busy[level+1] += elapsed
        end
    end
    sampler.cpu_last, sampler.cpu_last_ns = cpu, now_ns
    return true
end

function publish_resources_locked(sampler::ResourceSampler)
    record = resource_record_locked(sampler)
    content = string(resource_summary(record), "\n", JSON.json(record), "\n")
    try
        publish_resources(sampler.source, content)
    catch err
        err isa InterruptException && rethrow()
        # Expected while the job's side is not there, e.g. older VM images.
        @debug "Could not publish the job's resource record" exception=err
    end
    return nothing
end

# Take a sample and publish the record. Never throws (but for an interrupt):
# a failure only costs this sample, and the timer goes on to the next.
function sample_resources!(sampler::ResourceSampler)
    @lock sampler.lock begin
        sampler.stopped && return sampler
        try
            sample_resources_locked!(sampler) && publish_resources_locked(sampler)
        catch err
            err isa InterruptException && rethrow()
            sampler.failures += 1
            sampler.failures == 1 && @warn("Could not sample the job's resource use",
                job=get(sampler.context, "job", nothing), exception=(err, catch_backtrace()))
        end
    end
    return sampler
end

# Samples the job until the returned timer is closed: right away (the baseline
# for CPU time), every `fast_interval` for the first `fast_samples` ticks, then
# every `interval`. Every sample runs in the timer's task, so this returns
# without waiting for one.
function start_resource_sampler(sampler::ResourceSampler;
                                interval::Real=JOB_RESOURCE_SAMPLE_INTERVAL,
                                fast_interval::Real=JOB_RESOURCE_FAST_INTERVAL,
                                fast_samples::Integer=JOB_RESOURCE_FAST_SAMPLES)
    @lock sampler.lock begin
        sampler.started_at = time()
        sampler.started_ns = sampler.last_sample_ns = time_ns()
    end
    fast_samples > 0 || return Timer(_ -> sample_resources!(sampler), 0; interval)
    every = max(1, round(Int, interval / fast_interval))
    ticks = Ref(-1)
    return Timer(0; interval=fast_interval) do _
        ticks[] += 1
        (ticks[] <= fast_samples || ticks[] % every == 0) && sample_resources!(sampler)
    end
end

# Stop sampling: a sample in progress is interrupted if its source supports
# that, and completes; later ones do nothing.
function stop_resources!(sampler::ResourceSampler)
    try
        interrupt_resources(sampler.source)
    catch err
        @debug "Could not interrupt the resource sampler" exception=err
    end
    @lock sampler.lock sampler.stopped = true
    return nothing
end

# The fewest busy CPUs that cover `fraction` of the sampled time.
function busy_quantile(busy::AbstractVector{<:Real}, fraction::Real)
    total = sum(busy)
    total > 0 || return 0
    covered = 0.0
    for (i, seconds) in enumerate(busy)
        covered += seconds
        covered >= fraction * total && return i - 1
    end
    return length(busy) - 1
end

# The record from the samples so far; the caller holds `sampler.lock`.
function resource_record_locked(sampler::ResourceSampler)
    duration = (sampler.last_sample_ns - sampler.started_ns) / 1e9
    # CPU figures need two readings; without them they are unknown, not zero.
    cpu_duration = (sampler.cpu_last_ns - sampler.cpu_first_ns) / 1e9
    has_cpu = sampler.cpu_last !== nothing && cpu_duration > 0
    cpu_seconds = has_cpu ? sampler.cpu_last - sampler.cpu_first : 0.0
    mean_cpus = has_cpu ? cpu_seconds / cpu_duration : 0.0
    record = Dict{String,Any}(sampler.context)
    merge!(record, Dict{String,Any}(
        "schema" => RESOURCE_RECORD_SCHEMA,
        "platform" => resource_platform(sampler.source),
        "host_cpus" => resource_host_cpus(sampler.source),
        "started_at" => round(Int, something(sampler.started_at, time())),
        "duration_seconds" => round(Int, duration),
        "samples" => sampler.samples,
        # In milliseconds, as the hook must tell a sample from just before the
        # command ended from one just after.
        "sampled_at_ms" => sampler.sampled_at === nothing ? nothing : floor(Int, 1000 * sampler.sampled_at),
        "cpu_seconds" => has_cpu ? round(cpu_seconds; digits=1) : nothing,
        "mean_cpus" => has_cpu ? round(mean_cpus; digits=2) : nothing,
        "busy_histogram" => has_cpu ? round.(Int, sampler.busy) : nothing,
        "wait_seconds" => sampler.wait_last === nothing ? nothing :
                          round(sampler.wait_last - sampler.wait_first; digits=1),
        "peak_needed_bytes" => sampler.peak_needed,
        "peak_total_bytes" => sampler.peak_total,
        "peak_swap_bytes" => sampler.peak_swap,
        "peak_needed_is_lower_bound" => resource_needed_lower_bound(sampler.source),
        "oom_kills" => resource_oom_kills(sampler.source),
        # Memory can be observed less often than CPU, and later.
        "memory_samples" => sampler.memory_samples,
        "memory_age_seconds" => sampler.memory_at === nothing || sampler.sampled_at === nothing ? nothing :
                                round(Int, max(sampler.sampled_at - sampler.memory_at, 0)),
        "details" => resource_details(sampler.source),
    ))
    return record
end

gib(bytes::Integer) = round(bytes / 1024^3; digits=1)
gib_or_na(bytes) = bytes === nothing ? "n/a" : "$(gib(bytes)) GiB"

# Memory observed longer ago than this at the last sample is called out.
const RESOURCE_MEMORY_STALE_SECONDS = 15

# Above this share of the run, time spent waiting for a CPU is called out.
const RESOURCE_WAIT_NOTABLE = 0.05
# Page cache beyond what was needed is called out from this much on.
const RESOURCE_CACHE_NOTABLE_BYTES = 1024^3

# Bytes for people: GiB with one decimal, or whole MiB below 0.1 GiB.
human_bytes(bytes::Integer) = bytes < 102 * 1024^2 ? "$(cld(bytes, 1024^2)) MiB" : "$(gib(bytes)) GiB"

# One short line for people reading the job log, e.g.
#   Resources: CPU 1.5 avg, 2 peak of 4 (2 requested); memory 1.1 GiB peak of 4 GiB; disk 0.2 GiB read, 2.0 GiB written
# with what only matters sometimes (waiting, swapping, OOM kills, an old memory
# reading) appended. The record (meta-data `sba/<job id>`) has everything.
function resource_summary(record::AbstractDict)
    parts = String[]
    get_(key) = get(record, key, nothing)
    mean, histogram = get_("mean_cpus"), get_("busy_histogram")
    if mean !== nothing && histogram !== nothing
        peak = something(findlast(>(0), histogram), 1) - 1
        host, limit = get_("host_cpus"), something(get_("cpus_limit"), 0)
        push!(parts, string("CPU ", round(mean; digits=1), " avg, ", peak, " peak",
            host !== nothing ? " (whole host, $(host) CPUs; " :
            limit > 0 ? " of $(limit) (" : " (", something(get_("cpus"), 0), " requested)"))
    end
    needed = get_("peak_needed_bytes")
    if needed !== nothing
        limit = something(get_("mem_limit_gib"), 0)
        line = string("memory ", something(get_("peak_needed_is_lower_bound"), false) ? "at least " : "",
                      gib(needed), " GiB peak", limit > 0 ? " of $(limit) GiB" : "")
        total = get_("peak_total_bytes")
        total === nothing || total - needed < RESOURCE_CACHE_NOTABLE_BYTES ||
            (line *= " ($(gib(total)) GiB with cache)")
        push!(parts, line)
    end
    details = something(get_("details"), Dict())
    io = haskey(details, "io_read_bytes") ? details : get(details, "domain_cgroup", Dict())
    if haskey(io, "io_read_bytes") && haskey(io, "io_write_bytes")
        push!(parts, string("disk ", human_bytes(io["io_read_bytes"]), " read, ",
                            human_bytes(io["io_write_bytes"]), " written"))
    end
    isempty(parts) && return "Resources: no measurements"
    # Linux's wait is PSI: wall time with some of the job's work stalled. On
    # KVM it is the vCPUs' delays summed, so it is shared out over the vCPUs.
    wait, duration = get_("wait_seconds"), something(get_("duration_seconds"), 0)
    vcpus = get(details, "vcpus", nothing)
    if wait !== nothing && duration > 0
        share = vcpus isa Integer && vcpus > 0 ? wait / (vcpus * duration) : wait / duration
        share > RESOURCE_WAIT_NOTABLE && push!(parts, string(
            vcpus isa Integer && vcpus > 0 ? "vCPUs waited for a host CPU " : "waited for a CPU ",
            round(Int, 100 * share), "% of the time"))
    end
    swap = get_("peak_swap_bytes")
    swap === nothing || swap <= 0 || push!(parts, "swapped $(human_bytes(swap))")
    oom = get_("oom_kills")
    oom === nothing || oom <= 0 || push!(parts, string("OOM-killed ", oom, oom == 1 ? " process" : " processes"))
    age = get_("memory_age_seconds")
    age === nothing || age < RESOURCE_MEMORY_STALE_SECONDS || push!(parts, "memory reading $(age) s old")
    return string("Resources: ", join(parts, "; "))
end

# The external commands of a source's samples (virsh), one at a time: each
# must finish by a deadline, and `interrupt!` (from `interrupt_resources`, so
# from another task) kills the one running and refuses any more. A command
# that was never started throws `SampleCommandNotRun`; one that was killed,
# `SampleCommandKilled`, and one that failed, `SampleCommandFailed` with its
# error output: what either of those did is for the caller to judge.
mutable struct SampleCommands
    lock::ReentrantLock
    process::Union{Nothing,Base.Process}
    interrupted::Bool
end

SampleCommands() = SampleCommands(ReentrantLock(), nothing, false)

struct SampleCommandKilled <: Exception
    cmd::Cmd
end

Base.showerror(io::IO, e::SampleCommandKilled) =
    print(io, "Killed ", e.cmd, " (out of time or interrupted)")

struct SampleCommandNotRun <: Exception
    msg::String
end

Base.showerror(io::IO, e::SampleCommandNotRun) = print(io, e.msg)

struct SampleCommandFailed <: Exception
    cmd::Cmd
    stderr::String
end

Base.showerror(io::IO, e::SampleCommandFailed) = print(io, e.cmd, " failed: ", e.stderr)

function read_sample_command(commands::SampleCommands, cmd::Cmd, deadline::Real)
    remaining = deadline - time()
    remaining > 0 || throw(SampleCommandNotRun("Out of time for this resource sample"))
    err = Pipe()
    proc = @lock commands.lock begin
        commands.interrupted && throw(SampleCommandNotRun("Resource sampling was stopped"))
        commands.process = open(pipeline(cmd; stderr=err))
    end
    close(err.in)
    errors = @async String(read(err, 64 * 1024))
    killed = Ref(false)
    timer = Timer(remaining) do _
        killed[] = true
        kill(proc, Base.SIGKILL)
    end
    try
        output = read(proc, String)
        wait(proc)
        (killed[] || commands.interrupted) && throw(SampleCommandKilled(cmd))
        success(proc) || throw(SampleCommandFailed(cmd, fetch(errors)))
        return output
    finally
        close(timer)
        @lock commands.lock commands.process = nothing
    end
end

function interrupt!(commands::SampleCommands)
    @lock commands.lock begin
        commands.interrupted = true
        commands.process === nothing || kill(commands.process, Base.SIGKILL)
    end
    return nothing
end

# Replace `path` atomically, for hosts where the hook reads the live record
# through the file system. rename(2) replaces the target in one step;
# `mv(; force=true)` removes it first, and the hook could miss it in between.
function publish_file_atomically(path::AbstractString, content::AbstractString)
    tmp = path * ".tmp"
    write(tmp, content)
    Base.Filesystem.rename(tmp, path)
    return nothing
end
