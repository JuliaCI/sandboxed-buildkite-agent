using Test, Logging, JSON, Downloads
using SandboxedBuildkiteAgent
import SandboxedBuildkiteAgent:
    BACKEND_KVM,
    BACKEND_LINUX_SANDBOX,
    BACKEND_MACOS_SEATBELT,
    BuildkiteHTTPError,
    BuildkiteRateLimited,
    BuildkiteRunnerGroup,
    CachePlan,
    claim_job!,
    Job,
    JobSource,
    KVMBackend,
    KVMHandle,
    KVM_WINDOWS_AGENT_READY_TIMEOUT,
    KVM_WINDOWS_AGENT_STABLE_FOR,
    LinuxSandboxBackend,
    PlatformBackend,
    Scheduler,
    SchedulerConfig,
    Slot,
    StacksJobSource,
    SystemdConfig,
    SystemdTarget,
    cache_plan,
    check_backend_configs,
    cleanup,
    condense_cpu_selection,
    cpu_topology_permutation,
    encode_query,
    ensure_kvm_cache_overlay,
    escape_uri,
    generate_scheduler_launchctl_script,
    generate_scheduler_systemd_script,
    get_job_env,
    build_seatbelt_env,
    guest_agent_ready_timeout,
    guest_agent_stable_for,
    handle_poll_error!,
    guest_exec_payload,
    job_cgroup_name,
    kvm_guest,
    kvm_backing_identity,
    kvm_cache_overlay_path,
    kvm_cache_overlay_stamp_path,
    kvm_group_prefixes,
    kvm_os_overlay_path,
    kvm_pristine_cache_image,
    kvm_pristine_os_image,
    kvm_scratch_dir,
    kvm_template_vars,
    kvm_xml_template,
    kvm_xml_path,
    mine,
    parse_scheduler_args,
    parse_status_args,
    parse_stop_args,
    prepare_kvm_log_file,
    poll_result,
    poll_jobs,
    poll_jobs!,
    prepare,
    parse_paused,
    rate_limit_reset_seconds,
    rails_path_escape,
    read_configs,
    read_scheduler_config,
    release!,
    replace_pending_jobs!,
    ReservationResult,
    reserve_jobs,
    run_available_assignment!,
    run_job,
    scheduler_cgroup_root,
    scheduler_error_sleep,
    scheduler_launchctl_service_installed,
    scheduler_systemd_service_installed,
    scheduled_job_from_json,
    setup_backend!,
    slot_cpu_assignments,
    stack_key_override,
    stacks_request,
    start_scheduler!,
    take_assignment!,
    trust_from_env,
    virsh,
    wrap_command_in_cgroup_join_file

function runner_group(; name="tester", cachedir_root=mktempdir(), sharedcache_root=nothing,
                      num_agents=1, num_cpus=0, backend=nothing,
                      host=Sys.islinux() ? :linux : :macos)
    config = Dict{String,Any}(
        "queues" => "build",
        "num_agents" => num_agents,
        "num_cpus" => num_cpus,
        "cachedir" => cachedir_root,
        "tags" => Dict{String,String}(
            "os" => "linux",
            "arch" => "x86_64",
            "sandbox_capable" => "true",
        ),
    )
    if sharedcache_root !== nothing
        config["sharedcache"] = sharedcache_root
    end
    if backend !== nothing
        config["backend"] = backend
    end
    return BuildkiteRunnerGroup(name, config; host)
end

function job(; id="job-1", pipeline_id="01800000-0000-0000-0000-000000000000",
             agent_query_rules=["queue=build", "os=linux", "arch=x86_64"])
    return Job(
        id,
        pipeline_id,
        collect(agent_query_rules),
    )
end

function test_scheduler_config()
    return SchedulerConfig(mktempdir(), 0.01, 0.01, 900)
end

@testset "scheduler config" begin
    config = Dict{String,Any}(
        "logdir" => "logs",
        "reservation_expiry_seconds" => 120,
    )
    parsed = SchedulerConfig(config; config_dir="/tmp")
    @test parsed.logdir == "/tmp/logs"
    @test parsed.poll_interval == 15.0
    @test parsed.error_sleep == 10.0
    @test parsed.reservation_expiry_seconds == 120
    @test_logs (:warn, "Ignoring unknown scheduler config key(s)") SchedulerConfig(Dict{String,Any}(
        "logdir" => "logs",
        "idle_sleep" => 1.0,
    ); config_dir="/tmp")
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "reservation_expiry_seconds" => 3601,
    ))
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "poll_interval" => 0,
    ))
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "error_sleep" => -1,
    ))
end

@testset "scheduler rate-limit backoff" begin
    config = SchedulerConfig(mktempdir(), 0.01, 5.0, 900)
    @test scheduler_error_sleep(config, ErrorException("boom")) == 5.0
    @test scheduler_error_sleep(config, BuildkiteRateLimited(1.0)) == 5.0
    @test scheduler_error_sleep(config, BuildkiteRateLimited(30.0)) == 30.0
end

