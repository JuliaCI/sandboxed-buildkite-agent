using Test, Logging, JSON, Downloads, Sandbox
using SandboxedBuildkiteAgent
import SandboxedBuildkiteAgent:
    BACKEND_KVM,
    BACKEND_LINUX_SANDBOX,
    BACKEND_MACOS_SEATBELT,
    Allocation,
    AdmissionGroup,
    BuildkiteHTTPError,
    BuildkiteRateLimited,
    BuildkiteRunnerGroup,
    CachePlan,
    CpuPool,
    Job,
    JobSource,
    KVMBackend,
    KVMHandle,
    LeasePool,
    LinuxSandboxBackend,
    PlatformBackend,
    Scheduler,
    SchedulerConfig,
    Slot,
    StacksJobSource,
    cache_plan,
    check_backend_configs,
    cleanup,
    condense_cpu_selection,
    cpu_topology_permutation,
    free_cpus,
    allocate!,
    admission_plan,
    encode_query,
    ensure_kvm_cache_overlay,
    escape_uri,
    generate_scheduler_launchctl_script,
    generate_scheduler_systemd_script,
    get_job_env,
    build_seatbelt_env,
    finish_job_payload,
    finish_job_path,
    guest_agent_ready_timeout,
    guest_agent_stable_for,
    handle_poll_error!,
    cleanup_job_cgroups,
    guest_exec_payload,
    job_cgroup_name,
    kill_cgroup,
    kvm_guest,
    kvm_backing_identity,
    kvm_cache_overlay_path,
    kvm_cache_overlay_stamp_path,
    kvm_group_prefixes,
    kvm_os_overlay_path,
    kvm_pristine_cache_image,
    kvm_pristine_os_image,
    kvm_serial_log_path,
    kvm_template_vars,
    kvm_xml_template,
    kvm_xml_path,
    launch_scheduler_task,
    latest_slot_log_path,
    lease!,
    mine,
    parse_logs_args,
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
    representative_slot,
    read_scheduler_config,
    release!,
    replace_pending_jobs!,
    ReservationResult,
    reserve_jobs,
    run_available_assignment!,
    run_job,
    running,
    scheduler_cgroup_root,
    scheduler_error_sleep,
    scheduler_launchctl_service_installed,
    launchctl_status_from_output,
    scheduler_status_path,
    read_scheduler_status_snapshot,
    scheduler_systemd_service_installed,
    systemd_status_from_properties,
    scheduled_job_from_json,
    setup_backend!,
    setup_backend_configs!,
    slot_log_files,
    slot_log_path,
    stack_key_override,
    stacks_request,
    start_scheduler!,
    take_assignment!,
    trust_from_env,
    wrap_command_in_cgroup_join_file

function runner_group(; name="tester", cachedir_root=mktempdir(), sharedcache_root=nothing,
                      max_jobs=1, job_cpus=1, priority=10, backend=nothing,
                      host=Sys.islinux() ? :linux : :macos)
    config = Dict{String,Any}(
        "queues" => "build",
        "max_jobs" => max_jobs,
        "job_cpus" => job_cpus,
        "priority" => priority,
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
        "assignment_timeout_seconds" => 42,
        "total_cpus" => 1,
    )
    parsed = SchedulerConfig(config; config_dir="/tmp")
    @test parsed.logdir == "/tmp/logs"
    @test parsed.poll_interval == 15.0
    @test parsed.error_sleep == 10.0
    @test parsed.reservation_expiry_seconds == 120
    @test parsed.assignment_timeout_seconds == 42.0
    @test parsed.total_cpus == 1
    @test SchedulerConfig(Dict{String,Any}()).assignment_timeout_seconds == 6 * 60 * 60.0
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
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "assignment_timeout_seconds" => 0,
    ))
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "total_cpus" => 0,
    ))
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "total_cpus" => Sys.CPU_THREADS + 1,
    ))
end

@testset "scheduler rate-limit backoff" begin
    config = SchedulerConfig(mktempdir(), 0.01, 5.0, 900)
    @test scheduler_error_sleep(config, ErrorException("boom")) == 5.0
    @test scheduler_error_sleep(config, BuildkiteRateLimited(1.0)) == 5.0
    @test scheduler_error_sleep(config, BuildkiteRateLimited(30.0)) == 30.0
end

@testset "resource pools" begin
    pool = CpuPool(4, [0, 1, 2, 3])
    first = allocate!(pool, 2)
    @test first == Allocation(2, "0-1")
    second = allocate!(pool, 1)
    @test second == Allocation(1, "2")
    @test free_cpus(pool) == 1
    release!(pool, first)
    fragmented = allocate!(pool, 3)
    @test fragmented == Allocation(3, "0-1,3")
    @test allocate!(pool, 1) === nothing
    @test length(pool.allocated) == 4
    release!(pool, second)
    release!(pool, fragmented)
    @test free_cpus(pool) == 4
    @test allocate!(CpuPool(2, [8, 10, 12]), 2) == Allocation(2, "8,10")
    @test CpuPool(2, [4, 5, 6]).order == [4, 5]

    brg = runner_group(; name="leased", max_jobs=2)
    leases = LeasePool(brg)
    a = lease!(leases)
    b = lease!(leases)
    @test a.name == "$(brg.name)-$(SandboxedBuildkiteAgent.get_short_hostname()).1"
    @test b.name == "$(brg.name)-$(SandboxedBuildkiteAgent.get_short_hostname()).2"
    @test lease!(leases) === nothing
    @test running(leases) == 2
    release!(leases, a)
    @test lease!(leases).name == a.name
    @test representative_slot(leases).name == a.name
end

