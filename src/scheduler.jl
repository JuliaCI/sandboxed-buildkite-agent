#
# Scheduler types
#

struct Assignment
    slot::Slot
    job::Job
    plan::CachePlan
end

mutable struct Scheduler
    config::SchedulerConfig
    slots::Vector{Slot}
    sources::Dict{String,JobSource}
    backends::Dict{String,PlatformBackend}
    # Pending jobs are grouped by runner group.  Each Stacks source is already
    # scoped to one queue, so group-local pending state prevents cross-queue
    # dispatch when queue tags are omitted from a scheduled job.
    pending_jobs::Dict{String,Vector{Job}}
    claimed_jobs::Set{String}
    claimed_slots::Set{String}
    lock::ReentrantLock
    pending_jobs_changed::Threads.Condition
    draining::Bool
    dry_run::Bool
end

#
# Construction & configuration checks
#

function scheduler_slots(brgs::Vector{BuildkiteRunnerGroup})
    slots = Slot[]
    for brg in sort(brgs, by=brg -> brg.name)
        append!(slots, [Slot(brg, idx) for idx in 1:brg.num_agents])
    end
    return slots
end

function Scheduler(config::SchedulerConfig, brgs::Vector{BuildkiteRunnerGroup},
                   sources::AbstractDict, backends::AbstractDict;
                   dry_run::Bool=false)
    slots = scheduler_slots(brgs)
    lock = ReentrantLock()
    backend_dict = Dict{String,PlatformBackend}(String(k) => v for (k, v) in backends)
    missing_backends = setdiff(unique(slot.brg.backend for slot in slots), keys(backend_dict))
    isempty(missing_backends) || error("Missing scheduler backend(s): $(join(missing_backends, ", "))")

    sources_by_group = Dict{String,JobSource}(string(k) => v for (k, v) in sources)
    queued_groups = Set(brg.name for brg in brgs if !isempty(brg.queues))
    missing_sources = setdiff(queued_groups, keys(sources_by_group))
    isempty(missing_sources) || error("Missing scheduler job source(s): $(join(sort(collect(missing_sources)), ", "))")

    pending = Dict{String,Vector{Job}}(group => Job[] for group in keys(sources_by_group))
    return Scheduler(config, slots, sources_by_group, backend_dict, pending, Set{String}(),
        Set{String}(), lock, Threads.Condition(lock), false, dry_run)
end

function make_backend(name::String, scheduler_config::SchedulerConfig,
                      brgs::Vector{BuildkiteRunnerGroup}=BuildkiteRunnerGroup[])
    name == BACKEND_LINUX_SANDBOX && return LinuxSandboxBackend(scheduler_config.logdir)
    name == BACKEND_MACOS_SEATBELT && return MacSeatbeltBackend(scheduler_config.logdir)
    name == BACKEND_KVM && return KVMBackend(scheduler_config.logdir,
        [brg for brg in brgs if brg.backend == BACKEND_KVM])
    error("unsupported scheduler backend: $(name)")
end

function make_backends(scheduler_config::SchedulerConfig, brgs::Vector{BuildkiteRunnerGroup})
    return Dict(name => make_backend(name, scheduler_config, brgs)
        for name in unique(brg.backend for brg in brgs))
end

function grouped_by_backend(slots::Vector{Slot})
    groups = Dict{String,Vector{Slot}}()
    for slot in slots
        push!(get!(groups, slot.brg.backend, Slot[]), slot)
    end
    return groups
end

function check_backend_configs(backends::AbstractDict{String,<:PlatformBackend},
                               brgs::Vector{BuildkiteRunnerGroup})
    for (name, backend) in backends
        check_config(backend, [brg for brg in brgs if brg.backend == name])
    end
    return nothing
end

function check_scheduler_config(config::SchedulerConfig)
    mkpath(config.logdir)
    return nothing
end