@testset "runner group backend config" begin
    linux_group = BuildkiteRunnerGroup("linux", Dict{String,Any}("queues" => "build"); host=:linux)
    @test linux_group.backend == BACKEND_LINUX_SANDBOX

    mac_group = BuildkiteRunnerGroup("mac", Dict{String,Any}("queues" => "build"); host=:macos)
    @test mac_group.backend == BACKEND_MACOS_SEATBELT

    kvm_group = BuildkiteRunnerGroup("windows", Dict{String,Any}(
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "windows",
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
    ); host=:linux)
    @test kvm_group.backend == BACKEND_KVM
    @test kvm_guest(kvm_group) == "windows"
    @test kvm_group.tags["os"] == "windows"

    freebsd_group = BuildkiteRunnerGroup("freebsd", Dict{String,Any}(
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "freebsd",
        "tags" => Dict{String,String}("arch" => "x86_64"),
    ); host=:linux)
    @test freebsd_group.tags["os"] == "freebsd"

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => BACKEND_KVM,
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => BACKEND_LINUX_SANDBOX,
        "guest" => "freebsd",
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => "wat",
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => BACKEND_MACOS_SEATBELT,
    ); host=:linux)

    stack_group = BuildkiteRunnerGroup("stack", Dict{String,Any}(
        "queues" => "build",
        "stack_key" => "julia_stack_1",
    ); host=:linux)
    @test stack_key_override(stack_group) == "julia_stack_1"
    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "stack_key" => "not ok",
    ); host=:linux)

    @test_logs (:warn, "Ignoring unknown runner group config key(s)") BuildkiteRunnerGroup(
        "typo",
        Dict{String,Any}("queues" => "build", "num_agent" => 2);
        host=:linux,
    )
end

mutable struct StaticJobSource <: JobSource
    jobs::Vector{Job}
    envs::Dict{String,Dict{String,String}}
    reserved::Set{String}
    unavailable::Set{String}
    env_failures::Set{String}
    env_requests::Vector{String}
    registered::Int
    deregistered::Int
end
StaticJobSource(jobs::Vector{Job}) =
    StaticJobSource(jobs, Dict{String,Dict{String,String}}(), Set{String}(),
        Set{String}(), Set{String}(), String[], 0, 0)
poll_jobs(source::StaticJobSource) = source.jobs
poll_result(source::StaticJobSource; dispatch::Bool=true) =
    SandboxedBuildkiteAgent.JobPollResult(source.jobs, false)
function get_job_env(source::StaticJobSource, job_id::AbstractString)
    push!(source.env_requests, string(job_id))
    string(job_id) in source.env_failures && error("env unavailable")
    return get(source.envs, string(job_id), Dict{String,String}("BUILDKITE_PULL_REQUEST" => "false"))
end
function reserve_jobs(source::StaticJobSource, job_ids::Vector{String})
    reserved = String[]
    not_reserved = String[]
    for job_id in job_ids
        if job_id in source.unavailable || job_id in source.reserved
            push!(not_reserved, job_id)
        else
            push!(source.reserved, job_id)
            push!(reserved, job_id)
        end
    end
    return ReservationResult(reserved, not_reserved)
end
function SandboxedBuildkiteAgent.register_stack(source::StaticJobSource)
    source.registered += 1
    return nothing
end
function SandboxedBuildkiteAgent.deregister_stack(source::StaticJobSource)
    source.deregistered += 1
    return nothing
end

struct NullBackend <: PlatformBackend end

function test_scheduler(config::SchedulerConfig, brgs::Vector{BuildkiteRunnerGroup},
                        sources, backends; dry_run::Bool=false)
    source_map = if sources isa AbstractDict
        sources
    else
        Dict(brg.name => sources for brg in brgs if !isempty(brg.queues))
    end
    backend_map = if backends isa AbstractDict
        backends
    else
        backend_names = unique(brg.backend for brg in brgs)
        length(backend_names) == 1 || error("test helper cannot infer a single backend key")
        Dict(only(backend_names) => backends)
    end
    return Scheduler(config, brgs, source_map, backend_map; dry_run)
end

@testset "backend config checks accept concrete registries" begin
    @test check_backend_configs(Dict("null" => NullBackend()), BuildkiteRunnerGroup[]) === nothing
end

struct HTTPErrorSource <: JobSource
    status::Int
end
SandboxedBuildkiteAgent.poll_result(source::HTTPErrorSource; dispatch::Bool=true) =
    throw(BuildkiteHTTPError(source.status, "HTTP $(source.status)"))

mutable struct RecoveringHTTPErrorSource <: JobSource
    status::Int
    registered::Int
end
SandboxedBuildkiteAgent.register_stack(source::RecoveringHTTPErrorSource) =
    (source.registered += 1; nothing)

@testset "HTTP error polling" begin
    brg = runner_group(; cachedir_root=mktempdir())
    # Normal operation: HTTP errors propagate (poll loop crashes on 4xx).
    scheduler = test_scheduler(test_scheduler_config(), [brg],
        Dict(brg.name => HTTPErrorSource(404)), NullBackend())
    @test_throws BuildkiteHTTPError poll_jobs!(scheduler, brg.name)
    # Dry run: 404 is expected (no stack registered), so no jobs.
    dry = test_scheduler(test_scheduler_config(), [brg],
        Dict(brg.name => HTTPErrorSource(404)), NullBackend(); dry_run=true)
    @test with_logger(NullLogger()) do
        poll_jobs!(dry, brg.name)
    end == 0
    # Dry run must still surface other client errors (e.g. 403 bad token).
    dry403 = test_scheduler(test_scheduler_config(), [brg],
        Dict(brg.name => HTTPErrorSource(403)), NullBackend(); dry_run=true)
    @test_throws BuildkiteHTTPError poll_jobs!(dry403, brg.name)

    source404 = RecoveringHTTPErrorSource(404, 0)
    scheduler404 = test_scheduler(test_scheduler_config(), [brg],
        Dict(brg.name => source404), NullBackend())
    sleeps = Float64[]
    with_logger(NullLogger()) do
        handle_poll_error!(scheduler404, brg.name,
            BuildkiteHTTPError(404, "missing stack"), Any[];
            sleep_fn=seconds -> push!(sleeps, seconds))
    end
    @test source404.registered == 1
    @test isempty(sleeps)

    source403 = RecoveringHTTPErrorSource(403, 0)
    scheduler403 = test_scheduler(test_scheduler_config(), [brg],
        Dict(brg.name => source403), NullBackend())
    sleeps = Float64[]
    with_logger(NullLogger()) do
        handle_poll_error!(scheduler403, brg.name,
            BuildkiteHTTPError(403, "bad token"), Any[];
            sleep_fn=seconds -> push!(sleeps, seconds))
    end
    @test source403.registered == 0
    @test sleeps == [scheduler403.config.error_sleep]