@testset "admission policy" begin
    build = runner_group(; name="builder", job_cpus=4, max_jobs=1, priority=1)
    test = BuildkiteRunnerGroup("tester-priority", Dict{String,Any}(
        "queues" => "test",
        "job_cpus" => 2,
        "max_jobs" => 2,
        "priority" => 2,
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64"),
    ); host=:linux)
    launch = BuildkiteRunnerGroup("launcher", Dict{String,Any}(
        "queues" => "launch",
        "job_cpus" => 0,
        "max_jobs" => 2,
        "priority" => 3,
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64"),
    ); host=:linux)

    build_job = job(; id="build", agent_query_rules=["queue=build", "os=linux"])
    test_job = job(; id="test", agent_query_rules=["queue=test", "os=linux"])
    launch_job = job(; id="launch", agent_query_rules=["queue=launch", "os=linux"])
    groups = [
        AdmissionGroup(build.name, build.priority, build.job_cpus, build.max_jobs, 0, [build_job], Slot(build, 1)),
        AdmissionGroup(test.name, test.priority, test.job_cpus, test.max_jobs, 0, [test_job], Slot(test, 1)),
        AdmissionGroup(launch.name, launch.priority, launch.job_cpus, launch.max_jobs, 0, [launch_job], Slot(launch, 1)),
    ]
    blocked = admission_plan(groups, 2)
    @test [a.job.id for a in blocked.admissions] == ["launch"]
    @test blocked.blocked[build.name]
    @test blocked.blocked[test.name]
    @test !blocked.blocked[launch.name]

    fifo = admission_plan([
        AdmissionGroup(test.name, test.priority, test.job_cpus, test.max_jobs, 0,
            [job(; id="a", agent_query_rules=["queue=test", "os=linux"]),
             job(; id="b", agent_query_rules=["queue=test", "os=linux"])],
            Slot(test, 1)),
    ], 4)
    @test [a.job.id for a in fifo.admissions] == ["a", "b"]

    capped = admission_plan([
        AdmissionGroup(test.name, test.priority, test.job_cpus, 1, 1, [test_job], Slot(test, 1)),
    ], 4)
    @test isempty(capped.admissions)

    skipped = admission_plan([
        AdmissionGroup(test.name, test.priority, test.job_cpus, 1, 0,
            [job(; id="claimed", agent_query_rules=["queue=test", "os=linux"]),
             job(; id="quarantined", agent_query_rules=["queue=test", "os=linux"]),
             job(; id="wrong-os", agent_query_rules=["queue=test", "os=macos"]),
             job(; id="eligible", agent_query_rules=["queue=test", "os=linux"])],
            Slot(test, 1)),
    ], 2, Set(["claimed"]), Dict("quarantined" => time() + 60))
    @test only(skipped.admissions).job.id == "eligible"

    unblocked = admission_plan([
        AdmissionGroup(build.name, build.priority, build.job_cpus, build.max_jobs, 0, Job[], Slot(build, 1)),
        AdmissionGroup(test.name, test.priority, test.job_cpus, test.max_jobs, 0, [test_job], Slot(test, 1)),
    ], 2)
    @test [a.job.id for a in unblocked.admissions] == ["test"]
    @test !unblocked.blocked[test.name]
end

@testset "runner group backend config" begin
    linux_group = BuildkiteRunnerGroup("linux", Dict{String,Any}(
        "queues" => "build",
        "job_cpus" => 1,
    ); host=:linux)
    @test linux_group.backend == BACKEND_LINUX_SANDBOX

    mac_group = BuildkiteRunnerGroup("mac", Dict{String,Any}(
        "queues" => "build",
        "job_cpus" => 1,
    ); host=:macos)
    @test mac_group.backend == BACKEND_MACOS_SEATBELT

    kvm_group = BuildkiteRunnerGroup("windows", Dict{String,Any}(
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "windows",
        "job_cpus" => 2,
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
    ); host=:linux)
    @test kvm_group.backend == BACKEND_KVM
    @test kvm_guest(kvm_group) == "windows"
    @test kvm_group.tags["os"] == "windows"

    freebsd_group = BuildkiteRunnerGroup("freebsd", Dict{String,Any}(
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "freebsd",
        "job_cpus" => 2,
        "tags" => Dict{String,String}("arch" => "x86_64"),
    ); host=:linux)
    @test freebsd_group.tags["os"] == "freebsd"

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => BACKEND_KVM,
        "job_cpus" => 1,
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => BACKEND_LINUX_SANDBOX,
        "guest" => "freebsd",
        "job_cpus" => 1,
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => "wat",
        "job_cpus" => 1,
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => BACKEND_MACOS_SEATBELT,
        "job_cpus" => 1,
    ); host=:linux)

    stack_group = BuildkiteRunnerGroup("stack", Dict{String,Any}(
        "queues" => "build",
        "job_cpus" => 1,
        "stack_key" => "julia_stack_1",
    ); host=:linux)
    @test stack_key_override(stack_group) == "julia_stack_1"
    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "stack_key" => "not ok",
        "job_cpus" => 1,
    ); host=:linux)

    @test_logs (:warn, "Ignoring unknown runner group config key(s)") BuildkiteRunnerGroup(
        "typo",
        Dict{String,Any}("queues" => "build", "job_cpus" => 1, "num_agent" => 2);
        host=:linux,
    )
    @test_throws ArgumentError BuildkiteRunnerGroup("old", Dict{String,Any}(
        "queues" => "build",
        "num_agents" => 2,
        "job_cpus" => 1,
    ); host=:linux)
    @test_throws ArgumentError BuildkiteRunnerGroup("old", Dict{String,Any}(
        "queues" => "build",
        "num_cpus" => 2,
        "job_cpus" => 1,
    ); host=:linux)
    @test_throws ArgumentError BuildkiteRunnerGroup("zero", Dict{String,Any}(
        "queues" => "build",
        "job_cpus" => 0,
    ); host=:linux)
    zero = BuildkiteRunnerGroup("zero", Dict{String,Any}(
        "queues" => "launch",
        "job_cpus" => 0,
        "max_jobs" => 2,
    ); host=:linux)
    @test zero.max_jobs == 2
    defaulted = BuildkiteRunnerGroup("defaulted", Dict{String,Any}(
        "queues" => "build",
        "job_cpus" => 2,
    ); host=:linux, total_cpus=6)
    @test defaulted.max_jobs == 3
    @test defaulted.priority == 10
