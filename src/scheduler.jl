#
# Scheduler types
#

struct Assignment
    slot::Slot
    job::Job
    plan::CachePlan
    alloc::Allocation
end

mutable struct Scheduler
    config::SchedulerConfig
    brgs::Vector{BuildkiteRunnerGroup}
    cpu_pool::CpuPool
    lease_pools::Dict{String,LeasePool}
    sources::Dict{String,JobSource}
    backends::Dict{String,PlatformBackend}
    # Pending jobs are grouped by runner group.  Each Stacks source is already
    # scoped to one queue, so group-local pending state prevents cross-queue
    # dispatch when queue tags are omitted from a scheduled job.
    pending_jobs::Dict{String,Vector{Job}}
    claimed_jobs::Set{String}
    job_failures::Dict{String,Int}
    quarantined_jobs::Dict{String,Float64}
    slot_status::Dict{String,Dict{String,Any}}
    poll_status::Dict{String,Dict{String,Any}}
    started_at::Float64
    lock::ReentrantLock
    pending_jobs_changed::Threads.Condition
    dry_run::Bool
end

#
# Construction & configuration checks
#

function scheduler_slots(brgs::Vector{BuildkiteRunnerGroup})
    slots = Slot[]
    for brg in sort(brgs, by=brg -> brg.name)
        append!(slots, [Slot(brg, idx) for idx in 1:brg.max_jobs])
    end
    return slots
end

function Scheduler(config::SchedulerConfig, brgs::Vector{BuildkiteRunnerGroup},
                   sources::AbstractDict, backends::AbstractDict;
                   dry_run::Bool=false)
    lock = ReentrantLock()
    brgs = sort(collect(brgs), by=brg -> brg.name)
    lease_pools = Dict{String,LeasePool}(brg.name => LeasePool(brg) for brg in brgs)
    cpu_pool = CpuPool(config.total_cpus)
    backend_dict = Dict{String,PlatformBackend}(String(k) => v for (k, v) in backends)
    missing_backends = setdiff(unique(brg.backend for brg in brgs), keys(backend_dict))
    isempty(missing_backends) || error("Missing scheduler backend(s): $(join(missing_backends, ", "))")

    sources_by_group = Dict{String,JobSource}(string(k) => v for (k, v) in sources)
    queued_groups = Set(brg.name for brg in brgs if !isempty(brg.queues))
    missing_sources = setdiff(queued_groups, keys(sources_by_group))
    isempty(missing_sources) || error("Missing scheduler job source(s): $(join(sort(collect(missing_sources)), ", "))")

    pending = Dict{String,Vector{Job}}(group => Job[] for group in keys(sources_by_group))
    now = time()
    slot_status = Dict{String,Dict{String,Any}}()
    poll_status = Dict{String,Dict{String,Any}}(
        group => initial_poll_status(group, now) for group in keys(sources_by_group))
    return Scheduler(config, brgs, cpu_pool, lease_pools, sources_by_group,
        backend_dict, pending, Set{String}(), Dict{String,Int}(),
        Dict{String,Float64}(), slot_status,
        poll_status, now, lock, Threads.Condition(lock), dry_run)
end

function make_backend(name::String, scheduler_config::SchedulerConfig,
                      brgs::Vector{BuildkiteRunnerGroup}=BuildkiteRunnerGroup[])
    name == BACKEND_LINUX_SANDBOX && return LinuxSandboxBackend(scheduler_config.logdir)
    name == BACKEND_MACOS_SEATBELT && return MacSeatbeltBackend(scheduler_config.logdir)
    name == BACKEND_KVM && return KVMBackend(scheduler_config.logdir, brgs;
        total_cpus=scheduler_config.total_cpus)
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

function setup_backend_configs!(backends::AbstractDict{String,<:PlatformBackend},
                                brgs::Vector{BuildkiteRunnerGroup})
    for (name, backend) in backends
        setup_config!(backend, [brg for brg in brgs if brg.backend == name])
    end
    return nothing
end

function check_scheduler_config(config::SchedulerConfig)
    mkpath(config.logdir)
    return nothing