end

mutable struct CleanupBackend <: PlatformBackend
    count::Int
    setup_slots::Int
end

function cleanup(backend::CleanupBackend)
    backend.count += 1
    return nothing
end

function setup_backend!(backend::CleanupBackend, slots)
    backend.setup_slots = length(slots)
    return nothing
end

@testset "cache partitioning" begin
    cache_root = mktempdir()
    shared_root = mktempdir()
    slot = Slot(runner_group(; cachedir_root=cache_root, sharedcache_root=shared_root), 2)

    trusted = cache_plan(slot, job(), :trusted)
    @test trusted.trust == :trusted
    @test trusted.cache_pool == joinpath(cache_root, slot.name, trusted.pipeline, "trusted")
    @test trusted.ccache_pool == joinpath(shared_root, trusted.pipeline, "trusted")

    untrusted = cache_plan(slot, job(), :untrusted)
    @test untrusted.trust == :untrusted
    @test untrusted.cache_pool == joinpath(cache_root, slot.name, untrusted.pipeline, "untrusted")
    @test untrusted.ccache_pool == joinpath(shared_root, untrusted.pipeline, "untrusted")

    malformed = cache_plan(slot, job(; pipeline_id="../../main"), :trusted)
    @test malformed.trust == :trusted
    @test malformed.pipeline == "unknown-pipeline"
    @test malformed.cache_pool == joinpath(cache_root, slot.name, "unknown-pipeline", "trusted")
end

@testset "agent query matching" begin
    slot = Slot(runner_group(), 1)
    @test mine(slot, job())
    @test mine(slot, job(; agent_query_rules=["queue=test", "os=linux", "arch=x86_64"]))
    @test mine(slot, job(; agent_query_rules=["queue!=test", "os=linux", "arch=x86_64"]))
    @test mine(slot, job(; agent_query_rules=["queue=build", "os=*"]))
    @test !mine(slot, job(; agent_query_rules=["queue=build", "os=macos"]))
    # Negation is not a Buildkite agent-targeting rule and fails closed.
    @test !mine(slot, job(; agent_query_rules=["queue=build", "os!=macos"]))
    @test !mine(slot, job(; agent_query_rules=["queue=build", "requires-gpu"]))
end

@testset "Stacks job source fixtures" begin
    @test escape_uri("julia lang/test") == "julia%20lang%2Ftest"
    @test rails_path_escape("stack.v1/test") == "stack%2Ev1%2Ftest"
    @test encode_query(["queue_key" => "build", "limit" => "100"]) ==
          "queue_key=build&limit=100"

    scheduled = scheduled_job_from_json(JSON.parse("""
    {
      "id": "scheduled-job",
      "pipeline": {"uuid": "01800000-0000-0000-0000-000000000000"},
      "build": {"uuid": "build-uuid", "number": 1, "branch": "main"},
      "agent_query_rules": ["queue=build", "os=linux"]
    }
    """))
    @test scheduled.id == "scheduled-job"
    @test scheduled.pipeline_id == "01800000-0000-0000-0000-000000000000"
    @test scheduled.agent_query_rules == ["queue=build", "os=linux"]

    @test !parse_paused(Dict("cluster_queue" => Dict("dispatch_paused" => false)))
    @test parse_paused(Dict("cluster_queue" => Dict("dispatch_paused" => true)))
    @test !parse_paused(Dict("cluster_queue" => Dict{String,Any}()))
    @test !parse_paused(Dict{String,Any}())

    @test trust_from_env(Dict("BUILDKITE_PULL_REQUEST" => "false")) == :trusted
    @test trust_from_env(Dict("BUILDKITE_PULL_REQUEST" => "123")) == :untrusted
    @test trust_from_env(Dict{String,String}()) == :untrusted

    secrets = mktempdir()
    token_path = joinpath(secrets, "buildkite-agent-token")
    Base.write(token_path, "agent-token\n")
    chmod(token_path, 0o600)
    brg = BuildkiteRunnerGroup("julia", Dict{String,Any}(
        "queues" => "build",
        "secrets_dir" => secrets,
        "stack_key" => "julia-test-stack",
    ); host=:linux)
    source = StacksJobSource(test_scheduler_config(), brg; endpoint="https://example.invalid")
    @test source.stack_key == "julia-test-stack"
    @test source.queue_key == "build"
    @test source.token_path == token_path

    # Buildkite sends the reset header as seconds-until-reset, not an epoch.
    @test rate_limit_reset_seconds(["RateLimit-User-Reset" => "60"]) == 60.0
    # `Retry-After` (what upstream buildkite-agent honors) wins over RateLimit-*.
    @test rate_limit_reset_seconds([
        "Retry-After" => "30",
        "RateLimit-User-Reset" => "45",
        "RateLimit-Reset" => "90",
    ]) == 30.0
    # Absent Retry-After, the per-user header wins over the org-scoped one.
    @test rate_limit_reset_seconds([
        "RateLimit-User-Reset" => "45",
        "RateLimit-Reset" => "90",
    ]) == 45.0
    @test rate_limit_reset_seconds(["ratelimit-reset" => "90"]) == 90.0
    @test rate_limit_reset_seconds(String[]) == 0.0
end