end

mutable struct StaticJobSource <: JobSource
    jobs::Vector{Job}
    envs::Dict{String,Dict{String,String}}
    reserved::Set{String}
    unavailable::Set{String}
    env_failures::Set{String}
    env_requests::Vector{String}
    finished::Vector{Tuple{String,Int,String}}
    finish_failures::Set{String}
    registered::Int
    deregistered::Int
end
StaticJobSource(jobs::Vector{Job}) =
    StaticJobSource(jobs, Dict{String,Dict{String,String}}(), Set{String}(),
        Set{String}(), Set{String}(), String[], Tuple{String,Int,String}[],
        Set{String}(), 0, 0)
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
function SandboxedBuildkiteAgent.finish_job(source::StaticJobSource, job_id::AbstractString;
                                            exit_status::Integer=1,
                                            detail::AbstractString="")
    job_id = string(job_id)
    job_id in source.finish_failures && error("finish unavailable")
    push!(source.finished, (job_id, Int(exit_status), String(detail)))
    delete!(source.reserved, job_id)
    filter!(job -> job.id != job_id, source.jobs)
    return true
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

mutable struct ConfigBackend <: PlatformBackend
    checked::Vector{String}
    setup::Vector{String}
end
ConfigBackend() = ConfigBackend(String[], String[])

function SandboxedBuildkiteAgent.check_config(backend::ConfigBackend,
                                              brgs::Vector{BuildkiteRunnerGroup})
    append!(backend.checked, [brg.name for brg in brgs])
    return nothing
end

function SandboxedBuildkiteAgent.setup_config!(backend::ConfigBackend,
                                               brgs::Vector{BuildkiteRunnerGroup})
    append!(backend.setup, [brg.name for brg in brgs])
    return nothing
end

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

@testset "backend config setup is separate from runtime checks" begin
    brg = runner_group(; name="linux", backend=BACKEND_LINUX_SANDBOX, host=:linux)
    backend = ConfigBackend()
    backends = Dict(BACKEND_LINUX_SANDBOX => backend)

    @test check_backend_configs(backends, [brg]) === nothing
    @test backend.checked == ["linux"]
    @test isempty(backend.setup)

    @test setup_backend_configs!(backends, [brg]) === nothing
    @test backend.checked == ["linux"]
    @test backend.setup == ["linux"]
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

    # A revoked/invalid token (403) is fatal: it propagates so the supervisor
    # stops the unit rather than parking and retrying forever.
    source403 = RecoveringHTTPErrorSource(403, 0)
    scheduler403 = test_scheduler(test_scheduler_config(), [brg],
        Dict(brg.name => source403), NullBackend())
    sleeps = Float64[]
    with_logger(NullLogger()) do
        @test_throws BuildkiteHTTPError handle_poll_error!(scheduler403, brg.name,
            BuildkiteHTTPError(403, "bad token"), Any[];
            sleep_fn=seconds -> push!(sleeps, seconds))
    end
    @test source403.registered == 0
    @test isempty(sleeps)

    # A server-side 5xx is transient: back off in-process and keep polling.
    source503 = RecoveringHTTPErrorSource(503, 0)
    scheduler503 = test_scheduler(test_scheduler_config(), [brg],
        Dict(brg.name => source503), NullBackend())
    sleeps = Float64[]
    with_logger(NullLogger()) do
        handle_poll_error!(scheduler503, brg.name,
            BuildkiteHTTPError(503, "service unavailable"), Any[];
            sleep_fn=seconds -> push!(sleeps, seconds))
    end
    @test source503.registered == 0
    @test sleeps == [scheduler503.config.error_sleep]
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
        "job_cpus" => 1,
        "secrets_dir" => secrets,
        "stack_key" => "julia-test-stack",
    ); host=:linux)
    source = StacksJobSource(test_scheduler_config(), brg; endpoint="https://example.invalid")
    @test source.stack_key == "julia-test-stack"
    @test source.queue_key == "build"
    @test source.token_path == token_path
    @test finish_job_path(source, "job.1/test") ==
          "/stacks/julia-test-stack/jobs/job%2E1%2Ftest/finish"
    finish_payload = finish_job_payload(1, repeat("x", 5000))
    @test finish_payload["exit_status"] == 1
    @test ncodeunits(finish_payload["detail"]) <= 4 * 1024
    @test occursin("detail truncated", finish_payload["detail"])

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
        "job_cpus" => 1,
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
        "job_cpus" => 1,
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64"),
    ))
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

    assignments = filter(!isnothing, [take_assignment!(scheduler) for _ in 1:2])
    @test [a.job.id for a in assignments] == ["build-job", "test-job"]
    @test assignments[1].slot.name == Slot(build, 1).name
    @test assignments[2].slot.name == Slot(test, 1).name
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
    assignment = take_assignment!(scheduler)
    @test assignment.job.id == "build-job"
    replace_pending_jobs!(scheduler, build.name, poll_jobs(build_source))
    @test all(job.id != "build-job" for job in scheduler.pending_jobs[build.name])
    release!(scheduler, assignment)
    build_source = StaticJobSource(build_jobs)
    scheduler = test_scheduler(test_scheduler_config(), [build, test],
        Dict(build.name => build_source, test.name => StaticJobSource(test_jobs)), NullBackend())
    replace_pending_jobs!(scheduler, build.name, poll_jobs(build_source))
    @test any(job.id == "build-job" for job in scheduler.pending_jobs[build.name])

    two_slot_group = runner_group(; cachedir_root=mktempdir(), max_jobs=2)
    source = StaticJobSource([job(; id="single-job")])
    scheduler = test_scheduler(test_scheduler_config(), [two_slot_group],
        source, NullBackend())
    replace_pending_jobs!(scheduler, poll_jobs(source))
    first = take_assignment!(scheduler)
    second = take_assignment!(scheduler)
    @test first.job.id == "single-job"
    @test second === nothing

    duplicate_jobs = [job(; id="duplicate-job"), job(; id="duplicate-job")]
    source = StaticJobSource(duplicate_jobs)
    scheduler = test_scheduler(test_scheduler_config(), [two_slot_group],
        source, NullBackend())
    replace_pending_jobs!(scheduler, poll_jobs(source))
    first = take_assignment!(scheduler)
    second = take_assignment!(scheduler)
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
    assignment = take_assignment!(scheduler)
    @test assignment.job.id == "next-job"
    @test "already-reserved" ∉ scheduler.claimed_jobs

    env_failure_source = StaticJobSource([job(; id="env-failure")])
    push!(env_failure_source.env_failures, "env-failure")
    scheduler = test_scheduler(test_scheduler_config(), [runner_group(; cachedir_root=mktempdir())],
        env_failure_source, NullBackend())
    replace_pending_jobs!(scheduler, poll_jobs(env_failure_source))
    assignment = with_logger(NullLogger()) do
        take_assignment!(scheduler)
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
    dry_assignment = take_assignment!(dry_scheduler)
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
    @test all(running(pool) == 0 for pool in values(dry_scheduler.lease_pools))

    no_backfill_config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 2)
    build = runner_group(; name="wide-build", cachedir_root=mktempdir(),
        job_cpus=2, max_jobs=2, priority=1, host=:linux)
    test = BuildkiteRunnerGroup("narrow-test", Dict{String,Any}(
        "queues" => "test",
        "job_cpus" => 1,
        "max_jobs" => 1,
        "priority" => 2,
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64"),
    ); host=:linux)
    build_source = StaticJobSource([job(; id="build-1", agent_query_rules=["queue=build", "os=linux"])])
    test_source = StaticJobSource(Job[])
    scheduler = test_scheduler(no_backfill_config, [build, test],
        Dict(build.name => build_source, test.name => test_source), NullBackend())
    @test poll_jobs!(scheduler, build.name) == 1
    running_build = take_assignment!(scheduler)
    @test running_build.job.id == "build-1"

    build_source.jobs = [job(; id="build-2", agent_query_rules=["queue=build", "os=linux"])]
    test_source.jobs = [job(; id="test-1", agent_query_rules=["queue=test", "os=linux"])]
    @test poll_jobs!(scheduler, build.name) == 1
    @test poll_jobs!(scheduler, test.name) == 1
    @test take_assignment!(scheduler) === nothing
    release!(scheduler, running_build)
    next_build = take_assignment!(scheduler)
    @test next_build.job.id == "build-2"
    release!(scheduler, next_build)