end

#
# Status snapshots
#

function scheduler_status_path(config::SchedulerConfig)
    return joinpath(config.logdir, "scheduler-status.json")
end

function job_status(job::Job)
    return Dict{String,Any}(
        "id" => job.id,
        "pipeline_id" => job.pipeline_id,
        "agent_query_rules" => job.agent_query_rules,
    )
end

function initial_poll_status(group::AbstractString, now::Float64=time())
    return Dict{String,Any}(
        "runner_group" => string(group),
        "last_poll_at" => nothing,
        "last_success_at" => nothing,
        "last_error" => nothing,
        "pending_jobs" => 0,
        "dispatch" => false,
        "paused" => false,
        "updated_at" => now,
    )
end

function set_slot_idle_locked!(scheduler::Scheduler, slot::Slot)
    delete!(scheduler.slot_status, slot.name)
    return nothing
end

function set_slot_status_locked!(scheduler::Scheduler, slot::Slot, state::AbstractString;
                                 job::Union{Nothing,Job}=nothing,
                                 plan::Union{Nothing,CachePlan}=nothing,
                                 log_path::Union{Nothing,String}=nothing,
                                 deadline::Union{Nothing,Float64}=nothing,
                                 now::Float64=time())
    previous = get(scheduler.slot_status, slot.name, Dict{String,Any}())
    previous_job = get(get(previous, "job", Dict{String,Any}()), "id", nothing)
    started_at = if job === nothing || previous_job != job.id
        now
    else
        get(previous, "started_at", now)
    end
    status = Dict{String,Any}(
        "name" => slot.name,
        "runner_group" => slot.brg.name,
        "backend" => slot.brg.backend,
        "queue" => first(slot.brg.queues),
        "state" => string(state),
        "updated_at" => now,
    )
    if job !== nothing
        status["job"] = job_status(job)
        status["started_at"] = started_at
    end
    if plan !== nothing
        status["cache_pool"] = plan.cache_pool
        status["ccache_pool"] = plan.ccache_pool
        status["trust"] = string(plan.trust)
        status["pipeline_cache_key"] = plan.pipeline
    end
    log_path === nothing || (status["log_path"] = log_path)
    deadline === nothing || (status["deadline_at"] = deadline)
    scheduler.slot_status[slot.name] = status
    return nothing
end

function record_slot_status!(scheduler::Scheduler, slot::Slot, state::AbstractString; kwargs...)
    lock(scheduler.lock)
    try
        set_slot_status_locked!(scheduler, slot, state; kwargs...)
    finally
        unlock(scheduler.lock)
    end
    return nothing
end

function record_poll_success!(scheduler::Scheduler, group::AbstractString;
                              pending_jobs::Integer,
                              dispatch::Bool,
                              paused::Bool,
                              now::Float64=time())
    lock(scheduler.lock)
    try
        scheduler.poll_status[string(group)] = Dict{String,Any}(
            "runner_group" => string(group),
            "last_poll_at" => now,
            "last_success_at" => now,
            "last_error" => nothing,
            "pending_jobs" => Int(pending_jobs),
            "dispatch" => dispatch,
            "paused" => paused,
            "updated_at" => now,
        )
    finally
        unlock(scheduler.lock)
    end
    return nothing
end

function record_poll_error!(scheduler::Scheduler, group::AbstractString, err;
                            now::Float64=time())
    lock(scheduler.lock)
    try
        status = get!(scheduler.poll_status, string(group), initial_poll_status(group, now))
        status["last_poll_at"] = now
        status["last_error"] = Dict{String,Any}(
            "at" => now,
            "message" => sprint(showerror, err),
        )
        status["updated_at"] = now
    finally
        unlock(scheduler.lock)
    end
    return nothing
end

function existing_disk_probe_path(path::AbstractString)
    probe = abspath(path)
    while !ispath(probe)
        parent = dirname(probe)
        parent == probe && return nothing
        probe = parent
    end
    return probe
end