@testset "Stacks transport-error handling" begin
    secrets = mktempdir()
    token_path = joinpath(secrets, "buildkite-agent-token")
    Base.write(token_path, "agent-token\n")
    chmod(token_path, 0o600)
    brg = BuildkiteRunnerGroup("julia", Dict{String,Any}(
        "queues" => "build",
        "secrets_dir" => secrets,
        "stack_key" => "julia-test-stack",
    ); host=:linux)
    source = StacksJobSource(test_scheduler_config(), brg; endpoint="http://127.0.0.1:9")

    @test_throws Downloads.RequestError stacks_request(
        source, "GET", "/stacks/julia-test-stack/scheduled-jobs"; max_attempts=1)

    response = Downloads.Response("http", "http://127.0.0.1:9/x", 0, "",
        Pair{String,String}[])
    err = Downloads.RequestError("http://127.0.0.1:9/x", 7, "refused", response)
    @test_throws "RequestError has no field" err.status
end

@testset "scheduler assignment" begin
    build = runner_group(; cachedir_root=mktempdir())
    test = BuildkiteRunnerGroup("tester2", Dict{String,Any}(
        "queues" => "test",
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64"),
    ))
    slots = [Slot(build, 1), Slot(test, 1)]
    build_jobs = [
        job(; id="build-job", agent_query_rules=["queue=build", "os=linux"]),
    ]
    test_jobs = [
        job(; id="test-job", agent_query_rules=["queue=test", "os=linux"]),
    ]
    build_source = StaticJobSource(build_jobs)
    test_source = StaticJobSource(test_jobs)

    scheduler = test_scheduler(test_scheduler_config(), [build, test],
        Dict(build.name => build_source, test.name => test_source), NullBackend())
    replace_pending_jobs!(scheduler, build.name, poll_jobs(build_source))
    replace_pending_jobs!(scheduler, test.name, poll_jobs(test_source))

    assignments = filter(!isnothing, [take_assignment!(scheduler, slot) for slot in slots])
    @test [a.job.id for a in assignments] == ["build-job", "test-job"]
    @test assignments[1].slot.name == slots[1].name
    @test assignments[2].slot.name == slots[2].name
    @test build_source.reserved == Set(["build-job"])
    @test test_source.reserved == Set(["test-job"])
    @test build_source.env_requests == ["build-job"]
    @test test_source.env_requests == ["test-job"]
    @test scheduler.claimed_jobs == Set(["build-job", "test-job"])
    release!.(Ref(scheduler), assignments)

    build_source = StaticJobSource(build_jobs)
    scheduler = test_scheduler(test_scheduler_config(), [build, test],
        Dict(build.name => build_source, test.name => StaticJobSource(test_jobs)), NullBackend())
    replace_pending_jobs!(scheduler, build.name, poll_jobs(build_source))
    assignment = take_assignment!(scheduler, slots[1])
    @test assignment.job.id == "build-job"
    replace_pending_jobs!(scheduler, build.name, poll_jobs(build_source))
    @test all(job.id != "build-job" for job in scheduler.pending_jobs[build.name])
    release!(scheduler, assignment)
    build_source = StaticJobSource(build_jobs)
    scheduler = test_scheduler(test_scheduler_config(), [build, test],
        Dict(build.name => build_source, test.name => StaticJobSource(test_jobs)), NullBackend())
    replace_pending_jobs!(scheduler, build.name, poll_jobs(build_source))
    @test any(job.id == "build-job" for job in scheduler.pending_jobs[build.name])

    two_slot_group = runner_group(; cachedir_root=mktempdir(), num_agents=2)
    source = StaticJobSource([job(; id="single-job")])
    scheduler = test_scheduler(test_scheduler_config(), [two_slot_group],
        source, NullBackend())
    replace_pending_jobs!(scheduler, poll_jobs(source))
    first = take_assignment!(scheduler, scheduler.slots[1])
    second = take_assignment!(scheduler, scheduler.slots[2])
    @test first.job.id == "single-job"
    @test second === nothing

    duplicate_jobs = [job(; id="duplicate-job"), job(; id="duplicate-job")]
    source = StaticJobSource(duplicate_jobs)
    scheduler = test_scheduler(test_scheduler_config(), [two_slot_group],
        source, NullBackend())
    replace_pending_jobs!(scheduler, poll_jobs(source))
    first = take_assignment!(scheduler, scheduler.slots[1])
    second = take_assignment!(scheduler, scheduler.slots[2])
    @test first.job.id == "duplicate-job"
    @test second === nothing

    race_source = StaticJobSource([
        job(; id="already-reserved"),
        job(; id="next-job"),
    ])
    push!(race_source.unavailable, "already-reserved")
    scheduler = test_scheduler(test_scheduler_config(), [runner_group(; cachedir_root=mktempdir())],
        race_source, NullBackend())
    replace_pending_jobs!(scheduler, poll_jobs(race_source))
    assignment = take_assignment!(scheduler, only(scheduler.slots))
    @test assignment.job.id == "next-job"
    @test "already-reserved" ∉ scheduler.claimed_jobs

    env_failure_source = StaticJobSource([job(; id="env-failure")])
    push!(env_failure_source.env_failures, "env-failure")
    scheduler = test_scheduler(test_scheduler_config(), [runner_group(; cachedir_root=mktempdir())],
        env_failure_source, NullBackend())
    replace_pending_jobs!(scheduler, poll_jobs(env_failure_source))
    assignment = with_logger(NullLogger()) do
        take_assignment!(scheduler, only(scheduler.slots))
    end
    @test assignment.job.id == "env-failure"
    @test assignment.plan.trust == :untrusted
    @test env_failure_source.reserved == Set(["env-failure"])
    @test env_failure_source.env_requests == ["env-failure"]
    @test "env-failure" in scheduler.claimed_jobs
    release!(scheduler, assignment)

    dry_source = StaticJobSource([job(; id="dry-job")])
    dry_scheduler = test_scheduler(test_scheduler_config(), [runner_group(; cachedir_root=mktempdir())],
        dry_source, NullBackend(); dry_run=true)
    replace_pending_jobs!(dry_scheduler, poll_jobs(dry_source))
    dry_assignment = take_assignment!(dry_scheduler, only(dry_scheduler.slots))
    @test dry_assignment.job.id == "dry-job"
    @test dry_assignment.plan.trust == :dry_run
    @test isempty(dry_source.reserved)
    @test isempty(dry_source.env_requests)
    release!(dry_scheduler, dry_assignment)

    dry_source = StaticJobSource([job(; id="dry-run-once-job")])
    dry_scheduler = test_scheduler(test_scheduler_config(), [runner_group(; cachedir_root=mktempdir())],
        dry_source, NullBackend(); dry_run=true)
    @test run_once!(dry_scheduler) == 1
    @test isempty(dry_source.reserved)
    @test isempty(dry_source.env_requests)
    @test isempty(dry_scheduler.claimed_jobs)
    @test isempty(dry_scheduler.claimed_slots)