function check_scheduler_sources(scheduler::Scheduler)
    for source in values(scheduler.sources)
        check_source_config(source)
    end
    return nothing
end

#
# Stack registration & polling
#

function register_scheduler_sources!(scheduler::Scheduler)
    for source in values(scheduler.sources)
        register_stack(source)
    end
    return nothing
end

function deregister_scheduler_sources!(scheduler::Scheduler)
    for source in values(scheduler.sources)
        try
            deregister_stack(source)
        catch err
            @warn("Buildkite stack deregistration failed", exception=(err, catch_backtrace()))
        end
    end
    return nothing
end

function replace_pending_jobs!(scheduler::Scheduler, group::AbstractString, jobs::Vector{Job})
    lock(scheduler.lock)
    try
        scheduler.pending_jobs[string(group)] = [job for job in jobs if job.id ∉ scheduler.claimed_jobs]
        notify(scheduler.pending_jobs_changed; all=true)
    finally
        unlock(scheduler.lock)
    end
    return length(jobs)
end

function replace_pending_jobs!(scheduler::Scheduler, jobs::Vector{Job})
    for group in keys(scheduler.sources)
        replace_pending_jobs!(scheduler, group, jobs)
    end
    return length(jobs)
end

function is_draining(scheduler::Scheduler)
    lock(scheduler.lock)
    try
        return scheduler.draining
    finally
        unlock(scheduler.lock)
    end
end

function begin_draining!(scheduler::Scheduler)
    lock(scheduler.lock)
    try
        already_draining = scheduler.draining
        scheduler.draining = true
        notify(scheduler.pending_jobs_changed; all=true)
        return already_draining
    finally
        unlock(scheduler.lock)
    end
end

function group_has_idle_slot(scheduler::Scheduler, group::AbstractString)
    lock(scheduler.lock)
    try
        return any(slot -> slot.brg.name == group && slot.name ∉ scheduler.claimed_slots,
            scheduler.slots)
    finally
        unlock(scheduler.lock)
    end
end

function poll_jobs!(scheduler::Scheduler, group::AbstractString)
    source = scheduler.sources[string(group)]
    dispatch = group_has_idle_slot(scheduler, group)
    result = try
        poll_result(source; dispatch)
    catch err
        # A dry run never registers a stack, so 404 is expected: no jobs.
        if scheduler.dry_run && err isa BuildkiteHTTPError && err.status == 404
            @info("Dry run: Buildkite stack is not registered, no jobs to list",
                runner_group=group)
            return 0
        end
        rethrow()
    end
    if result.paused
        @info("Buildkite queue is paused; clearing pending jobs", runner_group=group)
        return replace_pending_jobs!(scheduler, group, Job[])
    elseif dispatch
        return replace_pending_jobs!(scheduler, group, result.jobs)
    else
        return length(result.jobs)
    end
end

function poll_jobs!(scheduler::Scheduler)
    return sum(poll_jobs!(scheduler, group) for group in keys(scheduler.sources); init=0)
end

#
# Cache planning
#

pipeline_cache_key(job::Job) = safe_path_component(job.pipeline_id, "unknown-pipeline")

function cache_plan(slot::Slot, job::Job, trust::Symbol)
    pipeline = pipeline_cache_key(job)
    trust_name = string(trust)
    cache_pool = joinpath(cachedir(slot.brg), slot.name, pipeline, trust_name)
    ccache_pool = if !has_shared_cache(slot.brg)
        nothing
    else
        joinpath(sharedcachedir(slot.brg), pipeline, trust_name)
    end
    return CachePlan(cache_pool, ccache_pool, trust, pipeline)
end

#
# Job claiming & assignment
#

function take_claim_locked!(scheduler::Scheduler, slot::Slot)
    haskey(scheduler.sources, slot.brg.name) || return nothing
    pending = get!(scheduler.pending_jobs, slot.brg.name, Job[])
    idx = findfirst(job -> job.id ∉ scheduler.claimed_jobs && mine(slot, job), pending)
    idx === nothing && return nothing

    job = pending[idx]
    filter!(candidate -> candidate.id != job.id, pending)
    push!(scheduler.claimed_jobs, job.id)
    push!(scheduler.claimed_slots, slot.name)
    return (; slot, job)
