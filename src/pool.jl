struct Allocation
    cpus::Int
    # Parallelism the job is told to use (`JULIA_CPU_THREADS`); 0 leaves it unset.
    threads::Int
    # Memory limit; 0 leaves it unlimited.
    mem_gib::Int
end

Allocation(cpus::Integer) = Allocation(cpus, cpus, 0)

# CPUs are a budget, not specific cores: Linux enforces a job's share with
# `cpu.weight`, KVM with the domain's CPU shares, and the job sizes its own
# parallelism from `threads`.
mutable struct CpuPool
    total_cpus::Int
    allocated::Int
end

function CpuPool(total_cpus::Integer)
    total = Int(total_cpus)
    total >= 1 || throw(ArgumentError("CPU pool size must be at least 1"))
    return CpuPool(total, 0)
end

free_cpus(pool::CpuPool) = pool.total_cpus - pool.allocated

function allocate!(pool::CpuPool, cpus::Integer)
    n = Int(cpus)
    n >= 0 || throw(ArgumentError("CPU allocation size must be non-negative"))
    free_cpus(pool) >= n || return nothing
    pool.allocated += n
    return n
end

function release!(pool::CpuPool, alloc::Allocation)
    alloc.cpus <= pool.allocated ||
        error("releasing $(alloc.cpus) CPUs, but only $(pool.allocated) are allocated")
    pool.allocated -= alloc.cpus
    return nothing
end

mutable struct LeasePool
    brg::BuildkiteRunnerGroup
    slots::Vector{Slot}
    leased::Set{Int}
end

LeasePool(brg::BuildkiteRunnerGroup) =
    LeasePool(brg, [Slot(brg, idx) for idx in 1:brg.max_jobs], Set{Int}())

running(pool::LeasePool) = length(pool.leased)

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

struct AdmissionGroup
    name::String
    priority::Int
    job_cpus::Int
    max_jobs::Int
    running::Int
    pending::Vector{Job}
    representative::Slot
    # `pending` only holds the queue's oldest job (see `Scheduler.probed_groups`)
    probed::Bool
end

AdmissionGroup(name, priority, job_cpus, max_jobs, running, pending, representative) =
    AdmissionGroup(name, priority, job_cpus, max_jobs, running, pending, representative, false)

struct Admission
    group::String
    job::Job
end

struct AdmissionResult
    admissions::Vector{Admission}
    blocked::Dict{String,Bool}
end

function first_eligible_job(group::AdmissionGroup, claimed_jobs::Set{String},
                            quarantined_jobs::Dict{String,Float64}, now::Float64)
    for job in group.pending
        job.id in claimed_jobs && continue
        get(quarantined_jobs, job.id, 0.0) > now && continue
        mine(group.representative, job) || continue
        return job
    end
    return nothing
end

function admission_plan(groups::Vector{AdmissionGroup}, free_cpus::Integer,
                        claimed_jobs::Set{String}=Set{String}(),
                        quarantined_jobs::Dict{String,Float64}=Dict{String,Float64}();
                        now::Float64=time())
    ordered = sort(groups, by=group -> (group.priority, group.name))
    planned_claims = Set{String}(claimed_jobs)
    running_counts = Dict(group.name => group.running for group in ordered)
    remaining = Int(free_cpus)
    global_blocked = false
    admissions = Admission[]
    blocked = Dict{String,Bool}(group.name => false for group in ordered)

    for group in ordered
        if group.probed
            # Running the probed job could bypass higher-priority ones, so admit
            # nothing until the next full poll. Meanwhile, keep lower-priority
            # groups off the CPUs if this group is waiting for them, or has them
            # and is about to list its jobs.
            if group.job_cpus > 0 && running_counts[group.name] < group.max_jobs &&
                    (group.job_cpus <= remaining ||
                     first_eligible_job(group, planned_claims, quarantined_jobs, now) !== nothing)
                blocked[group.name] = group.job_cpus > remaining
                global_blocked = true
            end
            continue
        end
        while running_counts[group.name] < group.max_jobs
            job = first_eligible_job(group, planned_claims, quarantined_jobs, now)
            job === nothing && break

            if group.job_cpus == 0
                push!(admissions, Admission(group.name, job))
                push!(planned_claims, job.id)
                running_counts[group.name] += 1
                continue
            end

            if global_blocked
                blocked[group.name] = true
                break
            elseif group.job_cpus <= remaining
                push!(admissions, Admission(group.name, job))
                push!(planned_claims, job.id)
                running_counts[group.name] += 1
                remaining -= group.job_cpus
            else
                blocked[group.name] = true
                global_blocked = true
                break
            end
        end
    end

    return AdmissionResult(admissions, blocked)
end
