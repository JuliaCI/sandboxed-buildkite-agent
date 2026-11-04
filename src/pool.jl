struct Allocation
    # CPU request: charged against `total_cpus`, and the job's `cpu.weight`.
    cpus::Int
    # How many CPUs the job may run on (its affinity mask, `JULIA_CPU_THREADS`,
    # KVM vCPUs); 0 leaves it unset.
    cpus_limit::Int
    # Memory request: what the job typically uses. Not charged yet.
    mem_gib::Int
    # Linux `memory.max` or KVM guest RAM; 0 leaves Linux memory unlimited.
    mem_limit_gib::Int
    # Charged against `total_mem_gib`: KVM guest RAM plus host overhead.
    reserved_mem_gib::Int
end

Allocation(cpus::Integer) = Allocation(cpus, cpus, 0, 0, 0)
Allocation(cpus::Integer, cpus_limit::Integer, mem_gib::Integer) =
    Allocation(cpus, cpus_limit, mem_gib, mem_gib, 0)

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
# Size tags of earlier releases, with what replaced them.
const RENAMED_SCHED_TAGS = Dict("sched_threads" => "sched_cpus_limit")

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
unknown or renamed keys, operators other than `=`, keys set twice, values that
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
        if haskey(RENAMED_SCHED_TAGS, key)
            push!(errors, "`$(key)` was renamed to `$(RENAMED_SCHED_TAGS[key])`")
        elseif key ∉ SCHED_TAGS
            push!(errors, "`$(key)` is not a size tag; expected one of $(join(SCHED_TAGS, ", "))")
        elseif op != "="
            push!(errors, "`$(strip(rule))` must set `$(key)` with `=`")
        elseif key in seen
            push!(errors, "`$(key)` is set more than once")
        elseif something(tryparse(Int, value), 0) < 1
            push!(errors, "`$(key)=$(value)` is not a positive integer")
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
limit.
"""
function job_allocation(brg::BuildkiteRunnerGroup, job::Job, config::SchedulerConfig)
    macos = brg.backend == BACKEND_MACOS_SEATBELT
    isempty(sched_tag_errors(job; complete=!macos)) || return nothing
    if macos || isempty(sched_rules(job))
        size = macos ? brg.default :
            default_size(brg, job_queue(brg, job))
        size === nothing && return nothing
        cpus, cpus_limit = size.cpus, size.cpus_limit
        mem_gib, mem_limit_gib = size.mem_gib, size.mem_limit_gib
    else
        tags = sched_tags(job)
        cpus, mem_gib = tags["sched_cpus"], tags["sched_mem_gib"]
        cpus_limit = get(tags, "sched_cpus_limit", cpus)
        mem_limit_gib = get(tags, "sched_mem_limit_gib", mem_gib)
    end
    cpus = min(cpus, config.total_cpus)
    cpus_limit = min(cpus_limit, config.total_cpus)
    reserved_mem_gib = 0
    if brg.backend == BACKEND_KVM
        brg.max_cpus > 0 && (cpus_limit = min(cpus_limit, brg.max_cpus))
        if brg.max_mem_gib > 0
            mem_gib = min(mem_gib, brg.max_mem_gib)
            mem_limit_gib = min(mem_limit_gib, brg.max_mem_gib)
        end
        # Guests reserve their whole RAM until their real use is measured.
        reserved_mem_gib = kvm_reserved_mem_gib(mem_limit_gib)
    end
    # Clipping a limit clips its request with it: a job is not charged for
    # more CPUs than it can run on (a 6-vCPU guest asked for 8), nor expects
    # more memory than it may use.
    cpus_limit > 0 && (cpus = min(cpus, cpus_limit))
    mem_gib = min(mem_gib, mem_limit_gib)
    return Allocation(cpus, cpus_limit, mem_gib, mem_limit_gib, reserved_mem_gib)
end

#
# Slots
#

mutable struct LeasePool
    brg::BuildkiteRunnerGroup
    slots::Vector{Slot}
    leased::Set{Int}
end

LeasePool(brg::BuildkiteRunnerGroup) =
    LeasePool(brg, [Slot(brg, idx) for idx in 1:brg.max_slots], Set{Int}())

running(pool::LeasePool) = length(pool.leased)
free_slots(pool::LeasePool) = length(pool.slots) - running(pool)

# The lowest free index, so the warmest caches are reused first.
function lease!(pool::LeasePool)
    for idx in eachindex(pool.slots)
        if idx ∉ pool.leased
            push!(pool.leased, idx)
            return pool.slots[idx]
        end
    end
    return nothing
end

function release!(pool::LeasePool, slot::Slot)
    idx = findfirst(candidate -> candidate.name == slot.name, pool.slots)
    idx === nothing && error("slot $(slot.name) is not part of lease pool $(pool.brg.name)")
    idx in pool.leased || error("slot $(slot.name) is not currently leased")
    delete!(pool.leased, idx)
    return nothing
end

representative_slot(pool::LeasePool) = first(pool.slots)

#
# Admission
#

struct AdmissionGroup
    name::String
    priority::Int
    free_slots::Int
    # Matches jobs against the group's tags; any slot of the group would do.
    representative::Slot
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
    # Groups with a job waiting for resources (or for a full poll).
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

One pass over the pending jobs of every group, ordered by group priority, then
Buildkite job priority (higher first), then age (`scheduled_at`, then id). Each
job is admitted if its group has a free slot and its CPUs (and, for KVM, its
memory reservation) fit. The first job that does not fit blocks every job after
it, so large jobs are not starved by smaller ones behind them; jobs of groups
without a free slot neither run nor block. Jobs that charge nothing (fixed
`cpus = 0` groups, such as launchers) are always admitted while their group
has slots.

`probed_groups` are groups with a job source that could only list its oldest job
(see `Scheduler.probed_sources`). Until a full listing arrives, the order of
their jobs is unknown, so no job of equal or lower group priority is admitted.

The order covers the jobs listed so far; polling is asynchronous, so it is not a
strict order over everything queued in Buildkite.
"""
function admission_plan(groups::Vector{AdmissionGroup}, candidates::Vector{Candidate},
                        free_cpus::Integer, free_mem_gib::Integer=typemax(Int);
                        probed_groups=String[],
                        total_mem_gib::Integer=typemax(Int),
                        claimed_jobs::Set{String}=Set{String}(),
                        quarantined_jobs::Dict{String,Float64}=Dict{String,Float64}(),
                        now::Float64=time())
    by_name = Dict(group.name => group for group in groups)
    slots = Dict(group.name => group.free_slots for group in groups)
    blocked = Dict(group.name => false for group in groups)
    barrier = typemax(Int)
    for name in probed_groups
        group = get(by_name, name, nothing)
        (group === nothing || group.free_slots == 0) && continue
        barrier = min(barrier, group.priority)
        blocked[name] = true
    end

    ordered = sort(filter(candidate -> haskey(by_name, candidate.group), candidates);
        by=candidate -> (by_name[candidate.group].priority, -candidate.job.priority,
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
        if alloc.reserved_mem_gib > total_mem_gib
            push!(impossible, candidate)
            continue
        end
        charged = alloc.cpus > 0 || alloc.reserved_mem_gib > 0
        if charged
            if head_blocked || group.priority >= barrier
                blocked[group.name] = true
                continue
            end
            if alloc.cpus > remaining_cpus || alloc.reserved_mem_gib > remaining_mem
                blocked[group.name] = true
                head_blocked = true
                continue
            end
            remaining_cpus -= alloc.cpus
            remaining_mem -= alloc.reserved_mem_gib
        end
        push!(admissions, Admission(group.name, candidate.source, candidate.job, alloc))
        push!(planned_claims, candidate.job.id)
        slots[group.name] -= 1
    end
    return AdmissionResult(admissions, blocked, impossible)
end