function disk_status_snapshot(path::AbstractString)
    status = Dict{String,Any}("path" => string(path))
    probe = existing_disk_probe_path(path)
    if probe === nothing
        status["error"] = "no existing parent"
        return status
    end
    status["probe_path"] = probe
    try
        ds = diskstat(probe)
        status["total_bytes"] = ds.total
        status["used_bytes"] = ds.used
        status["available_bytes"] = ds.available
        status["used_percent"] = ds.total == 0 ? nothing : 100 * ds.used / ds.total
    catch err
        status["error"] = sprint(showerror, err)
    end
    return status
end

function scheduler_disk_roots(config::SchedulerConfig, brgs::Vector{BuildkiteRunnerGroup})
    roots = Set{String}([config.logdir])
    for brg in brgs
        push!(roots, cachedir(brg))
        push!(roots, tempdir(brg))
        has_shared_cache(brg) && push!(roots, sharedcachedir(brg))
        persistence_dir(brg) === nothing || push!(roots, persistence_dir(brg))
    end
    return sort(collect(roots))
end

function admission_groups_locked(scheduler::Scheduler)
    groups = AdmissionGroup[]
    for brg in scheduler.brgs
        haskey(scheduler.sources, brg.name) || continue
        pool = scheduler.lease_pools[brg.name]
        push!(groups, AdmissionGroup(
            brg.name,
            brg.priority,
            brg.job_cpus,
            brg.max_jobs,
            running(pool),
            get(scheduler.pending_jobs, brg.name, Job[]),
            representative_slot(pool),
        ))
    end
    return groups
end

function admission_plan_locked(scheduler::Scheduler; now::Float64=time())
    return admission_plan(
        admission_groups_locked(scheduler),
        free_cpus(scheduler.cpu_pool),
        scheduler.claimed_jobs,
        scheduler.quarantined_jobs;
        now,
    )
end

function pool_status_locked(scheduler::Scheduler)
    plan = admission_plan_locked(scheduler)
    groups = Dict{String,Any}()
    for brg in scheduler.brgs
        pool = scheduler.lease_pools[brg.name]
        groups[brg.name] = Dict{String,Any}(
            "running" => running(pool),
            "max_jobs" => brg.max_jobs,
            "job_cpus" => brg.job_cpus,
            "priority" => brg.priority,
            "blocked" => get(plan.blocked, brg.name, false),
        )
    end
    return Dict{String,Any}(
        "total_cpus" => scheduler.cpu_pool.total_cpus,
        "free_cpus" => free_cpus(scheduler.cpu_pool),
        "groups" => groups,
    )
end

function scheduler_status_snapshot(scheduler::Scheduler)
    state = lock(scheduler.lock) do
        Dict{String,Any}(
            "version" => 2,
            "generated_at" => time(),
            "started_at" => scheduler.started_at,
            "hostname" => gethostname(),
            "pid" => getpid(),
            "dry_run" => scheduler.dry_run,
            "logdir" => scheduler.config.logdir,
            "slots" => deepcopy(collect(values(scheduler.slot_status))),
            "pool" => pool_status_locked(scheduler),
            "pollers" => deepcopy(collect(values(scheduler.poll_status))),
            "claimed_jobs" => sort(collect(scheduler.claimed_jobs)),
            "quarantined_jobs" => deepcopy(scheduler.quarantined_jobs),
            "pending_jobs" => Dict(group => length(jobs)
                for (group, jobs) in scheduler.pending_jobs),
        )
    end
    state["disks"] = [disk_status_snapshot(path)
        for path in scheduler_disk_roots(scheduler.config, scheduler.brgs)]
    return state
end

function write_scheduler_status!(scheduler::Scheduler)
    path = scheduler_status_path(scheduler.config)
    mkpath(dirname(path))
    tmp = string(path, ".tmp.", getpid(), ".", rand(UInt))
    try
        open(tmp, "w") do io
            write(io, JSON.json(scheduler_status_snapshot(scheduler), 2))
            write(io, "\n")
        end
        mv(tmp, path; force=true)
    catch
        rm(tmp; force=true)
        rethrow()
    end
    return path