end

mutable struct RecordingBackend <: PlatformBackend
    prepared::Vector{Tuple{String,String}}
end

struct RecordingHandle
    backend::RecordingBackend
end

function prepare(backend::RecordingBackend, slot::Slot, job::Job, plan::CachePlan)
    push!(backend.prepared, (slot.brg.name, job.id))
    return RecordingHandle(backend)
end

run_job(::RecordingHandle) = 0

@testset "scheduler backend registry" begin
    linux = runner_group(;
        name="linux",
        cachedir_root=mktempdir(),
        backend=BACKEND_LINUX_SANDBOX,
        host=:linux,
    )
    windows = BuildkiteRunnerGroup("windows", Dict{String,Any}(
        "queues" => "test",
        "backend" => BACKEND_KVM,
        "guest" => "windows",
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
        "num_cpus" => 8,
    ); host=:linux)
    linux_backend = RecordingBackend(Tuple{String,String}[])
    kvm_backend = RecordingBackend(Tuple{String,String}[])
    jobs = [
        job(; id="linux-job", agent_query_rules=["queue=build", "os=linux"]),
        job(; id="windows-job", agent_query_rules=["queue=test", "os=windows"]),
    ]
    scheduler = test_scheduler(
        test_scheduler_config(),
        [linux, windows],
        StaticJobSource(jobs),
        Dict(
            BACKEND_LINUX_SANDBOX => linux_backend,
            BACKEND_KVM => kvm_backend,
        ),
    )

    replace_pending_jobs!(scheduler, jobs)
    @test run_available_assignment!(scheduler, scheduler.slots[1])
    @test run_available_assignment!(scheduler, scheduler.slots[2])
    @test linux_backend.prepared == [("linux", "linux-job")]
    @test kvm_backend.prepared == [("windows", "windows-job")]
end

