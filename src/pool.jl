# How a job was admitted, for the job's log and resource record (see
# `admission_record`). Admission adds it to the job's `Allocation`.
struct AdmissionInfo
    # Where the size came from: `:tags` (the step's `sched_*` tags), `:default`
    # (the group's default for the job's queue) or `:host` (macOS, the whole host).
    size_source::Symbol
    # That size, before `job_allocation` capped it.
    requested::JobSize
    # The host's budgets (`total_cpus`, `total_mem_gib`), and what of them was
    # free just before the job was charged.
    total_cpus::Int
    total_mem_gib::Int
    free_cpus::Int
    free_mem_gib::Int
    # When the scheduler admitted the job, and when Buildkite says it became
    # runnable (`nothing` if unknown), in seconds since the epoch.
    admitted_at::Float64
    runnable_at::Union{Nothing,Float64}
end

struct Allocation
    # CPU request: charged against `total_cpus`, and the job's `cpu.weight`.
    cpus::Int
    # How many CPUs the job may run on (its Linux cpuset, `SBA_CPUS_LIMIT`,
    # KVM vCPUs); 0 leaves a Linux job unpinned.
    cpus_limit::Int
    # Memory request: what the job typically uses.
    mem_gib::Int
    # Linux `memory.max` or KVM guest RAM; 0 leaves Linux memory unlimited.
    mem_limit_gib::Int
    # Charged against `total_mem_gib`: the memory request of a native (Linux,
    # macOS) job, the guest RAM plus host overhead of a KVM job.
    charged_mem_gib::Int
    # Set once the job is admitted; `nothing` for a mere candidate.
    admission::Union{Nothing,AdmissionInfo}
end

Allocation(cpus::Integer, cpus_limit::Integer, mem_gib::Integer, mem_limit_gib::Integer,
           charged_mem_gib::Integer) =
    Allocation(cpus, cpus_limit, mem_gib, mem_limit_gib, charged_mem_gib, nothing)
Allocation(cpus::Integer) = Allocation(cpus, cpus, 0, 0, 0)
Allocation(cpus::Integer, cpus_limit::Integer, mem_gib::Integer) =
    Allocation(cpus, cpus_limit, mem_gib, mem_gib, mem_gib)

# The same grant with another CPU limit (fewer CPUs to pin than asked for), or
# with how it was admitted.
with_cpus_limit(alloc::Allocation, cpus_limit::Integer) =
    Allocation(alloc.cpus, cpus_limit, alloc.mem_gib, alloc.mem_limit_gib,
               alloc.charged_mem_gib, alloc.admission)
with_admission(alloc::Allocation, admission::AdmissionInfo) =
    Allocation(alloc.cpus, alloc.cpus_limit, alloc.mem_gib, alloc.mem_limit_gib,
               alloc.charged_mem_gib, admission)

"""
    allocation_env(alloc; cpus_limit=alloc.cpus_limit)

The job's grant as environment variables, which every backend exports and
the agent's environment hook maps to `JULIA_CPU_THREADS`. `cpus_limit` is
how many CPUs the job can run on; pass it for jobs that are not pinned to
`alloc.cpus_limit` CPUs. Memory is exported only when the job was granted
some. An admitted job also gets `SBA_ADMISSION`, one line saying how it was
admitted (`admission_summary`), which an environment hook prints.
"""
function allocation_env(alloc::Allocation; cpus_limit::Integer=alloc.cpus_limit)
    env = ["SBA_CPUS" => string(alloc.cpus), "SBA_CPUS_LIMIT" => string(cpus_limit)]
    alloc.mem_gib > 0 && push!(env, "SBA_MEM_GIB" => string(alloc.mem_gib))
    alloc.mem_limit_gib > 0 && push!(env, "SBA_MEM_LIMIT_GIB" => string(alloc.mem_limit_gib))
    alloc.admission === nothing ||
        push!(env, "SBA_ADMISSION" => admission_summary(allocation_record(alloc)))
    return env
end

