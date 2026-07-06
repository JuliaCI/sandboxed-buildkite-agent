struct Allocation
    cpus::Int
    cpuset::String
end

mutable struct CpuPool
    total_cpus::Int
    order::Vector{Int}
    allocated::Set{Int}
end

function CpuPool(total_cpus::Integer, order::Vector{Int}=cpu_topology_permutation())
    total = Int(total_cpus)
    total >= 1 || throw(ArgumentError("CPU pool size must be at least 1"))
    total <= length(order) ||
        throw(ArgumentError("CPU pool size $(total) exceeds CPU ordering length $(length(order))"))
    return CpuPool(total, collect(order[1:total]), Set{Int}())
end

free_cpu_ids(pool::CpuPool) = [cpu for cpu in pool.order if cpu ∉ pool.allocated]
free_cpus(pool::CpuPool) = length(free_cpu_ids(pool))

function allocation_cpu_ids(alloc::Allocation)
    alloc.cpus == 0 && return Int[]
    isempty(alloc.cpuset) && return Int[]
    return parse_cpu_list(alloc.cpuset)
end

function allocate!(pool::CpuPool, cpus::Integer)
    n = Int(cpus)
    n >= 0 || throw(ArgumentError("CPU allocation size must be non-negative"))
    n == 0 && return Allocation(0, "")
    free = free_cpu_ids(pool)
    length(free) >= n || return nothing
    ids = free[1:n]
    union!(pool.allocated, ids)
    return Allocation(n, condense_cpu_selection(ids))
end

function release!(pool::CpuPool, alloc::Allocation)
    ids = allocation_cpu_ids(alloc)
    for cpu in ids
        cpu in pool.order || error("CPU $(cpu) is not part of this pool")
        cpu in pool.allocated || error("CPU $(cpu) is not currently allocated")
    end
    setdiff!(pool.allocated, ids)
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
end

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