end

function write_scheduler_status_best_effort!(scheduler::Scheduler)
    try
        write_scheduler_status!(scheduler)
    catch err
        @warn("Unable to write scheduler status snapshot",
            path=scheduler_status_path(scheduler.config),
            exception=(err, catch_backtrace()))
    end
    return nothing
end

function read_scheduler_status_snapshot(config::SchedulerConfig)
    path = scheduler_status_path(config)
    isfile(path) || return nothing
    return JSON.parsefile(path)
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

function register_scheduler_source!(scheduler::Scheduler, group::AbstractString)
    source = scheduler.sources[string(group)]
    register_stack(source)
    return nothing
end

function register_scheduler_source_until_success!(scheduler::Scheduler, group::AbstractString;
                                                  sleep_fn::Function=sleep)
    while true
        try
            register_scheduler_source!(scheduler, group)
            return nothing
        catch err
            seconds = scheduler_error_sleep(scheduler.config, err)
            @error("Buildkite stack registration failed; retrying",
                runner_group=group,
                seconds,
                exception=(err, catch_backtrace()))
            sleep_fn(seconds)
        end
    end
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

function job_quarantined_locked!(scheduler::Scheduler, job_id::AbstractString, now::Float64)
    until = get(scheduler.quarantined_jobs, string(job_id), 0.0)
    if until <= now
        delete!(scheduler.quarantined_jobs, string(job_id))
        return false
    end
    return true
end

function replace_pending_jobs!(scheduler::Scheduler, group::AbstractString, jobs::Vector{Job})
    lock(scheduler.lock)
    try
        now = time()
        scheduler.pending_jobs[string(group)] = [
            job for job in jobs
            if job.id ∉ scheduler.claimed_jobs &&
               !job_quarantined_locked!(scheduler, job.id, now)
        ]
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

function group_can_dispatch(scheduler::Scheduler, group::AbstractString)
    lock(scheduler.lock)
    try
        pool = get(scheduler.lease_pools, string(group), nothing)
        pool === nothing && return false
        brg = pool.brg
        return running(pool) < brg.max_jobs &&
            (brg.job_cpus == 0 || free_cpus(scheduler.cpu_pool) >= brg.job_cpus)
    finally
        unlock(scheduler.lock)
    end
end

function poll_jobs!(scheduler::Scheduler, group::AbstractString)
    source = scheduler.sources[string(group)]
    dispatch = group_can_dispatch(scheduler, group)
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
        count = replace_pending_jobs!(scheduler, group, Job[])
        record_poll_success!(scheduler, group; pending_jobs=0, dispatch, paused=true)
        return count
    else
        count = replace_pending_jobs!(scheduler, group, result.jobs)
        record_poll_success!(scheduler, group; pending_jobs=length(result.jobs), dispatch, paused=false)
        return count
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

function take_dispatch_claims_locked!(scheduler::Scheduler; limit::Union{Nothing,Int}=nothing)
    plan = admission_plan_locked(scheduler)
    claims = NamedTuple[]
    for admission in plan.admissions
        limit !== nothing && length(claims) >= limit && break
        pool = scheduler.lease_pools[admission.group]
        slot = lease!(pool)
        if slot === nothing
            @warn("Admission selected a group with no free lease",
                runner_group=admission.group,
                job=admission.job.id)
            continue
        end
        alloc = allocate!(scheduler.cpu_pool, slot.brg.job_cpus)
        if alloc === nothing
            release!(pool, slot)
            @warn("Admission selected a job without available CPUs",
                runner_group=admission.group,
                job=admission.job.id,
                job_cpus=slot.brg.job_cpus,
                free_cpus=free_cpus(scheduler.cpu_pool))
            continue
        end
        pending = get!(scheduler.pending_jobs, admission.group, Job[])
        filter!(candidate -> candidate.id != admission.job.id, pending)
        push!(scheduler.claimed_jobs, admission.job.id)
        set_slot_status_locked!(scheduler, slot, "claiming"; job=admission.job)
        push!(claims, (; slot, job=admission.job, alloc))
    end
    return claims