# CPUs and memory are budgets, not specific cores or pages: Linux enforces a
# job's CPU share with `cpu.weight`, KVM with the domain's CPU shares, and the
# job sizes its own parallelism from `cpus_limit`.
mutable struct ResourcePool
    total::Int
    allocated::Int
end

function ResourcePool(total::Integer)
    Int(total) >= 1 || throw(ArgumentError("resource pool size must be at least 1"))
    return ResourcePool(Int(total), 0)
end

available(pool::ResourcePool) = pool.total - pool.allocated

function allocate!(pool::ResourcePool, amount::Integer)
    n = Int(amount)
    n >= 0 || throw(ArgumentError("allocation size must be non-negative"))
    available(pool) >= n || return nothing
    pool.allocated += n
    return n
end

function release!(pool::ResourcePool, amount::Integer)
    amount <= pool.allocated ||
        error("releasing $(amount), but only $(pool.allocated) is allocated")
    pool.allocated -= amount
    return nothing
end

#
# Job requests
#

# Agent tags a pipeline step sets to size its job, in `agents:` next to `queue`.
# Each resource has a request (`sched_cpus`, `sched_mem_gib`) and an optional
# limit that defaults to it and may not be below it; only bursty jobs (builds)
# ask for a CPU limit above their request.
const SCHED_TAGS = ("sched_cpus", "sched_cpus_limit", "sched_mem_gib", "sched_mem_limit_gib")
const REQUIRED_SCHED_TAGS = ("sched_cpus", "sched_mem_gib")
const SCHED_LIMIT_TAGS = ("sched_cpus_limit" => "sched_cpus", "sched_mem_limit_gib" => "sched_mem_gib")

# The scheduler owns every `sched_*` key: such rules never take part in agent
# matching, so a step with a misspelled or outdated one is failed with a
# message instead of waiting forever for an agent that advertises it.
is_sched_key(key::AbstractString) = startswith(key, "sched_")

# A rule's key, operator (`=`, `!=`, or empty for a bare key) and value.
function partition_rule(rule::AbstractString)
    rule = strip(rule)
    idx = findfirst('=', rule)
    idx === nothing && return (rule, "", "")
    value = strip(rule[nextind(rule, idx):end])
    if idx > firstindex(rule) && rule[prevind(rule, idx)] == '!'
        return (strip(rule[begin:prevind(rule, idx, 2)]), "!=", value)
    end
    return (strip(rule[begin:prevind(rule, idx)]), "=", value)
end

sched_rules(job::Job) =
    [rule for rule in job.agent_query_rules if is_sched_key(first(partition_rule(rule)))]

# The `sched_*` values a job asks for, keeping only positive integers.
function sched_tags(job::Job)
    tags = Dict{String,Int}()
    for rule in sched_rules(job)
        key, sep, value = partition_rule(rule)
        sep == "=" && key in SCHED_TAGS && !haskey(tags, key) || continue
        parsed = tryparse(Int, value)
        parsed === nothing || parsed < 1 || (tags[key] = parsed)
    end
    return tags
end

"""
    sched_tag_errors(job; complete=true)

What is wrong with the `sched_*` rules of `job`'s step, one message per problem:
unknown keys, operators other than `=`, keys set twice, values that
are not positive integers, and limits below their request. With `complete`,
also required tags that are missing. Empty for a step without `sched_*` tags.
"""
function sched_tag_errors(job::Job; complete::Bool=true)
    rules = sched_rules(job)
    isempty(rules) && return String[]
    errors = String[]
    seen = Set{String}()
    for rule in rules
        key, op, value = partition_rule(rule)
        if key ∉ SCHED_TAGS
            push!(errors, "`$(key)` is not a size tag; expected one of $(join(SCHED_TAGS, ", "))")
        elseif op != "="
            push!(errors, "`$(strip(rule))` must set `$(key)` with `=`")
        elseif key in seen
            push!(errors, "`$(key)` is set more than once")
        elseif something(tryparse(Int, value), 0) < 1
            push!(errors, "`$(key)=$(value)` is not a positive integer")
        elseif startswith(key, "sched_mem") && parse(Int, value) > MAX_MEM_GIB
            push!(errors, "`$(key)=$(value)` is more memory than can be represented " *
                "(at most $(MAX_MEM_GIB) GiB)")
        end
        push!(seen, key)
    end
    tags = sched_tags(job)
    if complete
        for key in REQUIRED_SCHED_TAGS
            key in seen || push!(errors, "`$(key)` is missing")
        end
    end
    for (limit, request) in SCHED_LIMIT_TAGS
        haskey(tags, limit) && haskey(tags, request) && tags[limit] < tags[request] &&
            push!(errors, "`$(limit)=$(tags[limit])` is below `$(request)=$(tags[request])`")
    end
    return errors