@testset "KVM backend planning" begin
    secrets = mktempdir()
    token_path = joinpath(secrets, "buildkite-agent-token")
    Base.write(token_path, "secret-token\n")
    chmod(token_path, 0o600)

    brg = BuildkiteRunnerGroup("freebsd13", Dict{String,Any}(
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "freebsd",
        "cachedir" => mktempdir(),
        "tempdir" => mktempdir(),
        "secrets_dir" => secrets,
        "num_cpus" => 4,
        "tags" => Dict{String,String}("os" => "freebsd", "arch" => "x86_64"),
    ); host=:linux)
    slot = Slot(brg, 2)
    plan = cache_plan(slot, job(; id="kvm-job"), :untrusted)
    backend = KVMBackend(mktempdir(), [brg])
    setup_backend!(backend, [slot])

    @test backend.groups == ["freebsd13"]
    @test backend.domain_prefixes == kvm_group_prefixes(["freebsd13"])
    @test only(backend.domain_prefixes) == string("freebsd13-", SandboxedBuildkiteAgent.get_short_hostname(), ".")
    @test virsh("list", "--name").exec == ["virsh", "-c", "qemu:///system", "list", "--name"]
    @test kvm_scratch_dir(slot) == joinpath(tempdir(brg), "kvm-agent-scratch", slot.name)
    @test kvm_os_overlay_path(slot) == joinpath(kvm_scratch_dir(slot), "$(slot.name).qcow2")
    @test kvm_xml_path(slot) == joinpath(kvm_scratch_dir(slot), "$(slot.name).xml")
    @test kvm_cache_overlay_path(plan) == joinpath(plan.cache_pool, "cache.qcow2-1")
    @test endswith(kvm_pristine_os_image(brg), joinpath("platforms", "freebsd-kvm", "buildkite-worker", "images", "worker.qcow2"))
    @test kvm_pristine_cache_image(brg) == string(kvm_pristine_os_image(brg), "-1")

    handle = KVMHandle(
        backend,
        slot,
        job(; id="kvm-job"),
        plan,
        slot.name,
        kvm_xml_path(slot),
        kvm_os_overlay_path(slot),
        kvm_cache_overlay_path(plan),
        joinpath(backend.logdir, slot.name, "kvm-job.log"),
    )
    vars = kvm_template_vars(handle)
    @test vars["agent_hostname"] == slot.name
    @test vars["num_cpus"] == "4"
    @test vars["memory_kb"] == string(4 * 4 * 1024 * 1024)
    @test vars["cache_disk_path"] == kvm_cache_overlay_path(plan)
    @test vars["log_path"] == handle.log_path

    payload = guest_exec_payload(handle)
    @test payload["execute"] == "guest-exec"
    @test payload["arguments"]["path"] == "/usr/local/bin/run-buildkite-job.sh"
    @test payload["arguments"]["arg"] == ["kvm-job"]
    @test "BUILDKITE_AGENT_TOKEN=secret-token" in payload["arguments"]["env"]
    @test "BUILDKITE_AGENT_NAME=$(slot.name)" in payload["arguments"]["env"]
    @test "BUILDKITE_PLUGIN_JULIA_ARCH=x86_64" in payload["arguments"]["env"]
    freebsd_tags_env = only(filter(env -> startswith(env, "BUILDKITE_AGENT_TAGS="),
        payload["arguments"]["env"]))
    freebsd_tags = Set(String.(split(freebsd_tags_env[length("BUILDKITE_AGENT_TAGS=")+1:end], ",")))
    @test "queue=build" in freebsd_tags
    @test "os=freebsd" in freebsd_tags
    @test "arch=x86_64" in freebsd_tags
    @test "cpuset_limited=true" in freebsd_tags
    @test "num_cpus=4" in freebsd_tags

    freebsd_template = read(kvm_xml_template(brg), String)
    @test length(collect(eachmatch(r"\$\{log_path\}", freebsd_template))) == 1
    @test occursin("<serial type='file'>", freebsd_template)
    @test occursin("<libosinfo:os id=\"http://freebsd.org/freebsd/13.4\"/>", freebsd_template)
    @test occursin("<model type='virtio'/>", freebsd_template)
    @test !occursin("<console type='file'>", freebsd_template)

    overlay_root = mktempdir()
    fakebin = joinpath(overlay_root, "bin")
    mkpath(fakebin)
    fake_qemu_img = joinpath(fakebin, "qemu-img")
    Base.write(fake_qemu_img, """
        #!/bin/sh
        printf '%s\\n' "\$*" >> "$(joinpath(overlay_root, "qemu-img.calls"))"
        for last do :; done
        : > "\$last"
        """)
    chmod(fake_qemu_img, 0o755)
    backing = joinpath(overlay_root, "backing.qcow2")
    overlay = joinpath(overlay_root, "cache.qcow2-1")
    Base.write(backing, "backing-v1")
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        @test ensure_kvm_cache_overlay(overlay, backing) == overlay
        stamp_path = kvm_cache_overlay_stamp_path(overlay)
        @test isfile(overlay)
        @test read(stamp_path, String) == kvm_backing_identity(backing)
        @test countlines(joinpath(overlay_root, "qemu-img.calls")) == 1
        @test ensure_kvm_cache_overlay(overlay, backing) == overlay
        @test countlines(joinpath(overlay_root, "qemu-img.calls")) == 1
        sleep(1.1)
        Base.write(backing, "backing-v2")
        @test ensure_kvm_cache_overlay(overlay, backing) == overlay
        @test read(stamp_path, String) == kvm_backing_identity(backing)
        @test countlines(joinpath(overlay_root, "qemu-img.calls")) == 2
    end

    windows_brg = BuildkiteRunnerGroup("windows", Dict{String,Any}(
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "windows",
        "cachedir" => mktempdir(),
        "tempdir" => mktempdir(),
        "secrets_dir" => secrets,
        "num_cpus" => 8,
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
    ); host=:linux)
    windows_slot = Slot(windows_brg, 1)
    windows_plan = cache_plan(windows_slot, job(; id="windows-job"), :trusted)
    windows_handle = KVMHandle(
        backend,
        windows_slot,
        job(; id="windows-job"),
        windows_plan,
        windows_slot.name,
        kvm_xml_path(windows_slot),
        kvm_os_overlay_path(windows_slot),
        kvm_cache_overlay_path(windows_plan),
        joinpath(backend.logdir, windows_slot.name, "windows-job.log"),
    )
    @test endswith(kvm_pristine_os_image(windows_brg), joinpath("platforms", "windows-kvm", "buildkite-worker", "images", "worker.qcow2"))
    @test kvm_xml_template(windows_brg) == SandboxedBuildkiteAgent.repo_path("platforms", "windows-kvm", "buildkite-worker", "kvm_machine.xml.template")
    @test guest_agent_ready_timeout(handle) == 30.0
    @test guest_agent_ready_timeout(windows_handle) == KVM_WINDOWS_AGENT_READY_TIMEOUT
    @test KVM_WINDOWS_AGENT_READY_TIMEOUT == 60.0
    @test guest_agent_stable_for(handle) == 0.0
    @test guest_agent_stable_for(windows_handle) == KVM_WINDOWS_AGENT_STABLE_FOR
    @test KVM_WINDOWS_AGENT_STABLE_FOR == 10.0
    windows_payload = guest_exec_payload(windows_handle)
    @test windows_payload["execute"] == "guest-exec"
    @test windows_payload["arguments"]["path"] == raw"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    @test windows_payload["arguments"]["arg"] == [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        raw"C:\buildkite-agent\run-buildkite-job.ps1",
        "windows-job",
    ]
    @test "BUILDKITE_AGENT_TOKEN=secret-token" in windows_payload["arguments"]["env"]
    @test "BUILDKITE_AGENT_NAME=$(windows_slot.name)" in windows_payload["arguments"]["env"]
    @test "BUILDKITE_PLUGIN_JULIA_ARCH=x86_64" in windows_payload["arguments"]["env"]
    windows_tags_env = only(filter(env -> startswith(env, "BUILDKITE_AGENT_TAGS="),
        windows_payload["arguments"]["env"]))
    windows_tags = Set(String.(split(windows_tags_env[length("BUILDKITE_AGENT_TAGS=")+1:end], ",")))
    @test "queue=build" in windows_tags
    @test "os=windows" in windows_tags
    @test "arch=x86_64" in windows_tags
    @test "cpuset_limited=true" in windows_tags
    @test "num_cpus=8" in windows_tags
    @test windows_payload["arguments"]["capture-output"] == false

    windows_template = read(kvm_xml_template(windows_brg), String)
    @test occursin("\${cache_disk_path}", windows_template)
    @test occursin("\${log_path}", windows_template)
    @test length(collect(eachmatch(r"\$\{log_path\}", windows_template))) == 1
    @test occursin("<serial type='file'>", windows_template)
    @test !occursin("<console type='file'>", windows_template)
    @test occursin("org.qemu.guest_agent.0", windows_template)

    windows_agent_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "windows-kvm", "buildkite-worker", "setup_scripts", "0-02-install-buildkite-agent.ps1"), String)
    # Keep this focused on the scheduler/guest-exec contract.  The PowerShell
    # control flow can change without affecting the host-side scheduler.
    @test occursin("run-buildkite-job.ps1", windows_agent_setup)
    @test occursin("disconnect-after-job=true", windows_agent_setup)
    @test occursin("--acquire-job", windows_agent_setup)
    @test occursin("--tags", windows_agent_setup)
    @test occursin("placeholder-token", windows_agent_setup)
    @test occursin("BUILDKITE_AGENT_TOKEN=\$env:BUILDKITE_AGENT_TOKEN", windows_agent_setup)
    @test occursin("BUILDKITE_AGENT_TAGS=\$env:BUILDKITE_AGENT_TAGS", windows_agent_setup)
    @test occursin("BUILDKITE_ACQUIRE_JOB_ID=\$JobId", windows_agent_setup)
    @test !occursin("buildkiteAgentQueues", windows_agent_setup)
    @test !occursin("Register-ScheduledTask", windows_agent_setup)
    @test !occursin("shutdown /s", windows_agent_setup)

    windows_packer = read(SandboxedBuildkiteAgent.repo_path("platforms", "windows-kvm", "buildkite-worker", "kvm_machine.pkr.hcl"), String)
    @test !occursin("buildkite_queues", windows_packer)
    @test !occursin("buildkite_tags", windows_packer)

    windows_qga_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "windows-kvm", "buildkite-worker", "setup_scripts", "0-07-configure-qemu-guest-agent.ps1"), String)
    @test occursin("guest-exec", windows_qga_setup)
    @test !occursin("--allow-rpcs", windows_qga_setup)

    freebsd_qga_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "setup_scripts", "install-qemu-guest-agent.sh"), String)
    @test occursin("--allow-rpcs=help", freebsd_qga_setup)
    @test all(rpc -> occursin(rpc, freebsd_qga_setup), ("guest-ping", "guest-exec", "guest-exec-status"))
    @test occursin("--block-rpcs=", freebsd_qga_setup)

    freebsd_agent_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "setup_scripts", "install-buildkite-agent.sh"), String)
    @test occursin("BUILDKITE_AGENT_TAGS must be set", freebsd_agent_setup)
    @test occursin("--tags '\\\${BUILDKITE_AGENT_TAGS}'", freebsd_agent_setup)
    @test !occursin("BUILDKITE_AGENT_QUEUES", freebsd_agent_setup)

    for script in ("format-data-disk.sh", "install-more-dependencies.sh", "set-hostname.sh")
        contents = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "setup_scripts", script), String)
        @test occursin("set -e", contents)
    end
    freebsd_format_disk = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "setup_scripts", "format-data-disk.sh"), String)
    @test occursin("zpool list cache", freebsd_format_disk)

    freebsd_packer = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "kvm_machine.pkr.hcl"), String)
    @test !occursin("buildkite_queues", freebsd_packer)
    @test !occursin("buildkite_tags", freebsd_packer)

    log_path = joinpath(mktempdir(), "kvm.log")
    @test prepare_kvm_log_file(log_path) == log_path
    @test isfile(log_path)
    @test stat(log_path).mode & 0o777 == 0o666