end

function take_dispatch_claims!(scheduler::Scheduler; block::Bool=false,
                               limit::Union{Nothing,Int}=nothing)
    lock(scheduler.lock)
    try
        while true
            claims = take_dispatch_claims_locked!(scheduler; limit)
            !isempty(claims) && return claims
            block || return NamedTuple[]
            wait(scheduler.pending_jobs_changed)
        end
    finally
        unlock(scheduler.lock)
    end
end

function release!(scheduler::Scheduler, slot::Slot, job::Job, alloc::Allocation)
    lock(scheduler.lock)
    try
        delete!(scheduler.claimed_jobs, job.id)
        release!(scheduler.cpu_pool, alloc)
        release!(scheduler.lease_pools[slot.brg.name], slot)
        set_slot_idle_locked!(scheduler, slot)
        notify(scheduler.pending_jobs_changed; all=true)
    finally
        unlock(scheduler.lock)
    end
    return nothing
end

release!(scheduler::Scheduler, assignment::Assignment) =
    release!(scheduler, assignment.slot, assignment.job, assignment.alloc)

function assignment_from_claim!(scheduler::Scheduler, slot::Slot, job::Job,
                                alloc::Allocation)
    record_slot_status!(scheduler, slot, "claiming"; job)
    try
        if scheduler.dry_run
            # Trust is normally known only after reserving and fetching the job.
            # Keep dry-run read-only and use a synthetic partition for logging.
            plan = cache_plan(slot, job, :dry_run)
            record_slot_status!(scheduler, slot, "assigned"; job, plan)
            return Assignment(slot, job, plan, alloc)
        end

        source = scheduler.sources[slot.brg.name]
        reservation = reserve_jobs(source, [job.id])
        if job.id ∉ reservation.reserved
            @info("Buildkite job was already reserved elsewhere",
                slot=slot.name,
                job=job.id,
                not_reserved=reservation.not_reserved)
            release!(scheduler, slot, job, alloc)
            return nothing
        end
        record_slot_status!(scheduler, slot, "reserved"; job)

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
        record_slot_status!(scheduler, slot, "assigned"; job, plan)
        return Assignment(slot, job, plan, alloc)
    catch
        release!(scheduler, slot, job, alloc)
        rethrow()
    end
end

function take_assignment!(scheduler::Scheduler; block::Bool=false)
    while true
        claims = take_dispatch_claims!(scheduler; block, limit=1)
        isempty(claims) && return nothing
        for claim in claims
            assignment = assignment_from_claim!(scheduler, claim.slot, claim.job, claim.alloc)
            assignment === nothing || return assignment
        end
    end
end

take_assignment!(scheduler::Scheduler, ::Slot; block::Bool=false) =
    take_assignment!(scheduler; block)

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
        cpus=assignment.alloc.cpus,
        cpuset=assignment.alloc.cpuset,
        cache_pool=plan.cache_pool,
        ccache_pool=plan.ccache_pool)
end

function finish_assignment(assignment::Assignment, code::Integer)
    # `buildkite-agent start --acquire-job` exits 27 when the job was already
    # taken by another agent and 28 when the job is locked waiting on
    # dependencies (clicommand/agent_start.go); neither is a runner failure.
    level = code in (0, 27, 28) ? Logging.Info : Logging.Warn
    @logmsg level "Buildkite job finished" slot=assignment.slot.name job=assignment.job.id exit_code=code
    return code
end

assignment_deadline(scheduler::Scheduler; now_fn::Function=time) =
    now_fn() + scheduler.config.assignment_timeout_seconds

const JOB_FAILURE_BACKOFF_BASE_SECONDS = 60.0
const JOB_FAILURE_BACKOFF_MAX_SECONDS = 60 * 60.0

function job_failure_backoff(scheduler::Scheduler, failures::Integer)
    bounded_failures = min(max(Int(failures), 1), 10)
    exponential = JOB_FAILURE_BACKOFF_BASE_SECONDS * 2.0^(bounded_failures - 1)
    return min(max(exponential, Float64(scheduler.config.reservation_expiry_seconds)),
        JOB_FAILURE_BACKOFF_MAX_SECONDS)