end

@testset "scheduler status snapshots" begin
    config = test_scheduler_config()
    brg = runner_group(; cachedir_root=mktempdir())
    source = StaticJobSource([job(; id="status-job")])
    scheduler = test_scheduler(config, [brg], source, NullBackend())

    @test SandboxedBuildkiteAgent.write_scheduler_status!(scheduler) == scheduler_status_path(config)
    snapshot = read_scheduler_status_snapshot(config)
    @test snapshot["version"] == 2
    @test snapshot["logdir"] == config.logdir
    @test isempty(snapshot["slots"])
    @test snapshot["pool"]["total_cpus"] == config.total_cpus
    @test snapshot["pool"]["free_cpus"] == config.total_cpus
    @test !isempty(snapshot["disks"])

    # State transitions only mutate in-memory status; the heartbeat task is the
    # sole writer, so flush explicitly before each read.
    @test poll_jobs!(scheduler) == 1
    SandboxedBuildkiteAgent.write_scheduler_status!(scheduler)
    snapshot = read_scheduler_status_snapshot(config)
    poller = only(snapshot["pollers"])
    @test poller["runner_group"] == brg.name
    @test poller["pending_jobs"] == 1
    @test poller["last_success_at"] !== nothing

    assignment = take_assignment!(scheduler)
    SandboxedBuildkiteAgent.write_scheduler_status!(scheduler)
    snapshot = read_scheduler_status_snapshot(config)
    slot_status = only(snapshot["slots"])
    @test slot_status["state"] == "assigned"
    @test slot_status["job"]["id"] == "status-job"
    @test slot_status["trust"] == "trusted"

    release!(scheduler, assignment)
    SandboxedBuildkiteAgent.write_scheduler_status!(scheduler)
    snapshot = read_scheduler_status_snapshot(config)
    @test isempty(snapshot["slots"])
    @test snapshot["pool"]["free_cpus"] == config.total_cpus
end

mutable struct RecordingBackend <: PlatformBackend
    prepared::Vector{Tuple{String,String}}
end

struct RecordingHandle
    backend::RecordingBackend
end