end

"""
    requested_size(brg, job)

The size `job` asks for before any cap, and where it comes from:
`(; source=:tags, size)` from the step's `sched_*` tags, `:default` from the
group's default for the job's queue, or `:host` for macOS jobs, which get the
whole host. `nothing` if the job cannot be sized (see `job_allocation`).
"""
function requested_size(brg::BuildkiteRunnerGroup, job::Job)
    macos = brg.backend == BACKEND_MACOS_SEATBELT
    isempty(sched_tag_errors(job; complete=!macos)) || return nothing
    macos && return (; source=:host, size=brg.default)
    if isempty(sched_rules(job))
        size = default_size(brg, job_queue(brg, job))
        return size === nothing ? nothing : (; source=:default, size)
    end
    tags = sched_tags(job)
    cpus, mem_gib = tags["sched_cpus"], tags["sched_mem_gib"]
    return (; source=:tags, size=JobSize(cpus, get(tags, "sched_cpus_limit", cpus),
                                          mem_gib, get(tags, "sched_mem_limit_gib", mem_gib)))
end

"""
    job_allocation(brg, job, config)

What `job` gets on this host. A step with any `sched_*` tag gets its
`sched_cpus` and `sched_mem_gib` requests and the optional `sched_cpus_limit`
and `sched_mem_limit_gib` (default: the request), and `nothing` if any of its
`sched_*` rules is wrong (see `sched_tag_errors`): a broken request never falls
back to a default. A step without tags gets the group's `default` for the job's
queue, or `nothing` if there is none. macOS jobs always get the whole host, but
their `sched_*` rules must still be valid, if not complete.

CPUs and their limit are capped at `total_cpus`, and KVM vCPUs and guest RAM at
the group's `max_cpus` and `max_mem_gib`; each request is then capped at its
limit. Memory is never capped at `total_mem_gib`: a job charged more than the
host has is left to other hosts (see `admission_plan`).
"""
function job_allocation(brg::BuildkiteRunnerGroup, job::Job, config::SchedulerConfig)
    requested = requested_size(brg, job)
    requested === nothing && return nothing
    size = requested.size
    cpus, cpus_limit = size.cpus, size.cpus_limit
    mem_gib, mem_limit_gib = size.mem_gib, size.mem_limit_gib
    cpus = min(cpus, config.total_cpus)
    cpus_limit = min(cpus_limit, config.total_cpus)
    kvm = brg.backend == BACKEND_KVM
    if kvm
        brg.max_cpus > 0 && (cpus_limit = min(cpus_limit, brg.max_cpus))
        if brg.max_mem_gib > 0
            mem_gib = min(mem_gib, brg.max_mem_gib)
            mem_limit_gib = min(mem_limit_gib, brg.max_mem_gib)
        end
    end
    # Clipping a limit clips its request with it: a job is not charged for
    # more CPUs than it can run on (a 6-vCPU guest asked for 8), nor expects
    # more memory than it may use.
    cpus_limit > 0 && (cpus = min(cpus, cpus_limit))
    mem_gib = min(mem_gib, mem_limit_gib)
    # Guests hold their whole RAM until their real use is measured; native
    # jobs share the host's memory and are charged their request.
    charged_mem_gib = kvm ? kvm_reserved_mem_gib(mem_limit_gib) : mem_gib
    return Allocation(cpus, cpus_limit, mem_gib, mem_limit_gib, charged_mem_gib)