end

function claim_job!(scheduler::Scheduler, slot::Slot; block::Bool=false)
    lock(scheduler.lock)
    try
        while true
            scheduler.draining && return nothing
            claim = take_claim_locked!(scheduler, slot)
            claim === nothing || return claim
            block || return nothing
            wait(scheduler.pending_jobs_changed)
        end
    finally
        unlock(scheduler.lock)
    end
end

function release!(scheduler::Scheduler, slot::Slot, job::Job)
    lock(scheduler.lock)
    try
        delete!(scheduler.claimed_jobs, job.id)
        delete!(scheduler.claimed_slots, slot.name)
        notify(scheduler.pending_jobs_changed; all=true)
    finally
        unlock(scheduler.lock)
    end
    return nothing
end

release!(scheduler::Scheduler, assignment::Assignment) =
    release!(scheduler, assignment.slot, assignment.job)

function assignment_from_claim!(scheduler::Scheduler, slot::Slot, job::Job)
    try
        if scheduler.dry_run
            # Trust is normally known only after reserving and fetching the job.
            # Keep dry-run read-only and use a synthetic partition for logging.
            return Assignment(slot, job, cache_plan(slot, job, :dry_run))
        end

        source = scheduler.sources[slot.brg.name]
        reservation = reserve_jobs(source, [job.id])
        if job.id ∉ reservation.reserved
            @info("Buildkite job was already reserved elsewhere",
                slot=slot.name,
                job=job.id,
                not_reserved=reservation.not_reserved)
            release!(scheduler, slot, job)
            return nothing
        end

        # After this point, a pre-acquire backend failure leaves the job reserved
        # until Buildkite's reservation expiry releases it for another worker.
        trust = try
            trust_from_env(get_job_env(source, job.id))
        catch err
            @warn("Buildkite job env fetch failed after reservation; using untrusted cache",
                slot=slot.name,
                job=job.id,
                exception=(err, catch_backtrace()))
            :untrusted
        end
        plan = cache_plan(slot, job, trust)
        return Assignment(slot, job, plan)
    catch
        release!(scheduler, slot, job)
        rethrow()
    end
end

function take_assignment!(scheduler::Scheduler, slot::Slot; block::Bool=false)
    while true
        claim = claim_job!(scheduler, slot; block)
        claim === nothing && return nothing
        assignment = assignment_from_claim!(scheduler, claim.slot, claim.job)
        assignment === nothing || return assignment
    end
end

#
# Running jobs
#

function log_assignment(assignment::Assignment)
    job = assignment.job
    plan = assignment.plan
    @info("Selected Buildkite job",
        slot=assignment.slot.name,
        runner_group=assignment.slot.brg.name,
        job=job.id,
        pipeline=plan.pipeline,
        trust=plan.trust,
        backend=assignment.slot.brg.backend,
        cache_pool=plan.cache_pool,
        ccache_pool=plan.ccache_pool)
end

function finish_assignment(assignment::Assignment, code::Integer)
    level = code in (0, 27, 28) ? Logging.Info : Logging.Warn
    @logmsg level "Buildkite job finished" slot=assignment.slot.name job=assignment.job.id exit_code=code
    return code
end

function run_assignment!(scheduler::Scheduler, assignment::Assignment)
    log_assignment(assignment)

    handle = nothing
    try
        if !scheduler.dry_run
            backend = scheduler.backends[assignment.slot.brg.backend]
            handle = prepare(backend, assignment.slot, assignment.job, assignment.plan)
            code = run_job(handle)
            finish_assignment(assignment, code)
        end
    catch err
        @error("Buildkite job runner failed",
            slot=assignment.slot.name,
            job=assignment.job.id,
            exception=(err, catch_backtrace()))
    finally
        handle === nothing || reap(handle)
        release!(scheduler, assignment)
    end
    return nothing