end

@testset "scheduler CLI arguments" begin
    dry_run, once = parse_scheduler_args(["--dry-run", "--once"])
    @test dry_run
    @test once
    @test_throws ErrorException parse_scheduler_args(["--config=config.toml"])
    @test parse_status_args(String[]) === nothing
    @test_throws ErrorException parse_status_args(["--verbose"])
    @test parse_stop_args(String[]) === nothing
    @test_throws ErrorException parse_stop_args(["--force"])
end

struct BlockingBackend <: PlatformBackend
    started::Channel{String}
    release::Channel{Nothing}
end

struct BlockingHandle
    backend::BlockingBackend
    job::Job
end

prepare(backend::BlockingBackend, slot::Slot, job::Job, plan::CachePlan) = BlockingHandle(backend, job)

function run_job(handle::BlockingHandle)
    put!(handle.backend.started, handle.job.id)
    take!(handle.backend.release)
    return 0
end

@testset "scheduler slot workers" begin
    backend = BlockingBackend(Channel{String}(2), Channel{Nothing}(2))
    source = StaticJobSource([job(; id="async-job")])
    scheduler = test_scheduler(
        test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir())],
        source,
        backend,
    )
    slot = only(scheduler.slots)

    with_logger(NullLogger()) do
        @test poll_jobs!(scheduler) == 1
        task = @async run_available_assignment!(scheduler, slot; block=true)
        @test take!(backend.started) == "async-job"
        @test "async-job" in scheduler.claimed_jobs

        source.jobs = [job(; id="second-job")]
        @test poll_jobs!(scheduler) == 1
        yield()
        @test !isready(backend.started)
        @test "second-job" ∉ scheduler.claimed_jobs

        put!(backend.release, nothing)
        @test timedwait(() -> istaskdone(task), 5.0) == :ok
        @test "async-job" ∉ scheduler.claimed_jobs

        @test poll_jobs!(scheduler) == 1
        task = @async run_available_assignment!(scheduler, slot)
        @test take!(backend.started) == "second-job"
        put!(backend.release, nothing)
        @test timedwait(() -> istaskdone(task), 5.0) == :ok
    end
end