end

function clear_job_failure!(scheduler::Scheduler, job_id::AbstractString)
    lock(scheduler.lock)
    try
        delete!(scheduler.job_failures, string(job_id))
        delete!(scheduler.quarantined_jobs, string(job_id))
    finally
        unlock(scheduler.lock)
    end
    return nothing
end

function quarantine_job!(scheduler::Scheduler, assignment::Assignment)
    job_id = assignment.job.id
    failures = 0
    backoff = 0.0
    lock(scheduler.lock)
    try
        failures = get(scheduler.job_failures, job_id, 0) + 1
        backoff = job_failure_backoff(scheduler, failures)
        scheduler.job_failures[job_id] = failures
        scheduler.quarantined_jobs[job_id] = time() + backoff
        for pending in values(scheduler.pending_jobs)
            filter!(job -> job.id != job_id, pending)
        end
        notify(scheduler.pending_jobs_changed; all=true)
    finally
        unlock(scheduler.lock)
    end
    @warn("Quarantined Buildkite job after runner failure",
        slot=assignment.slot.name,
        job=job_id,
        failures,
        seconds=backoff)
    return nothing
end

function assignment_failure_detail(assignment::Assignment, err)
    return join([
        "sandboxed-buildkite-agent failed to run a reserved job.",
        "slot: $(assignment.slot.name)",
        "runner_group: $(assignment.slot.brg.name)",
        "backend: $(assignment.slot.brg.backend)",
        "cpus: $(assignment.alloc.cpus)",
        "pipeline_cache_key: $(assignment.plan.pipeline)",
        "trust: $(assignment.plan.trust)",
        "error: $(sprint(showerror, err))",
    ], "\n")
end

function finish_failed_assignment!(scheduler::Scheduler, assignment::Assignment, err, bt)
    source = scheduler.sources[assignment.slot.brg.name]
    try
        finished = finish_job(source, assignment.job.id;
            exit_status=1,
            detail=assignment_failure_detail(assignment, err))
        if finished
            clear_job_failure!(scheduler, assignment.job.id)
        else
            quarantine_job!(scheduler, assignment)
        end
    catch finish_err
        @warn("Unable to mark failed Buildkite job finished; quarantining locally",
            slot=assignment.slot.name,
            job=assignment.job.id,
            original_exception=(err, bt),
            finish_exception=(finish_err, catch_backtrace()))
        quarantine_job!(scheduler, assignment)
    end
    return nothing
end

function reap_assignment_handle!(handle, assignment::Assignment)
    handle === nothing && return nothing
    try
        reap(handle)
    catch err
        @warn("Buildkite job cleanup failed",
            slot=assignment.slot.name,
            job=assignment.job.id,
            exception=(err, catch_backtrace()))
    end
    return nothing
end

function run_assignment!(scheduler::Scheduler, assignment::Assignment)
    log_assignment(assignment)

    handle = nothing
    deadline = assignment_deadline(scheduler)
    try
        if !scheduler.dry_run
            backend = scheduler.backends[assignment.slot.brg.backend]
            record_slot_status!(scheduler, assignment.slot, "preparing";
                job=assignment.job, plan=assignment.plan, deadline)
            handle = prepare(backend, assignment.slot, assignment.job,
                assignment.plan, assignment.alloc)
            log_path = hasproperty(handle, :log_path) ? getproperty(handle, :log_path) : nothing
            record_slot_status!(scheduler, assignment.slot, "running";
                job=assignment.job, plan=assignment.plan, log_path, deadline)
            code = run_job(handle, deadline)
            record_slot_status!(scheduler, assignment.slot, "finishing";
                job=assignment.job, plan=assignment.plan, log_path, deadline)
            finish_assignment(assignment, code)
            clear_job_failure!(scheduler, assignment.job.id)
        end
    catch err
        bt = catch_backtrace()
        @error("Buildkite job runner failed",
            slot=assignment.slot.name,
            job=assignment.job.id,
            exception=(err, bt))
        reap_assignment_handle!(handle, assignment)
        handle = nothing
        scheduler.dry_run || finish_failed_assignment!(scheduler, assignment, err, bt)
    finally
        reap_assignment_handle!(handle, assignment)
        release!(scheduler, assignment)
    end
    return nothing