end

function run_available_assignment!(scheduler::Scheduler, slot::Slot; block::Bool=false)
    assignment = take_assignment!(scheduler, slot; block)
    assignment === nothing && return false
    run_assignment!(scheduler, assignment)
    return true
end

function run_once!(scheduler::Scheduler)
    poll_jobs!(scheduler)
    count = 0
    for slot in scheduler.slots
        run_available_assignment!(scheduler, slot) && (count += 1)
    end
    return count
end

#
# Main loop
#

function scheduler_error_sleep(config::SchedulerConfig, err)
    err isa BuildkiteRateLimited && return max(err.reset_in, config.error_sleep)
    return config.error_sleep
end

function poll_forever!(scheduler::Scheduler, group::AbstractString)
    sleep_interval = min(scheduler.config.poll_interval, 30.0)
    while !is_draining(scheduler)
        try
            poll_jobs!(scheduler, group)
        catch err
            if err isa BuildkiteHTTPError && 400 <= err.status < 500
                # Permanent client error (404 missing stack, 401 revoked token,
                # ...): can't fix in-process, so exit and let the supervisor
                # restart and re-register.  No backoff; RestartSec paces it.
                @error("Buildkite Stacks API client error; exiting for supervisor restart",
                    runner_group=group, status=err.status)
                exit(1)
            end
            if err isa BuildkiteRateLimited
                @warn("Buildkite rate limited; backing off", runner_group=group,
                    seconds=err.reset_in)
                sleep(scheduler_error_sleep(scheduler.config, err))
                continue
            end
            # Transient (5xx, network): back off in-process so a blip doesn't
            # trip the supervisor's restart limit.
            @error("Buildkite polling failed", runner_group=group,
                exception=(err, catch_backtrace()))
            sleep(scheduler_error_sleep(scheduler.config, err))
            continue
        end
        sleep(sleep_interval)
    end
end

function slot_worker!(scheduler::Scheduler, slot::Slot)
    while !is_draining(scheduler)
        try
            run_available_assignment!(scheduler, slot; block=true) || break
        catch err
            if err isa BuildkiteRateLimited
                @warn("Buildkite rate limited while claiming job; backing off",
                    slot=slot.name,
                    seconds=err.reset_in)
                sleep(scheduler_error_sleep(scheduler.config, err))
                continue
            end
            @error("Scheduler slot worker failed",
                slot=slot.name,
                exception=(err, catch_backtrace()))
            sleep(scheduler_error_sleep(scheduler.config, err))
        end
    end
end

function start_scheduler!(scheduler::Scheduler)
    check_scheduler_config(scheduler.config)
    check_scheduler_sources(scheduler)
    if !scheduler.dry_run
        slots_by_backend = grouped_by_backend(scheduler.slots)
        for (name, backend) in scheduler.backends
            cleanup(backend)
            setup_backend!(backend, get(slots_by_backend, name, Slot[]))
        end
        register_scheduler_sources!(scheduler)
    end
    return nothing
end

function cleanup_scheduler!(scheduler::Scheduler)
    if !scheduler.dry_run
        deregister_scheduler_sources!(scheduler)
        for backend in values(scheduler.backends)
            try
                cleanup(backend)
            catch err
                @warn("Scheduler cleanup failed during exit", exception=(err, catch_backtrace()))
            end
        end
    end
    return nothing
end

function run_forever!(scheduler::Scheduler)
    start_scheduler!(scheduler)
    atexit() do
        cleanup_scheduler!(scheduler)
    end
    workers = [@async slot_worker!(scheduler, slot) for slot in scheduler.slots]
    for group in keys(scheduler.sources)
        @async poll_forever!(scheduler, group)
    end
    foreach(wait, workers)
end