@testset "scheduler startup cleanup" begin
    backend = CleanupBackend(0, 0)
    source = StaticJobSource(Job[])
    scheduler = test_scheduler(
        test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir(), num_agents=2)],
        source,
        backend,
    )

    start_scheduler!(scheduler)
    @test backend.count == 1
    @test backend.setup_slots == 2
    @test source.registered == 1
    @test source.deregistered == 0
    SandboxedBuildkiteAgent.cleanup_scheduler!(scheduler)
    @test backend.count == 2
    @test source.deregistered == 1

    dry_backend = CleanupBackend(0, 0)
    dry_source = StaticJobSource(Job[])
    dry_scheduler = test_scheduler(
        test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir())],
        dry_source,
        dry_backend;
        dry_run=true,
    )

    start_scheduler!(dry_scheduler)
    @test dry_backend.count == 0
    @test dry_backend.setup_slots == 0
    @test dry_source.registered == 0
    SandboxedBuildkiteAgent.cleanup_scheduler!(dry_scheduler)
    @test dry_backend.count == 0
    @test dry_source.deregistered == 0
end

@testset "Linux scheduler cgroups" begin
    brg = runner_group(; name="pinned", cachedir_root=mktempdir(), num_agents=2, num_cpus=1)
    slots = [Slot(brg, 1), Slot(brg, 2)]
    assignments = slot_cpu_assignments(slots)
    permutation = cpu_topology_permutation()
    @test assignments[slots[1].name] == condense_cpu_selection(permutation[1:1])
    @test assignments[slots[2].name] == condense_cpu_selection(permutation[2:2])
    @test isempty(slot_cpu_assignments([Slot(runner_group(; name="plain"), 1)]))

    slot = Slot(runner_group(; name="linux", cachedir_root=mktempdir()), 1)
    @test job_cgroup_name(slot, job(; id="abc/def")) == string("job-", slot.name, "-unknown-job")

    cgroup_file = tempname()
    Base.write(cgroup_file, "0::/system.slice/buildkite.service\n")
    @test scheduler_cgroup_root(; cgroup_file, cgroup_mount="/sys/fs/cgroup") ==
          "/sys/fs/cgroup/system.slice/buildkite.service"

    wrapped = wrap_command_in_cgroup_join_file("/sys/fs/cgroup/test/cgroup.procs", `echo ok`)
    @test wrapped.exec[1] == joinpath(dirname(@__DIR__), "src", "backends", "assets", "host_cgroup_wrapper.sh")
    @test wrapped.exec[2] == "/sys/fs/cgroup/test/cgroup.procs"

    backend = LinuxSandboxBackend(mktempdir())
    backend.root = "/not/a/real/cgroup"
    cleanup(backend)
    @test backend.root == "/not/a/real/cgroup"
end

@testset "Linux scheduler systemd service" begin
    unit_path = tempname()
    @test !scheduler_systemd_service_installed(; unit_path)
    Base.write(unit_path, "unit")
    @test scheduler_systemd_service_installed(; unit_path)

    config = SystemdConfig(;
        exec_start=SystemdTarget("/bin/true"),
        delegate="cpuset",
    )
    io = IOBuffer()
    Base.write(io, config)
    @test occursin("Delegate=cpuset", String(take!(io)))

    config_path = tempname()
    Base.write(config_path, """
    [scheduler]

    [builder]
    backend = "linux-sandbox"
    queues = "build"

    [builder.tags]
    os = "linux"
    arch = "x86_64"
    sandbox_capable = "true"
    """)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, config_path; dry_run=true, host=:linux)
    unit = String(take!(io))
    @test occursin("Delegate=cpuset", unit)
    @test occursin("bin/bk --config=$(abspath(config_path)) scheduler", unit)
    @test !occursin("--backend", unit)
    @test occursin("--dry-run", unit)
    @test occursin("Restart=on-failure", unit)
    @test !occursin("Restart=always", unit)
    @test occursin("After=network-online.target", unit)
    @test occursin("Wants=network-online.target", unit)
    @test occursin("RuntimeDirectory=sandboxed-buildkite-agent", unit)

    kvm_config_path = tempname()
    Base.write(kvm_config_path, """
    [scheduler]

    [windows]
    backend = "kvm"
    guest = "windows"
    queues = "build"
    num_cpus = 8

    [windows.tags]
    os = "windows"
    arch = "x86_64"
    """)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, kvm_config_path; host=:linux)
    unit = String(take!(io))
    @test !occursin("Delegate=cpuset", unit)
    @test occursin("virsh -c qemu:///system list --name", unit)
end

@testset "macOS scheduler launchd service" begin
    plist_path = tempname()
    @test !scheduler_launchctl_service_installed(; plist_path)
    Base.write(plist_path, "plist")
    @test scheduler_launchctl_service_installed(; plist_path)

    config_path = tempname()
    logdir = mktempdir()
    Base.write(config_path, """
    [scheduler]
    logdir = "$(logdir)"

    [builder]
    queues = "build"
    num_agents = 2
    tempdir = "$(mktempdir())"

    [builder.tags]
    os = "macos"
    arch = "aarch64"
    """)

    scheduler_config = read_scheduler_config(config_path)
    @test scheduler_config.poll_interval == 15.0
    @test scheduler_config.reservation_expiry_seconds == 300

    io = IOBuffer()
    generate_scheduler_launchctl_script(io, config_path; dry_run=true, host=:macos)
    plist = String(take!(io))
    @test occursin("org.julialang.buildkite.scheduler.", plist)
    @test occursin("bin/bk", plist)
    @test !occursin("--backend", plist)
    @test occursin("--config=$(abspath(config_path))", plist)
    @test first(findfirst("--config=$(abspath(config_path))", plist)) <
          first(findfirst(">scheduler<", plist))
    @test occursin("--dry-run", plist)
    @test occursin("<string>$(logdir)/scheduler.log</string>", plist)

    token_path = joinpath(mktempdir(), "buildkite-agent-token")
    Base.write(token_path, "secret-token\n")
    seatbelt_env = build_seatbelt_env(mktempdir(), mktempdir();
        agent_token_path=token_path,
        julia_arch="aarch64")
    @test seatbelt_env["BUILDKITE_AGENT_TOKEN"] == "secret-token"
    @test seatbelt_env["BUILDKITE_PLUGIN_JULIA_ARCH"] == "aarch64"
end