end

#
# Slots
#

# A group's slots, created as jobs need them: a job leases the lowest free index,
# so the warmest caches are reused first and a new slot is only made when every
# existing one is busy. A group with `max_slots` makes at most that many.
mutable struct LeasePool
    brg::BuildkiteRunnerGroup
    # Slot `i` at index `i`, every one made since the scheduler started.
    slots::Vector{Slot}
    leased::Set{Int}
end

LeasePool(brg::BuildkiteRunnerGroup) = LeasePool(brg, [Slot(brg, 1)], Set{Int}())

running(pool::LeasePool) = length(pool.leased)
capped(brg::BuildkiteRunnerGroup) = brg.max_slots > 0
free_slots(pool::LeasePool) =
    capped(pool.brg) ? pool.brg.max_slots - running(pool) : typemax(Int)

function lease!(pool::LeasePool)
    idx = findfirst(∉(pool.leased), eachindex(pool.slots))
    if idx === nothing
        free_slots(pool) > 0 || return nothing
        push!(pool.slots, Slot(pool.brg, length(pool.slots) + 1))
        idx = lastindex(pool.slots)
    end
    push!(pool.leased, idx)
    return pool.slots[idx]
end

function release!(pool::LeasePool, slot::Slot)
    idx = findfirst(candidate -> candidate.name == slot.name, pool.slots)
    idx === nothing && error("slot $(slot.name) is not part of lease pool $(pool.brg.name)")
    idx in pool.leased || error("slot $(slot.name) is not currently leased")
    delete!(pool.leased, idx)
    return nothing
end

representative_slot(pool::LeasePool) = first(pool.slots)

# A slot name of this host (`<group>-<host>.<index>`, see `Slot`) as
# `(group, index)`, or `nothing` for any other name.
function parse_slot_name(name::AbstractString, hostname::AbstractString=get_short_hostname())
    parts = rsplit(name, "-$(hostname)."; limit=2)
    length(parts) == 2 && all(!isempty, parts) && all(isdigit, parts[2]) || return nothing
    index = tryparse(Int, parts[2])
    index === nothing && return nothing
    return (String(parts[1]), index)
end

# Whether `name` is a slot name of this host, of a configured group or not.
host_slot_name(name::AbstractString, hostname::AbstractString=get_short_hostname()) =
    parse_slot_name(name, hostname) !== nothing

# Whether `name` is a slot this configuration can lease, given each group's
# `max_slots` (0: any index): one of a removed group, or above a lowered
# `max_slots`, is not.
function configured_slot(max_slots::AbstractDict{String,Int}, name::AbstractString,
                         hostname::AbstractString=get_short_hostname())
    parsed = parse_slot_name(name, hostname)
    parsed === nothing && return false
    group, index = parsed
    haskey(max_slots, group) || return false
    cap = max_slots[group]
    return index >= 1 && (cap == 0 || index <= cap)
end

slot_caps(brgs) = Dict{String,Int}(brg.name => brg.max_slots for brg in brgs)

#
# Admission
#

struct AdmissionGroup
    name::String
    priority::Int
    free_slots::Int
    # Matches jobs against the group's tags; any slot of the group would do.
    representative::Slot
    priority_aging::Float64
end

AdmissionGroup(name, priority, free_slots, representative) =
    AdmissionGroup(name, priority, free_slots, representative, 0.0)

# A job's Buildkite priority, where a negative one rises by one for every
# `aging` seconds the job has been runnable, up to 0. Aging only lifts jobs into
# the default tier, where they then take their build's place by age; it never
# reorders jobs at 0 or above.
function effective_priority(job::Job, aging::Float64, now::Float64)
    (aging > 0 && job.priority < 0) || return job.priority
    runnable = buildkite_time(job.runnable_at)
    runnable === nothing && return job.priority
    steps = min(Float64(-job.priority), floor(max(now - runnable, 0.0) / aging))
    return job.priority + Int(steps)