function prepare(backend::RecordingBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    push!(backend.prepared, (slot.brg.name, job.id))
    return RecordingHandle(backend)
end

run_job(::RecordingHandle, ::Union{Nothing,Float64}=nothing) = 0

mutable struct DeadlineBackend <: PlatformBackend
    deadlines::Vector{Float64}
end

struct DeadlineHandle
    backend::DeadlineBackend
end

prepare(backend::DeadlineBackend, slot::Slot, job::Job, plan::CachePlan,
        alloc::Allocation) =
    DeadlineHandle(backend)

function run_job(handle::DeadlineHandle, deadline::Union{Nothing,Float64})
    deadline === nothing || push!(handle.backend.deadlines, deadline)
    return 0
end

struct FailingPrepareBackend <: PlatformBackend end

function prepare(::FailingPrepareBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    error("prepare failed")
end

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
        "job_cpus" => 2,
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
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
    @test run_available_assignment!(scheduler)
    @test run_available_assignment!(scheduler)
    @test linux_backend.prepared == [("linux", "linux-job")]
    @test kvm_backend.prepared == [("windows", "windows-job")]

    deadline_backend = DeadlineBackend(Float64[])
    deadline_config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0)
    deadline_scheduler = test_scheduler(deadline_config, [linux],
        StaticJobSource([job(; id="deadline-job", agent_query_rules=["queue=build", "os=linux"])]),
        Dict(BACKEND_LINUX_SANDBOX => deadline_backend))
    before = time()
    @test run_once!(deadline_scheduler) == 1
    @test length(deadline_backend.deadlines) == 1
    @test 55.0 <= only(deadline_backend.deadlines) - before <= 65.0
end

@testset "scheduler finishes failed reserved jobs" begin
    brg = runner_group(; cachedir_root=mktempdir())
    source = StaticJobSource([job(; id="prepare-failure")])
    scheduler = test_scheduler(test_scheduler_config(), [brg], source, FailingPrepareBackend())
    replace_pending_jobs!(scheduler, poll_jobs(source))

    with_logger(NullLogger()) do
        @test run_available_assignment!(scheduler)
    end
    @test isempty(scheduler.claimed_jobs)
    @test all(running(pool) == 0 for pool in values(scheduler.lease_pools))
    @test length(source.finished) == 1
    finished_job, exit_status, detail = only(source.finished)
    @test finished_job == "prepare-failure"
    @test exit_status == 1
    @test occursin("prepare failed", detail)
    @test isempty(source.jobs)
    @test isempty(source.reserved)

    retry_source = StaticJobSource([job(; id="finish-failure")])
    push!(retry_source.finish_failures, "finish-failure")
    retry_scheduler = test_scheduler(test_scheduler_config(), [brg], retry_source, FailingPrepareBackend())
    replace_pending_jobs!(retry_scheduler, poll_jobs(retry_source))
    with_logger(NullLogger()) do
        @test run_available_assignment!(retry_scheduler)
    end
    @test isempty(retry_scheduler.claimed_jobs)
    @test all(running(pool) == 0 for pool in values(retry_scheduler.lease_pools))
    @test haskey(retry_scheduler.quarantined_jobs, "finish-failure")

    empty!(retry_source.reserved)
    replace_pending_jobs!(retry_scheduler, poll_jobs(retry_source))
    @test isempty(retry_scheduler.pending_jobs[brg.name])

    retry_scheduler.quarantined_jobs["finish-failure"] = time() - 1
    replace_pending_jobs!(retry_scheduler, poll_jobs(retry_source))
    assignment = take_assignment!(retry_scheduler)
    @test assignment.job.id == "finish-failure"
    release!(retry_scheduler, assignment)
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
        "job_cpus" => 4,
        "tags" => Dict{String,String}("os" => "freebsd", "arch" => "x86_64"),
    ); host=:linux)
    slot = Slot(brg, 2)
    plan = cache_plan(slot, job(; id="kvm-job"), :untrusted)
    backend = KVMBackend(mktempdir(), [brg])
    alloc = Allocation(4, "0-3")

    # The orphan sweep matches domains by hostname-qualified prefix and by the
    # cache overlay basename inside the scheduler's roots.
    @test backend.groups == ["freebsd13"]
    @test only(backend.domain_prefixes) == string("freebsd13-", SandboxedBuildkiteAgent.get_short_hostname(), ".")
    @test backend.scratch_roots == [joinpath(tempdir(brg), "kvm-agent-scratch")]
    @test backend.cache_roots == [SandboxedBuildkiteAgent.cachedir(brg)]
    @test basename(kvm_cache_overlay_path(plan)) == "cache.qcow2-1"
    # The Makefiles produce worker.qcow2 (+ the "-1" cache disk) under
    # platforms/<guest>-kvm/buildkite-worker/images/.
    @test endswith(kvm_pristine_os_image(brg), joinpath("platforms", "freebsd-kvm", "buildkite-worker", "images", "worker.qcow2"))
    @test kvm_pristine_cache_image(brg) == string(kvm_pristine_os_image(brg), "-1")

    handle = KVMHandle(
        backend,
        slot,
        job(; id="kvm-job"),
        plan,
        alloc,
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
    # The serial console log must be a separate file next to the job log,
    # where `bk logs --serial` looks for it.
    @test vars["log_path"] == kvm_serial_log_path(handle.log_path)
    @test vars["log_path"] != handle.log_path
    @test endswith(vars["log_path"], ".serial.log")

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
    @test !any(startswith(tag, "num_cpus=") for tag in freebsd_tags)

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
        "job_cpus" => 4,
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
    ); host=:linux)
    windows_slot = Slot(windows_brg, 1)
    windows_plan = cache_plan(windows_slot, job(; id="windows-job"), :trusted)
    windows_handle = KVMHandle(
        backend,
        windows_slot,
        job(; id="windows-job"),
        windows_plan,
        Allocation(4, "0-3"),
        windows_slot.name,
        kvm_xml_path(windows_slot),
        kvm_os_overlay_path(windows_slot),
        kvm_cache_overlay_path(windows_plan),
        joinpath(backend.logdir, windows_slot.name, "windows-job.log"),
    )
    @test endswith(kvm_pristine_os_image(windows_brg), joinpath("platforms", "windows-kvm", "buildkite-worker", "images", "worker.qcow2"))
    # Windows guests boot slower and need a stability window before guest-exec.
    @test guest_agent_ready_timeout(windows_handle) > guest_agent_ready_timeout(handle)
    @test guest_agent_stable_for(windows_handle) > guest_agent_stable_for(handle)
    windows_payload = guest_exec_payload(windows_handle)
    @test windows_payload["execute"] == "guest-exec"
    @test windows_payload["arguments"]["path"] == raw"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    @test raw"C:\buildkite-agent\run-buildkite-job.ps1" in windows_payload["arguments"]["arg"]
    @test last(windows_payload["arguments"]["arg"]) == "windows-job"
    @test windows_payload["arguments"]["capture-output"] == false

    # Every placeholder in the XML templates must be provided by the scheduler.
    for (template_brg, template_vars) in ((brg, vars), (windows_brg, kvm_template_vars(windows_handle)))
        template = read(kvm_xml_template(template_brg), String)
        for m in eachmatch(r"\$\{(\w+)\}", template)
            @test haskey(template_vars, m.captures[1])
        end
        # The serial console goes to the per-job file `bk logs --serial` reads,
        # and the guest agent channel guest-exec relies on is present.
        @test occursin("<serial type='file'>", template)
        @test occursin("org.qemu.guest_agent.0", template)
    end

    fake_virsh_root = mktempdir()
    fakebin = joinpath(fake_virsh_root, "bin")
    mkpath(fakebin)
    fake_virsh = joinpath(fakebin, "virsh")
    destroyed_path = joinpath(fake_virsh_root, "destroyed")
    list_count_path = joinpath(fake_virsh_root, "list.count")
    current_domain = string(only(kvm_group_prefixes([brg.name])), "1")
    renamed_domain = "renamed-runner-oldhost.1"
    foreign_domain = "foreign-domain"
    renamed_disk = joinpath(tempdir(brg), "kvm-agent-scratch", "renamed", "renamed.qcow2")
    foreign_disk = joinpath(mktempdir(), "foreign.qcow2")
    Base.write(fake_virsh, """
        #!/bin/sh
        cmd="\$3"
        if [ "\$cmd" = "list" ]; then
            count=\$(cat "$(list_count_path)" 2>/dev/null || printf 0)
            count=\$((count + 1))
            printf '%s' "\$count" > "$(list_count_path)"
            if [ "\$count" -eq 1 ]; then
                printf '%s\\n' "$(current_domain)" "$(renamed_domain)" "$(foreign_domain)"
            else
                printf '%s\\n' "$(foreign_domain)"
            fi
        elif [ "\$cmd" = "domblklist" ]; then
            domain="\$4"
            printf '%s\\n' "Type Device Target Source"
            printf '%s\\n' "--------------------------------"
            case "\$domain" in
                "$(renamed_domain)") printf '%s\\n' "file disk vda $(renamed_disk)" ;;
                "$(foreign_domain)") printf '%s\\n' "file disk vda $(foreign_disk)" ;;
                *) printf '%s\\n' "file disk vda -" ;;
            esac
        elif [ "\$cmd" = "destroy" ]; then
            printf '%s\\n' "\$4" >> "$(destroyed_path)"
        else
            exit 2
        fi
        """)
    chmod(fake_virsh, 0o755)
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        cleanup(backend)
    end
    destroyed = split(strip(read(destroyed_path, String)), '\n')
    @test current_domain in destroyed
    @test renamed_domain in destroyed
    @test foreign_domain ∉ destroyed

    # Cross-file contracts with the guest images, not guest-internal control
    # flow: the guest-exec entry points, the env the scheduler injects, the
    # exit/log files the host polls, and the cache-disk repair/detach that
    # guards the shared overlay against `virsh destroy` power-offs.
    windows_agent_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "windows-kvm", "buildkite-worker", "setup_scripts", "0-02-install-buildkite-agent.ps1"), String)
    @test occursin("run-buildkite-job.ps1", windows_agent_setup)
    @test occursin("BUILDKITE_AGENT_TOKEN=\$env:BUILDKITE_AGENT_TOKEN", windows_agent_setup)
    @test occursin("BUILDKITE_AGENT_TAGS=\$env:BUILDKITE_AGENT_TAGS", windows_agent_setup)
    @test occursin("BUILDKITE_ACQUIRE_JOB_ID=\$JobId", windows_agent_setup)
    # The token is injected per job over guest-exec, never baked into the image.
    @test occursin("placeholder-token", windows_agent_setup)
    @test occursin("run-buildkite-job.exit", windows_agent_setup)
    @test occursin("run-buildkite-job.log", windows_agent_setup)
    @test occursin("chkdsk", windows_agent_setup)
    @test occursin("Dismount-Volume", windows_agent_setup)

    windows_qga_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "windows-kvm", "buildkite-worker", "setup_scripts", "0-07-configure-qemu-guest-agent.ps1"), String)
    @test occursin("guest-exec", windows_qga_setup)

    freebsd_qga_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "setup_scripts", "install-qemu-guest-agent.sh"), String)
    @test all(rpc -> occursin(rpc, freebsd_qga_setup), ("guest-ping", "guest-exec", "guest-exec-status"))
    @test occursin("--block-rpcs=", freebsd_qga_setup)

    freebsd_agent_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "setup_scripts", "install-buildkite-agent.sh"), String)
    @test occursin("run-buildkite-job.sh", freebsd_agent_setup)
    @test occursin("--tags '\\\${BUILDKITE_AGENT_TAGS}'", freebsd_agent_setup)
    @test occursin("zpool export cache", freebsd_agent_setup)

    # Baked setup scripts must fail loudly instead of producing a broken image.
    for script in ("format-data-disk.sh", "install-more-dependencies.sh", "set-hostname.sh")
        contents = read(SandboxedBuildkiteAgent.repo_path("platforms", "freebsd-kvm", "buildkite-worker", "setup_scripts", script), String)
        @test occursin("set -e", contents)
    end

    # Queues/tags are injected per agent at runtime, never baked into the image.
    for packer in ("windows-kvm", "freebsd-kvm")
        contents = read(SandboxedBuildkiteAgent.repo_path("platforms", packer, "buildkite-worker", "kvm_machine.pkr.hcl"), String)
        @test !occursin("buildkite_queues", contents)
        @test !occursin("buildkite_tags", contents)
    end

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
    @test !parse_status_args(String[]).json
    @test parse_status_args(["--json"]).json
    @test_throws ErrorException parse_status_args(["--verbose"])
    logs = parse_logs_args(["--slot", "win2k22-tester-amdci6.3", "--job", "job-1", "--serial", "-n", "10"])
    @test logs.slot == "win2k22-tester-amdci6.3"
    @test logs.job == "job-1"
    @test logs.serial
    @test logs.lines == 10
    @test parse_logs_args(String[]).scheduler
    @test parse_logs_args(["--list"]).list
    @test_throws ErrorException parse_logs_args(["--job", "job-1"])
    @test_throws ErrorException parse_logs_args(["--scheduler", "--slot", "slot-1"])
    @test_throws ErrorException parse_logs_args(["--lines", "0"])
    @test parse_stop_args(String[]) === nothing
    @test_throws ErrorException parse_stop_args(["--force"])
