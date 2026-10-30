struct Allocation
    cpus::Int
    # Parallelism the job is told to use (`JULIA_CPU_THREADS`, KVM vCPUs); 0
    # leaves it unset.
    threads::Int
    # Linux `memory.max` or KVM guest RAM; 0 leaves Linux memory unlimited.
    mem_gib::Int
    # Charged against `total_mem_gib`: KVM guest RAM plus host overhead.
    reserved_mem_gib::Int
end

Allocation(cpus::Integer) = Allocation(cpus, cpus, 0, 0)
Allocation(cpus::Integer, threads::Integer, mem_gib::Integer) =
    Allocation(cpus, threads, mem_gib, 0)

# CPUs and memory are budgets, not specific cores or pages: Linux enforces a
# job's CPU share with `cpu.weight`, KVM with the domain's CPU shares, and the
# job sizes its own parallelism from `threads`.
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
# `sched_threads` is optional and defaults to `sched_cpus`; only bursty jobs
# (builds) ask for more threads than the CPUs they are charged.
const SCHED_TAGS = ("sched_cpus", "sched_threads", "sched_mem_gib")
const REQUIRED_SCHED_TAGS = ("sched_cpus", "sched_mem_gib")

# The `sched_*` values a job asks for, keeping only positive integers.
function sched_tags(job::Job)
    tags = Dict{String,Int}()
    for rule in job.agent_query_rules
        key, sep, value = partition_rule(rule)
        sep == "=" && key in SCHED_TAGS && !haskey(tags, key) || continue
        parsed = tryparse(Int, value)
        parsed === nothing || parsed < 1 || (tags[key] = parsed)
    end
    return tags
end

function partition_rule(rule::AbstractString)
    idx = findfirst('=', rule)
    idx === nothing && return (strip(rule), "", "")
    return (strip(rule[begin:prevind(rule, idx)]), "=", strip(rule[nextind(rule, idx):end]))
end

# Size tags that are required but missing, or set but not positive integers.
function missing_sched_tags(job::Job)
    valid = sched_tags(job)
    set = Set(first(partition_rule(rule)) for rule in job.agent_query_rules)
    return [key for key in SCHED_TAGS
            if !haskey(valid, key) && (key in REQUIRED_SCHED_TAGS || key in set)]
end

"""
    job_allocation(brg, job, config)

What `job` gets on this host: the group's fixed `size` if it has one, otherwise
the job's `sched_cpus`, `sched_mem_gib` and optional `sched_threads` (default:
`sched_cpus`) tags (`nothing` if a required one is missing, or any is not a
positive integer). CPUs are
capped at `total_cpus`, and KVM vCPUs and guest RAM at the group's
`max_threads` and `max_mem_gib`.
"""
function job_allocation(brg::BuildkiteRunnerGroup, job::Job, config::SchedulerConfig)
    if brg.size !== nothing
        cpus, threads, mem_gib = brg.size.cpus, brg.size.threads, brg.size.mem_gib
    else
        isempty(missing_sched_tags(job)) || return nothing
        tags = sched_tags(job)
        cpus, mem_gib = tags["sched_cpus"], tags["sched_mem_gib"]
        threads = get(tags, "sched_threads", cpus)
    end
    cpus = min(cpus, config.total_cpus)
    reserved_mem_gib = 0
    if brg.backend == BACKEND_KVM
        brg.max_threads > 0 && (threads = min(threads, brg.max_threads))
        brg.max_mem_gib > 0 && (mem_gib = min(mem_gib, brg.max_mem_gib))
        reserved_mem_gib = kvm_reserved_mem_gib(mem_gib)
    end
    return Allocation(cpus, threads, mem_gib, reserved_mem_gib)
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