end

# A pending job of one of a group's job sources, with what it would get.
struct Candidate
    group::String
    source::String
    job::Job
    alloc::Allocation
end

struct Admission
    group::String
    source::String
    job::Job
    alloc::Allocation
end

struct AdmissionResult
    admissions::Vector{Admission}
    # Groups with a job waiting for resources, or behind one that is.
    blocked::Dict{String,Bool}
    # Jobs whose request can never fit this host; they are skipped, not waited for.
    impossible::Vector{Candidate}
end

function eligible(candidate::Candidate, group::AdmissionGroup, claimed_jobs::Set{String},
                  quarantined_jobs::Dict{String,Float64}, now::Float64)
    candidate.job.id in claimed_jobs && return false
    get(quarantined_jobs, candidate.job.id, 0.0) > now && return false
    return mine(group.representative, candidate.job)
end

"""
    admission_plan(groups, candidates, free_cpus, free_mem_gib; ...)

One pass over the pending jobs of every group, in strict order: group priority,
then Buildkite job priority (higher first; a negative one raised towards 0 by
the group's `priority_aging`), then age (the build's `scheduled_at`, then the job id). Each job is admitted while its CPU request,
and its memory charge (`Allocation.charged_mem_gib`: a native job's memory
request, a KVM guest's RAM plus host overhead), fit what is left; a request of
zero CPUs and zero memory always fits. The first job that does not fit stops
the pass: nothing after it is admitted, so a big job is not starved by smaller
ones behind it, whatever their group.

The order is over the jobs this host could start now. Not in it, so neither
running nor blocking: jobs of a group at its `max_slots` (only that group's own
jobs can free a slot; holding back others meanwhile would idle the host), claimed and
quarantined jobs, jobs the group's tags do not match, and jobs whose memory
charge exceeds `total_mem_gib` (returned as `impossible`).

Polling is asynchronous and bounded (see `StacksJobSource`), so the order is
over the jobs listed so far, not everything queued in Buildkite at this instant.
"""
function admission_plan(groups::Vector{AdmissionGroup}, candidates::Vector{Candidate},
                        free_cpus::Integer, free_mem_gib::Integer=typemax(Int);
                        total_mem_gib::Integer=typemax(Int),
                        claimed_jobs::Set{String}=Set{String}(),
                        quarantined_jobs::Dict{String,Float64}=Dict{String,Float64}(),
                        now::Float64=time())
    by_name = Dict(group.name => group for group in groups)
    slots = Dict(group.name => group.free_slots for group in groups)
    blocked = Dict(group.name => false for group in groups)

    ordered = sort(filter(candidate -> haskey(by_name, candidate.group), candidates);
        by=candidate -> (by_name[candidate.group].priority,
                         -effective_priority(candidate.job, by_name[candidate.group].priority_aging, now),
                         candidate.job.scheduled_at, candidate.job.id))
    remaining_cpus = Int(free_cpus)
    remaining_mem = Int(free_mem_gib)
    head_blocked = false
    admissions = Admission[]
    impossible = Candidate[]
    planned_claims = Set{String}(claimed_jobs)
    for candidate in ordered
        group = by_name[candidate.group]
        slots[group.name] > 0 || continue
        eligible(candidate, group, planned_claims, quarantined_jobs, now) || continue
        alloc = candidate.alloc
        if alloc.charged_mem_gib > total_mem_gib
            push!(impossible, candidate)
            continue
        end
        # Past a job that does not fit, the pass only records who waits.
        if head_blocked || alloc.cpus > remaining_cpus || alloc.charged_mem_gib > remaining_mem
            blocked[group.name] = true
            head_blocked = true
            continue
        end
        remaining_cpus -= alloc.cpus
        remaining_mem -= alloc.charged_mem_gib
        push!(admissions, Admission(group.name, candidate.source, candidate.job, alloc))
        push!(planned_claims, candidate.job.id)
        slots[group.name] -= 1
    end
    return AdmissionResult(admissions, blocked, impossible)
end