end

@testset "scheduler log selection" begin
    logdir = mktempdir()
    config = SchedulerConfig(logdir, 0.01, 0.01, 900)
    slot = "slot.example-1"
    job_id = "job-1"
    mkpath(joinpath(logdir, slot))
    first_log = slot_log_path(config, slot, job_id)
    write(first_log, "old\n")
    sleep(0.02)
    second_log = slot_log_path(config, slot, "job-2")
    write(second_log, "new\n")
    serial_log = slot_log_path(config, slot, "job-2"; serial=true)
    write(serial_log, "serial\n")

    @test slot_log_path(config, slot, job_id) == joinpath(logdir, slot, "$(job_id).log")
    @test latest_slot_log_path(config, slot) == second_log
    @test latest_slot_log_path(config, slot; serial=true) == serial_log
    @test slot_log_files(config, slot) == [second_log, first_log]
    @test_throws ErrorException slot_log_path(config, "../bad", job_id)
    @test_throws ErrorException slot_log_path(config, slot, "../bad")
end

struct BlockingBackend <: PlatformBackend
    started::Channel{String}
    release::Channel{Nothing}
end

struct BlockingHandle
    backend::BlockingBackend
    job::Job
end

prepare(backend::BlockingBackend, slot::Slot, job::Job, plan::CachePlan,
        alloc::Allocation) = BlockingHandle(backend, job)