end

function run_available_assignment!(scheduler::Scheduler; block::Bool=false)
    assignment = take_assignment!(scheduler; block)
    assignment === nothing && return false
    run_assignment!(scheduler, assignment)
    return true
end

run_available_assignment!(scheduler::Scheduler, ::Slot; block::Bool=false) =
    run_available_assignment!(scheduler; block)

function dry_run_assignments(scheduler::Scheduler)
    lock(scheduler.lock)
    try
        plan = admission_plan_locked(scheduler)
        assignments = Assignment[]
        for admission in plan.admissions
            lease_pool = scheduler.lease_pools[admission.group]
            slot = representative_slot(lease_pool)
            alloc = Allocation(slot.brg.job_cpus, "")
            push!(assignments, Assignment(slot, admission.job,
                cache_plan(slot, admission.job, :dry_run), alloc))
        end
        return assignments
    finally
        unlock(scheduler.lock)
    end
end

function run_once!(scheduler::Scheduler)
    poll_jobs!(scheduler)
    if scheduler.dry_run
        assignments = dry_run_assignments(scheduler)
        foreach(log_assignment, assignments)
        return length(assignments)
    end

    count = 0
    claims = take_dispatch_claims!(scheduler)
    for claim in claims
        assignment = assignment_from_claim!(scheduler, claim.slot, claim.job, claim.alloc)
        assignment === nothing && continue
        run_assignment!(scheduler, assignment)
        count += 1
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

# Errors that recover on their own if we keep polling: rate limits, server-side
# 5xx, and transport failures (network/DNS/connection).  `stacks_request`
# already fast-retries these; reaching here means that was exhausted, so we back
# off and keep trying rather than take the scheduler down for a passing outage.
function is_transient_poll_error(err)
    err isa BuildkiteRateLimited && return true
    err isa BuildkiteHTTPError && return 500 <= err.status < 600
    err isa Downloads.RequestError && return true
    return false
end

function handle_poll_error!(scheduler::Scheduler, group::AbstractString, err, bt;
                            sleep_fn::Function=sleep)
    record_poll_error!(scheduler, group, err)

    # A missing stack is recoverable: re-register and resume (dry runs never
    # register, so there is nothing to recover there).
    if err isa BuildkiteHTTPError && err.status == 404
        scheduler.dry_run && return nothing
        @warn("Buildkite stack was not found; re-registering",
            runner_group=group,
            status=err.status,
            exception=(err, bt))
        register_scheduler_source_until_success!(scheduler, group; sleep_fn)
        return nothing
    end

    # Transient outages: back off in-process and keep polling.  We never exit for
    # these, so a Buildkite/network outage doesn't require restarting every host.
    if is_transient_poll_error(err)
        seconds = scheduler_error_sleep(scheduler.config, err)
        @warn("Buildkite polling failed transiently; backing off",
            runner_group=group,
            seconds,
            exception=(err, bt))
        sleep_fn(seconds)
        return nothing
    end

    # Everything else — a revoked/invalid token (401/403), a malformed request,
    # or an unexpected bug — will not fix itself.  Propagate so the supervisor
    # leaves the unit stopped (`Restart=no`) for an operator to diagnose, rather
    # than silently restarting into the same fault.
    @error("Buildkite polling failed fatally; stopping scheduler",
        runner_group=group,
        exception=(err, bt))
    throw(err)
end

function poll_forever!(scheduler::Scheduler, group::AbstractString)
    sleep_interval = min(scheduler.config.poll_interval, 30.0)
    while true
        try
            poll_jobs!(scheduler, group)
        catch err
            handle_poll_error!(scheduler, group, err, catch_backtrace())
            continue
        end
        sleep(sleep_interval)
    end
