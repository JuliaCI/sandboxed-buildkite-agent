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
    # Memory each job reserves against `total_mem_gib` (KVM only).
    job_mem_gib::Int
end

AdmissionGroup(name, priority, job_cpus, max_jobs, running, pending, representative,
               probed=false) =
    AdmissionGroup(name, priority, job_cpus, max_jobs, running, pending, representative,
        probed, 0)

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
                        free_mem_gib::Integer=typemax(Int),
                        now::Float64=time())
    ordered = sort(groups, by=group -> (group.priority, group.name))
    planned_claims = Set{String}(claimed_jobs)
    running_counts = Dict(group.name => group.running for group in ordered)
    remaining = Int(free_cpus)
    remaining_mem = Int(free_mem_gib)
    fits(group) = group.job_cpus <= remaining && group.job_mem_gib <= remaining_mem
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
                    (fits(group) ||
                     first_eligible_job(group, planned_claims, quarantined_jobs, now) !== nothing)
                blocked[group.name] = !fits(group)
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
            elseif fits(group)
                push!(admissions, Admission(group.name, job))
                push!(planned_claims, job.id)
                running_counts[group.name] += 1
                remaining -= group.job_cpus
                remaining_mem -= group.job_mem_gib
            else
                blocked[group.name] = true
                global_blocked = true
                break
            end
        end
    end

    return AdmissionResult(admissions, blocked)
end