function run_job(handle::BlockingHandle, ::Union{Nothing,Float64}=nothing)
    put!(handle.backend.started, handle.job.id)
    take!(handle.backend.release)
    return 0
end

@testset "scheduler dispatcher jobs" begin
    backend = BlockingBackend(Channel{String}(2), Channel{Nothing}(2))
    source = StaticJobSource([job(; id="async-job")])
    scheduler = test_scheduler(
        test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir())],
        source,
        backend,
    )
    with_logger(NullLogger()) do
        @test poll_jobs!(scheduler) == 1
        task = @async run_available_assignment!(scheduler; block=true)
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
        task = @async run_available_assignment!(scheduler)
        @test take!(backend.started) == "second-job"
        put!(backend.release, nothing)
        @test timedwait(() -> istaskdone(task), 5.0) == :ok
    end
end

@testset "scheduler task supervision" begin
    failures = Channel{NamedTuple}(1)
    task = launch_scheduler_task(failures, "returning task") do
        nothing
    end
    failure = take!(failures)
    @test failure.label == "returning task"
    @test failure.exception isa ErrorException
    @test occursin("exited unexpectedly", sprint(showerror, failure.exception))
    @test timedwait(() -> istaskdone(task), 5.0) == :ok

    failures = Channel{NamedTuple}(1)
    task = launch_scheduler_task(failures, "failing task") do
        error("task failed")
    end
    failure = take!(failures)
    @test failure.label == "failing task"
    @test failure.exception isa ErrorException
    @test occursin("task failed", sprint(showerror, failure.exception))
    @test timedwait(() -> istaskdone(task), 5.0) == :ok
end

@testset "scheduler startup cleanup" begin
    backend = CleanupBackend(0, 0)
    source = StaticJobSource(Job[])
    scheduler = test_scheduler(
        test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir(), max_jobs=2)],
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

    forced_backend = CleanupBackend(0, 0)
    forced_source = StaticJobSource(Job[])
    forced_scheduler = test_scheduler(
        test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir())],
        forced_source,
        forced_backend;
        dry_run=true,
    )
    SandboxedBuildkiteAgent.cleanup_scheduler_resources!(forced_scheduler)
    @test forced_backend.count == 1
    @test forced_source.deregistered == 1
end