end

function run_claimed_job_task!(scheduler::Scheduler, slot::Slot, job::Job, alloc::Allocation)
    try
        assignment = assignment_from_claim!(scheduler, slot, job, alloc)
        assignment === nothing && return nothing
        run_assignment!(scheduler, assignment)
    catch err
        if err isa BuildkiteRateLimited
            @warn("Buildkite rate limited while claiming job; backing off",
                slot=slot.name,
                job=job.id,
                seconds=err.reset_in)
            sleep(scheduler_error_sleep(scheduler.config, err))
        else
            @error("Scheduler job task failed",
                slot=slot.name,
                job=job.id,
                exception=(err, catch_backtrace()))
            sleep(scheduler_error_sleep(scheduler.config, err))
        end
    end
    return nothing
end

function dispatch_forever!(scheduler::Scheduler)
    while true
        try
            claims = take_dispatch_claims!(scheduler; block=true)
            for claim in claims
                @async run_claimed_job_task!(scheduler, claim.slot, claim.job, claim.alloc)
            end
        catch err
            @error("Scheduler dispatcher failed",
                exception=(err, catch_backtrace()))
            sleep(scheduler_error_sleep(scheduler.config, err))
        end
    end
end

function start_scheduler!(scheduler::Scheduler; register_sources::Bool=true)
    check_scheduler_config(scheduler.config)
    check_scheduler_sources(scheduler)
    write_scheduler_status_best_effort!(scheduler)
    if !scheduler.dry_run
        slots_by_backend = grouped_by_backend(scheduler_slots(scheduler.brgs))
        for (name, backend) in scheduler.backends
            setup_backend!(backend, get(slots_by_backend, name, Slot[]))
            cleanup(backend)
        end
        register_sources && register_scheduler_sources!(scheduler)
    end
    return nothing
end

function cleanup_scheduler!(scheduler::Scheduler)
    if !scheduler.dry_run
        cleanup_scheduler_resources!(scheduler)
    end
    return nothing
end

function cleanup_scheduler_resources!(scheduler::Scheduler)
    deregister_scheduler_sources!(scheduler)
    for backend in values(scheduler.backends)
        try
            cleanup(backend)
        catch err
            @warn("Scheduler backend cleanup failed during teardown",
                exception=(err, catch_backtrace()))
        end
    end
    return nothing
end

# The heartbeat is the sole writer of the on-disk status snapshot; state
# transitions only mutate the in-memory status, so `bk status` may lag by up
# to one heartbeat interval.
function heartbeat_forever!(scheduler::Scheduler)
    sleep_interval = min(scheduler.config.poll_interval, 30.0)
    while true
        write_scheduler_status_best_effort!(scheduler)
        sleep(sleep_interval)
    end
end

function launch_scheduler_task(f::Function, failures::Channel, label::AbstractString)
    return @async begin
        try
            f()
            put!(failures, (; label=string(label),
                exception=ErrorException("scheduler task exited unexpectedly"),
                backtrace=backtrace()))
        catch err
            put!(failures, (; label=string(label),
                exception=err,
                backtrace=catch_backtrace()))
        end
    end
end

function run_forever!(scheduler::Scheduler)
    atexit() do
        cleanup_scheduler!(scheduler)
    end
    start_scheduler!(scheduler; register_sources=false)

    failures = Channel{NamedTuple}(length(scheduler.sources) + 2)

    launch_scheduler_task(failures, "dispatcher") do
        dispatch_forever!(scheduler)
    end
    for group in keys(scheduler.sources)
        launch_scheduler_task(failures, "poller $(group)") do
            scheduler.dry_run || register_scheduler_source_until_success!(scheduler, group)
            poll_forever!(scheduler, group)
        end
    end
    launch_scheduler_task(failures, "status heartbeat") do
        heartbeat_forever!(scheduler)
    end
    failure = take!(failures)
    @error("Scheduler task failed",
        task=failure.label,
        exception=(failure.exception, failure.backtrace))
    throw(failure.exception)
end