@testset "Linux scheduler cgroups" begin
    permutation = cpu_topology_permutation()
    @test length(permutation) >= Sys.CPU_THREADS
    @test condense_cpu_selection([0, 1, 2, 6, 7, 10, 15]) == "0-2,6-7,10,15"

    secrets = mktempdir()
    token_path = joinpath(secrets, "buildkite-agent-token")
    Base.write(token_path, "secret-token\n")
    brg = BuildkiteRunnerGroup("linux-env", Dict{String,Any}(
        "queues" => "build",
        "job_cpus" => 3,
        "cachedir" => mktempdir(),
        "secrets_dir" => secrets,
        "tags" => Dict{String,String}(
            "os" => "linux",
            "arch" => "x86_64",
            "sandbox_capable" => "true",
        ),
    ); host=:linux)
    sandbox_config = Sandbox.SandboxConfig(brg;
        agent_name=Slot(brg, 1).name,
        cache_path=mktempdir(),
        shared_cache_path=nothing,
        temp_path=mktempdir(),
        alloc=Allocation(3, "0-2"),
        rootfs_dir=mktempdir(),
        agent_token_path=token_path)
    @test sandbox_config.env["JULIA_CPU_THREADS"] == "3"

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

    kill_root = mktempdir()
    kill_path = joinpath(kill_root, "cgroup.kill")
    Base.write(kill_path, "")
    @test kill_cgroup(kill_root)
    @test read(kill_path, String) == "1\n"

    cgroup_root = mktempdir()
    stale_job = joinpath(cgroup_root, "job-linux-1-job-1")
    mkpath(joinpath(stale_job, "docker", "nested"))
    mkpath(joinpath(cgroup_root, "supervisor"))
    mkpath(joinpath(cgroup_root, "not-a-job"))
    with_logger(NullLogger()) do
        cleanup_job_cgroups(cgroup_root)
    end
    @test !ispath(stale_job)
    @test isdir(joinpath(cgroup_root, "supervisor"))
    @test isdir(joinpath(cgroup_root, "not-a-job"))

    stale_temp = mktempdir()
    mkpath(joinpath(stale_temp, "home"))
    backend.cleanup_paths = [stale_temp]
    cleanup(backend)
    @test !ispath(stale_temp)
end

@testset "Linux scheduler systemd service" begin
    unit_path = tempname()
    @test !scheduler_systemd_service_installed(; unit_path)
    Base.write(unit_path, "unit")
    @test scheduler_systemd_service_installed(; unit_path)

    config_path = tempname()
    Base.write(config_path, """
    [scheduler]

    [builder]
    backend = "linux-sandbox"
    queues = "build"
    job_cpus = 1

    [builder.tags]
    os = "linux"
    arch = "x86_64"
    sandbox_capable = "true"
    """)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, config_path; host=:linux)
    unit = String(take!(io))
    @test occursin("Delegate=cpuset", unit)
    @test occursin("bin/bk --config=$(abspath(config_path)) scheduler", unit)
    @test !occursin("--backend", unit)
    @test !occursin("--dry-run", unit)
    @test occursin("Restart=no", unit)
    @test !occursin("Restart=on-failure", unit)
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
    job_cpus = 2

    [windows.tags]
    os = "windows"
    arch = "x86_64"
    """)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, kvm_config_path; host=:linux)
    unit = String(take!(io))
    @test !occursin("Delegate=cpuset", unit)
    @test occursin("virsh -c qemu:///system list --name", unit)

    # `bk status` maps the supervisor's own report into a verdict.
    active = systemd_status_from_properties(Dict("ActiveState" => "active",
        "SubState" => "running", "Result" => "success", "ExecMainStatus" => "0"))
    @test active["running"] && active["state"] == "active" && active["detail"] == ""
    failed = systemd_status_from_properties(Dict("ActiveState" => "failed",
        "SubState" => "failed", "Result" => "exit-code", "ExecMainStatus" => "1"))
    @test !failed["running"] && failed["state"] == "failed"
    @test occursin("Result=exit-code", failed["detail"]) && occursin("exit status=1", failed["detail"])
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
    job_cpus = 2
    max_jobs = 2
    tempdir = "$(mktempdir())"

    [builder.tags]
    os = "macos"
    arch = "aarch64"
    """)

    scheduler_config = read_scheduler_config(config_path)
    @test scheduler_config.poll_interval == 15.0
    @test scheduler_config.reservation_expiry_seconds == 300

    io = IOBuffer()
    generate_scheduler_launchctl_script(io, config_path; host=:macos)
    plist = String(take!(io))
    @test occursin("org.julialang.buildkite.scheduler.", plist)
    @test occursin("bin/bk", plist)
    @test !occursin("--backend", plist)
    @test occursin("--config=$(abspath(config_path))", plist)
    @test first(findfirst("--config=$(abspath(config_path))", plist)) <
          first(findfirst(">scheduler<", plist))
    @test !occursin("--dry-run", plist)
    @test occursin("<string>$(logdir)/scheduler.log</string>", plist)
    # No KeepAlive: a fatal exit stays stopped instead of respawning.
    @test !occursin("KeepAlive", plist)

    token_path = joinpath(mktempdir(), "buildkite-agent-token")
    Base.write(token_path, "secret-token\n")
    seatbelt_env = build_seatbelt_env(mktempdir(), mktempdir();
        agent_token_path=token_path,
        julia_arch="aarch64",
        alloc=Allocation(2, ""))
    @test seatbelt_env["BUILDKITE_AGENT_TOKEN"] == "secret-token"
    @test seatbelt_env["BUILDKITE_PLUGIN_JULIA_ARCH"] == "aarch64"
    @test seatbelt_env["JULIA_CPU_THREADS"] == "2"

    # `bk status` maps `launchctl print` output into a verdict.
    running = launchctl_status_from_output("\tstate = running\n\tpid = 4321\n")
    @test running["running"] && running["state"] == "running" && running["detail"] == ""
    stopped = launchctl_status_from_output("\tstate = not running\n\tlast exit code = 1\n")
    @test !stopped["running"] && stopped["state"] == "stopped"
    @test stopped["detail"] == "last exit code=1"
    clean = launchctl_status_from_output("\tstate = not running\n\tlast exit code = 0\n")
    @test !clean["running"] && clean["detail"] == ""
end
