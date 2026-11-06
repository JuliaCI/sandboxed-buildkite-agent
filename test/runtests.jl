using Test, HTTP, JSON, Logging, Sandbox, Sockets
using SandboxedBuildkiteAgent
import SandboxedBuildkiteAgent:
    BACKEND_KVM,
    BACKEND_LINUX_SANDBOX,
    BACKEND_MACOS_SEATBELT,
    Allocation,
    AdmissionGroup,
    Candidate,
    BuildkiteHTTPError,
    BuildkiteRateLimited,
    BuildkiteRunnerGroup,
    CachePlan,
    ResourcePool,
    available,
    Job,
    JobSource,
    KVMBackend,
    KVMHandle,
    LeasePool,
    LinuxSandboxBackend,
    MacOSProcess,
    MacOSProcessIdentity,
    MacSeatbeltBackend,
    PlatformBackend,
    Scheduler,
    SchedulerConfig,
    Slot,
    StacksJobSource,
    StacksTransportError,
    cache_plan,
    check_backend_configs,
    cleanup,
    cleanup_backend_configs!,
    allocate!,
    admission_plan,
    encode_query,
    ensure_kvm_cache_overlay,
    escape_uri,
    generate_scheduler_launchctl_script,
    generate_macos_corefile_launchd_plist,
    generate_macos_core_cleanup_launchd_plist,
    generate_scheduler_systemd_script,
    get_job_env,
    build_seatbelt_env,
    finish_job_payload,
    finish_job_path,
    guest_agent_ready_timeout,
    guest_agent_stable_for,
    handle_poll_error!,
    linux_persist_root_cache,
    linux_persist_root_info,
    cleanup_job_cgroups,
    guest_exec_payload,
    job_cgroup_name,
    kill_cgroup,
    kvm_guest,
    kvm_backing_identity,
    kvm_bridge_stp_enabled,
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
    macos_agent_temp_path,
    macos_process_matches,
    macos_reap_process_ids,
    macos_retired_reaper_identities,
    macos_slot_cache_root,
    macos_slot_reaper_identity,
    mine,
    parse_ipcs_semaphores,
    remove_idle_macos_sysv_semaphores_locked,
    parse_logs_args,
    parse_scheduler_args,
    parse_status_args,
    parse_stop_args,
    print_stop_job_report,
    prepare_kvm_log_file,
    poll_result,
    poll_jobs,
    poll_jobs!,
    prepare,
    reap,
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
    stop_snapshot_jobs,
    read_scheduler_status_snapshot,
    reinstall_scheduler_service,
    restart_scheduler_service,
    scheduler_systemd_service_installed,
    seatbelt_setup,
    systemd_status_from_properties,
    scheduled_job_from_json,
    setup_backend!,
    setup_backend_configs!,
    slot_log_files,
    slot_log_path,
    stacks_http_request,
    stack_key_override,
    stacks_request,
    job_acquisition_token,
    mint_job_token,
    JobTokenUnavailable,
    start_scheduler!,
    is_transient_poll_error,
    take_assignment!,
    trust_from_env,
    wrap_command_in_cgroup_join_file

function runner_group(; name="tester", cachedir_root=mktempdir(), sharedcache_root=nothing,
                      max_slots=1, cpus=1, priority=10, backend=nothing,
                      host=:linux)
    config = Dict{String,Any}(
        "queues" => "build",
        "max_slots" => max_slots,
        "default" => Dict("cpus" => cpus),
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
             agent_query_rules=["queue=build", "os=linux", "arch=x86_64"], priority=0)
    return Job(
        id,
        pipeline_id,
        collect(agent_query_rules),
        priority,
    )
end

function test_scheduler_config()
    return SchedulerConfig(mktempdir(), 0.01, 0.01, 900)
end

function stacks_test_source(endpoint)
    secrets = mktempdir()
    token_path = joinpath(secrets, "buildkite-agent-token")
    Base.write(token_path, "agent-token\n")
    chmod(token_path, 0o600)
    brg = BuildkiteRunnerGroup("julia", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "default" => Dict("cpus" => 1),
        "secrets_dir" => secrets,
        "stack_key" => "julia-test-stack",
    ); host=:linux)
    return StacksJobSource(test_scheduler_config(), brg; endpoint)
end

function with_http_server(f, handler)
    server = HTTP.serve!(handler, "127.0.0.1", 0; verbose=-1)
    _, port = Sockets.getsockname(server.listener.server)
    try
        return f("http://127.0.0.1:$(Int(port))")
    finally
        close(server)
        wait(server.task)
    end
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
    @test SchedulerConfig(Dict{String,Any}()).assignment_timeout_seconds == 12 * 60 * 60.0
    # Unknown keys are errors, so a typo does not go unnoticed.
    err = try
        SchedulerConfig(Dict{String,Any}("logdir" => "logs", "idle_sleep" => 1.0); config_dir="/tmp")
    catch err
        err
    end
    @test err isa ArgumentError && occursin("idle_sleep", err.msg)
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
    @test parsed.total_mem_gib == SandboxedBuildkiteAgent.host_mem_gib()
    @test parsed.min_mem_available_gib == 0
    # io accounting for Linux job cgroups is on unless a host turns it off.
    @test parsed.io_accounting
    @test !SchedulerConfig(Dict{String,Any}("io_accounting" => false)).io_accounting
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}("io_accounting" => "no"))
    @test SandboxedBuildkiteAgent.make_backend(SandboxedBuildkiteAgent.BACKEND_LINUX_SANDBOX,
        SchedulerConfig(Dict{String,Any}("io_accounting" => false))).io_accounting == false
    memory = SchedulerConfig(Dict{String,Any}("total_mem_gib" => 2, "min_mem_available_gib" => 1))
    @test (memory.total_mem_gib, memory.min_mem_available_gib) == (2, 1)
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "total_mem_gib" => SandboxedBuildkiteAgent.host_mem_gib() + 1))
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "total_mem_gib" => 2, "min_mem_available_gib" => 2))
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "total_cpus" => 0,
    ))
    @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(
        "total_cpus" => SandboxedBuildkiteAgent.host_cpu_count() + 1,
    ))
    @test SchedulerConfig(Dict{String,Any}()).total_cpus == SandboxedBuildkiteAgent.host_cpu_count()
    if Sys.isapple()
        # All logical cores, not only Apple Silicon's performance cores.
        @test SandboxedBuildkiteAgent.host_cpu_count() ==
            parse(Int, readchomp(`sysctl -n hw.logicalcpu`))
        @test SandboxedBuildkiteAgent.host_cpu_count() >= Sys.CPU_THREADS
    else
        @test SandboxedBuildkiteAgent.host_cpu_count() == Sys.CPU_THREADS
    end
end

@testset "scheduler rate-limit backoff" begin
    config = SchedulerConfig(mktempdir(), 0.01, 5.0, 900)
    @test scheduler_error_sleep(config, ErrorException("boom")) == 5.0
    @test scheduler_error_sleep(config, BuildkiteRateLimited(1.0)) == 5.0
    @test scheduler_error_sleep(config, BuildkiteRateLimited(30.0)) == 30.0
end

@testset "resource pools" begin
    pool = ResourcePool(4)
    @test allocate!(pool, 2) == 2
    @test allocate!(pool, 1) == 1
    @test available(pool) == 1
    @test allocate!(pool, 2) === nothing
    @test allocate!(pool, 0) == 0
    release!(pool, 2)
    @test allocate!(pool, 3) == 3
    release!(pool, 1)
    release!(pool, 3)
    @test available(pool) == 4
    @test_throws ErrorException release!(pool, 1)
    @test_throws ArgumentError ResourcePool(0)

    brg = runner_group(; name="leased", max_slots=2)
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

function linux_group(name; queues=["build", "test"], default=nothing, priority=10,
                     max_slots=4, extra=Dict{String,Any}(), total_cpus=128, total_mem_gib=512)
    config = merge(Dict{String,Any}(
        "queues" => queues,
        "max_slots" => max_slots,
        "priority" => priority,
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64"),
    ), extra)
    default === nothing || (config["default"] = default)
    return BuildkiteRunnerGroup(name, config; host=:linux, total_cpus, total_mem_gib)
end

sized_job(id; queue="test", tags=String[], priority=0, scheduled_at="2026-10-30T10:00:00.000Z") =
    Job(id, "01800000-0000-0000-0000-000000000000",
        vcat(["queue=$(queue)", "os=linux"], tags), priority, scheduled_at)

@testset "admission policy" begin
    config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 16, 64, 0)
    alloc(cpus; mem=0) = Allocation(cpus, cpus, 0, 0, mem)
    group(name; priority=10, free_slots=8) =
        AdmissionGroup(name, priority, free_slots, Slot(linux_group(name), 1))
    candidate(group, job, cpus; source=group, mem=0) =
        Candidate(group, source, job, alloc(cpus; mem))
    ids(plan) = [a.job.id for a in plan.admissions]
    at(minute) = "2026-10-30T10:$(lpad(minute, 2, '0')):00.000Z"

    # One pass in age order across groups and queues.
    groups = [group("linux"), group("other")]
    aged = [candidate("other", sized_job("young"; scheduled_at=at(3)), 4),
            candidate("linux", sized_job("old"; scheduled_at=at(1)), 4; source="linux/build"),
            candidate("linux", sized_job("mid"; scheduled_at=at(2)), 4; source="linux/test")]
    plan = admission_plan(groups, aged, 8)
    @test ids(plan) == ["old", "mid"]
    @test [a.source for a in plan.admissions] == ["linux/build", "linux/test"]
    @test plan.blocked["other"] && !plan.blocked["linux"]

    # Group priority first, then Buildkite job priority, then age, then id.
    ordered = [candidate("other", sized_job("b"; scheduled_at=at(1)), 1),
               candidate("other", sized_job("a"; scheduled_at=at(1)), 1),
               candidate("other", sized_job("urgent"; scheduled_at=at(5), priority=3), 1),
               candidate("first", sized_job("late"; scheduled_at=at(9)), 1)]
    @test ids(admission_plan([group("first"; priority=1), group("other")], ordered, 16)) ==
        ["late", "urgent", "a", "b"]

    # Head-of-line blocking: a younger small job does not overtake an older big one.
    hol = [candidate("linux", sized_job("big"; scheduled_at=at(1)), 12),
           candidate("linux", sized_job("small"; scheduled_at=at(2)), 1)]
    @test isempty(admission_plan([group("linux")], hol, 8).admissions)
    @test ids(admission_plan([group("linux")], hol, 13)) == ["big", "small"]

    # Groups without a free slot neither run nor block others.
    full = [candidate("full", sized_job("waiting"; scheduled_at=at(1)), 12),
            candidate("linux", sized_job("runs"; scheduled_at=at(2)), 4)]
    plan = admission_plan([group("full"; free_slots=0), group("linux")], full, 8)
    @test ids(plan) == ["runs"]
    @test !plan.blocked["full"]
    # ... and slots bound a group's admissions.
    many = [candidate("linux", sized_job(string(i); scheduled_at=at(i)), 1) for i in 1:5]
    @test ids(admission_plan([group("linux"; free_slots=2)], many, 16)) == ["1", "2"]

    # Jobs that charge nothing (launchers with `cpus = 0`) pass a blocked head.
    free = [candidate("linux", sized_job("big"; scheduled_at=at(1)), 12),
            candidate("launch", sized_job("launch"; scheduled_at=at(2)), 0)]
    @test ids(admission_plan([group("linux"), group("launch")], free, 4)) == ["launch"]

    # KVM memory reservations fit like CPUs, and a request larger than the host
    # is skipped rather than blocking it forever.
    vms = [candidate("vm", sized_job("huge"; scheduled_at=at(1)), 4; mem=600),
           candidate("vm", sized_job("a"; scheduled_at=at(2)), 4; mem=32),
           candidate("vm", sized_job("b"; scheduled_at=at(3)), 4; mem=32),
           candidate("linux", sized_job("c"; scheduled_at=at(4)), 4)]
    plan = admission_plan([group("vm"), group("linux")], vms, 16, 40; total_mem_gib=512)
    @test ids(plan) == ["a"]
    @test [c.job.id for c in plan.impossible] == ["huge"]
    @test plan.blocked["vm"] && plan.blocked["linux"]

    # A probed source holds back its group's priority and below until it is
    # fully listed, but not higher-priority groups, and only while its group
    # could take a job.
    probe = [candidate("launch", sized_job("launch"; scheduled_at=at(5)), 1),
             candidate("linux", sized_job("other-queue"; scheduled_at=at(1)), 1),
             candidate("low", sized_job("low"; scheduled_at=at(1)), 1)]
    groups = [group("launch"; priority=0), group("linux"), group("low"; priority=20)]
    plan = admission_plan(groups, probe, 16; probed_groups=["linux"])
    @test ids(plan) == ["launch"]
    @test plan.blocked["linux"] && plan.blocked["low"]
    groups = [group("launch"; priority=0), group("linux"; free_slots=0), group("low"; priority=20)]
    @test ids(admission_plan(groups, probe, 16; probed_groups=["linux"])) == ["launch", "low"]

    # Claimed, quarantined and unmatched jobs are skipped.
    skipped = [candidate("linux", sized_job("claimed"; scheduled_at=at(1)), 1),
               candidate("linux", sized_job("quarantined"; scheduled_at=at(2)), 1),
               candidate("linux", Job("wrong-os", nothing, ["queue=test", "os=macos"], 0, at(3)), 1),
               candidate("linux", sized_job("eligible"; scheduled_at=at(4)), 1)]
    plan = admission_plan([group("linux")], skipped, 2;
        claimed_jobs=Set(["claimed"]), quarantined_jobs=Dict("quarantined" => time() + 60))
    @test ids(plan) == ["eligible"]
end

@testset "job size requests" begin
    config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 64, 256, 0)
    linux = linux_group("linux"; total_cpus=64, total_mem_gib=256)
    size(job; brg=linux) = SandboxedBuildkiteAgent.job_allocation(brg, job, config)
    all3(cpus, cpus_limit, mem) = ["sched_cpus=$(cpus)", "sched_cpus_limit=$(cpus_limit)", "sched_mem_gib=$(mem)"]

    @test size(sized_job("build"; tags=all3(4, 16, 40))) == Allocation(4, 16, 40, 40, 0)
    # Limits default to their request.
    @test size(sized_job("test"; tags=["sched_cpus=12", "sched_mem_gib=64"])) == Allocation(12, 12, 64, 64, 0)
    # The other two are required, and all must be positive integers.
    @test size(sized_job("untagged")) === nothing
    @test size(sized_job("partial"; tags=["sched_cpus=1"])) === nothing
    @test size(sized_job("bad"; tags=all3("many", 1, 8))) === nothing
    @test size(sized_job("zero"; tags=all3(0, 1, 8))) === nothing
    @test size(sized_job("bad-limit"; tags=all3(1, "x", 8))) === nothing
    # A memory limit above the request; limits below their request are invalid.
    @test size(sized_job("mem"; tags=[all3(4, 16, 12); "sched_mem_limit_gib=40"])) == Allocation(4, 16, 12, 40, 0)
    @test size(sized_job("narrow"; tags=all3(4, 2, 8))) === nothing
    @test size(sized_job("small"; tags=[all3(4, 4, 16); "sched_mem_limit_gib=8"])) === nothing
    errors(tags) = SandboxedBuildkiteAgent.sched_tag_errors(sized_job("p"; tags))
    @test errors(["sched_cpus=1", "sched_mem_gib=x"]) == ["`sched_mem_gib=x` is not a positive integer"]
    @test errors(["sched_cpus_limit=0"]) == ["`sched_cpus_limit=0` is not a positive integer",
        "`sched_cpus` is missing", "`sched_mem_gib` is missing"]
    @test errors([all3(4, 2, 8); "sched_mem_limit_gib=4"]) ==
        ["`sched_cpus_limit=2` is below `sched_cpus=4`", "`sched_mem_limit_gib=4` is below `sched_mem_gib=8`"]
    @test isempty(errors(["sched_cpus=1", "sched_mem_gib=8"]))
    @test isempty(errors(String[]))
    @test errors(["sched_cpus=1", "sched_cpus=2", "sched_mem_gib=8"]) == ["`sched_cpus` is set more than once"]
    # GiB that do not fit in bytes would wrap around (2^34 GiB to 0, which
    # leaves `memory.max` unset), so they are rejected.
    @test occursin("more memory than can be represented",
        only(errors(["sched_cpus=1", "sched_mem_gib=8", "sched_mem_limit_gib=17179869184"])))
    @test size(sized_job("huge"; tags=["sched_cpus=1", "sched_mem_gib=8", "sched_mem_limit_gib=17179869184"])) === nothing
    @test isempty(errors(["sched_cpus=1", "sched_mem_gib=$(SandboxedBuildkiteAgent.MAX_MEM_GIB)"]))
    @test_throws OverflowError SandboxedBuildkiteAgent.gib_bytes(17179869184)
    @test SandboxedBuildkiteAgent.gib_bytes(2) == 2 * 1024^3
    @test errors(["sched_cpus=1", "sched_mem_gib=8", "sched_mem_limit_gib=99999999999999999999"]) ==
        ["`sched_mem_limit_gib=99999999999999999999` is not a positive integer"]
    # The scheduler owns every `sched_*` key: renamed ones, typos and other
    # operators fail the job instead of leaving it to wait for a matching agent.
    renamed = sized_job("renamed"; tags=["sched_cpus=4", "sched_threads=16", "sched_mem_gib=8"])
    @test size(renamed) === nothing
    @test errors(renamed.agent_query_rules) == ["`sched_threads` was renamed to `sched_cpus_limit`"]
    typo = sized_job("typo"; tags=["sched_cpus=4", "sched_mem_gb=8"])
    @test size(typo) === nothing
    @test occursin("`sched_mem_gb` is not a size tag", first(errors(typo.agent_query_rules)))
    @test errors(typo.agent_query_rules)[end] == "`sched_mem_gib` is missing"
    negated = sized_job("negated"; tags=["sched_cpus=4", "sched_mem_gib=8", "sched_cpus_limit!=2"])
    @test size(negated) === nothing
    @test errors(negated.agent_query_rules) == ["`sched_cpus_limit!=2` must set `sched_cpus_limit` with `=`"]
    @test errors(["sched_cpus=4", "sched_mem_gib=8", "sched_cpus_limit"]) ==
        ["`sched_cpus_limit` must set `sched_cpus_limit` with `=`"]
    for bad in (renamed, typo, negated)
        @test mine(Slot(linux, 1), bad)
        @test size(bad; brg=linux_group("d"; default=Dict("cpus" => 1))) === nothing
    end
    # Requests and limits larger than the host get the whole host, so the
    # affinity mask and `JULIA_CPU_THREADS` agree.
    @test size(sized_job("wide"; tags=all3(200, 200, 64))) == Allocation(64, 64, 64, 64, 0)
    @test size(sized_job("burst"; tags=all3(4, 200, 64))) == Allocation(4, 64, 64, 64, 0)

    # KVM clamps vCPUs and guest RAM to the image's limits and reserves overhead.
    windows = BuildkiteRunnerGroup("windows", Dict{String,Any}("max_slots" => 2,
        "backend" => "kvm", "guest" => "windows", "max_cpus" => 6, "max_mem_gib" => 32,
        "tags" => Dict("os" => "windows", "arch" => "x86_64"),
    ); host=:linux, total_cpus=64, total_mem_gib=256)
    @test windows.queues == ["build", "test"]
    @test size(sized_job("test"; tags=all3(6, 6, 24)); brg=windows) == Allocation(6, 6, 24, 24, 26)
    # A request clipped with its limit is charged no more than the guest's vCPUs.
    @test size(sized_job("greedy"; tags=all3(8, 16, 64)); brg=windows) == Allocation(6, 6, 32, 32, 34)
    @test size(sized_job("split"; tags=[all3(2, 16, 48); "sched_mem_limit_gib=64"]); brg=windows) ==
        Allocation(2, 6, 32, 32, 34)

    # Untagged jobs get the group's `default`; tags override it.
    launch = linux_group("launch"; queues="launch", default=Dict("cpus" => 1), max_slots=2)
    @test size(sized_job("upload"; queue="launch")) === nothing
    @test size(sized_job("upload"; queue="launch"); brg=launch) == Allocation(1, 1, 0, 0, 0)
    @test size(sized_job("tagged"; queue="launch", tags=all3(8, 8, 8)); brg=launch) == Allocation(8, 8, 8, 8, 0)

    # A queue's own default wins over the group's; queues without one use the group's.
    per_queue = linux_group("linux"; queues=["build", "test", "other"], default=Dict(
        "cpus" => 2,
        "build" => Dict("cpus" => 4, "cpus_limit" => 16, "mem_gib" => 40),
        "test" => Dict("cpus" => 12, "mem_gib" => 64)))
    @test size(sized_job("b"; queue="build"); brg=per_queue) == Allocation(4, 16, 40, 40, 0)
    @test size(sized_job("t"; queue="test"); brg=per_queue) == Allocation(12, 12, 64, 64, 0)
    @test size(sized_job("o"; queue="other"); brg=per_queue) == Allocation(2, 2, 0, 0, 0)
    @test size(sized_job("t"; queue="test", tags=all3(1, 1, 8)); brg=per_queue) == Allocation(1, 1, 8, 8, 0)
    # Without a group default, a queue without its own is unsized.
    only_build = linux_group("linux"; default=Dict("build" => Dict("cpus" => 4)))
    @test size(sized_job("b"; queue="build"); brg=only_build) == Allocation(4, 4, 0, 0, 0)
    @test size(sized_job("t"; queue="test"); brg=only_build) === nothing

    # Any `sched_*` tag makes the request explicit: incomplete or invalid ones are
    # unsized rather than falling back to the default.
    @test size(sized_job("partial"; queue="test", tags=["sched_cpus=1"]); brg=per_queue) === nothing
    @test size(sized_job("limit-only"; queue="test", tags=["sched_cpus_limit=4"]); brg=per_queue) === nothing
    @test size(sized_job("bad"; queue="test", tags=all3(1, 1, "x")); brg=per_queue) === nothing
    @test size(sized_job("zero"; queue="test", tags=all3(0, 1, 8)); brg=per_queue) === nothing

    # The failure message says which rule the step broke.
    detail(job) = SandboxedBuildkiteAgent.unsized_job_detail(linux, job)
    @test occursin("`default`", detail(sized_job("untagged")))
    @test occursin("queue test", detail(sized_job("untagged")))
    @test occursin("does not fall back", detail(sized_job("partial"; tags=["sched_cpus=1"])))
    @test occursin("- `sched_mem_gib` is missing", detail(sized_job("partial"; tags=["sched_cpus=1"])))
    @test occursin("- `sched_threads` was renamed to `sched_cpus_limit`", detail(renamed))

    # macOS jobs get the whole host, its CPUs and its memory, tagged or not.
    mac = BuildkiteRunnerGroup("macos", Dict{String,Any}("tempdir" => "/private/var/tmp");
        host=:macos, total_cpus=4, total_mem_gib=6)
    @test mac.default == SandboxedBuildkiteAgent.JobSize(4, 4, 6)
    mac_config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 4, 6, 0)
    @test SandboxedBuildkiteAgent.job_allocation(mac, sized_job("m"; tags=all3(1, 1, 1)),
        mac_config) == Allocation(4, 4, 6, 6, 0)
    @test SandboxedBuildkiteAgent.job_allocation(mac, sized_job("m"; tags=["sched_cpus=1"]),
        mac_config) == Allocation(4, 4, 6, 6, 0)
    @test SandboxedBuildkiteAgent.job_allocation(mac, sized_job("m"), mac_config) ==
        Allocation(4, 4, 6, 6, 0)
    # ... but their `sched_*` rules must still be valid.
    @test SandboxedBuildkiteAgent.job_allocation(mac, renamed, mac_config) === nothing
    @test SandboxedBuildkiteAgent.job_allocation(mac, sized_job("m"; tags=["sched_cpus=x"]),
        mac_config) === nothing

    # Agents match jobs ignoring the queue and every `sched_*` rule, and
    # advertise the job's queue and its valid size tags.
    tagged = sized_job("tagged"; tags=["sched_cpus=4", "sched_cpus_limit=16", "sched_mem_gib=x"])
    @test mine(Slot(linux, 1), tagged)
    @test mine(Slot(linux, 1), sized_job("other"; tags=["sched_other=1", "sched_cpus!=1"]))
    @test !mine(Slot(linux, 1), sized_job("other"; tags=["other=1"]))
    tags = split(SandboxedBuildkiteAgent.buildkite_agent_tags(linux, tagged), ",")
    @test "queue=test" in tags && !("queue=build" in tags)
    @test "sched_cpus=4" in tags && "sched_cpus_limit=16" in tags
    @test !any(startswith("sched_mem_gib"), tags)
    @test SandboxedBuildkiteAgent.job_queue(linux, Job("q", nothing, ["os=linux"])) == "build"
end

@testset "host CPU tag" begin
    tag = SandboxedBuildkiteAgent.host_cpu_tag
    @test tag("Apple M2") == "apple-m2"
    @test tag("Apple M3 Pro") == "apple-m3-pro"
    @test tag("AMD Ryzen 9 9950X 16-Core Processor") == "amd-ryzen-9-9950x-16-core-processor"
    @test tag("Neoverse-N1") == "neoverse-n1"
    @test tag("Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz") == "intel-r-core-tm-i7-8700b-cpu-3-20ghz"
    @test tag("POWER9 (architected), altivec supported") == "power9-architected-altivec-supported"
    @test tag("") === nothing
    @test tag(" (?) ") === nothing
    @test tag() == tag(Sys.cpu_info()[1].model)

    # Every group gets the host's value, KVM guests included (their vCPUs run
    # on the host CPU), unless its config names a `cpu` itself.
    apply! = SandboxedBuildkiteAgent.apply_host_cpu_tag!
    linux = linux_group("linux")
    mac = BuildkiteRunnerGroup("macos", Dict{String,Any}("tempdir" => "/private/var/tmp");
        host=:macos, total_cpus=4, total_mem_gib=6)
    kvm = BuildkiteRunnerGroup("windows", Dict{String,Any}("max_slots" => 2,
        "backend" => "kvm", "guest" => "windows", "max_cpus" => 6, "max_mem_gib" => 32,
        "tags" => Dict("os" => "windows", "arch" => "x86_64"),
    ); host=:linux, total_cpus=64, total_mem_gib=256)
    pinned = BuildkiteRunnerGroup("pinned", Dict{String,Any}("tempdir" => "/private/var/tmp",
        "tags" => Dict("cpu" => "apple-m2")); host=:macos, total_cpus=4, total_mem_gib=6)
    @test_logs (:info, r"CPU") match_mode=:any apply!([linux, mac, kvm, pinned], "apple-m1")
    for brg in (linux, mac, kvm)
        tags = split(SandboxedBuildkiteAgent.buildkite_agent_tags(brg, sized_job("j")), ",")
        @test "cpu=apple-m1" in tags
    end
    @test pinned.tags["cpu"] == "apple-m2"

    # An unknown model leaves the tag out rather than refusing to start.
    bare = linux_group("bare")
    @test_logs (:warn, r"CPU model") apply!([bare], nothing)
    @test !haskey(bare.tags, "cpu")
end

@testset "runner group sizes and slots" begin
    # `slots` is the `max_slots` unless the config sets it; `nothing` leaves it out.
    parse(config; host=:linux, total_cpus=128, total_mem_gib=512, slots=4) =
        BuildkiteRunnerGroup("g", merge(slots === nothing ? Dict{String,Any}() :
            Dict{String,Any}("max_slots" => slots), Dict{String,Any}(config));
            host, total_cpus, total_mem_gib)
    size(s) = (s.cpus, s.cpus_limit, s.mem_gib, s.mem_limit_gib)
    size(g::BuildkiteRunnerGroup) = size(g.default)

    # Tag-sized groups serve build and test by default from one pool of slots.
    g = parse(Dict("max_slots" => 20))
    @test g.queues == ["build", "test"]
    @test g.default === nothing && isempty(g.queue_defaults)
    @test g.max_slots == 20
    # Slots are a disk budget, which no CPU count implies.
    err = try parse(Dict(); slots=nothing) catch err; err end
    @test err isa ArgumentError && occursin("must set `max_slots`", err.msg)
    @test parse(Dict("queues" => "build, test")).queues == ["build", "test"]
    @test parse(Dict("queues" => ["test"])).queues == ["test"]
    @test_throws ArgumentError parse(Dict("queues" => String[]))
    @test_throws ArgumentError parse(Dict("max_slots" => 0))
    @test_throws ArgumentError parse(Dict("stack_key" => "julia-x"))
    @test parse(Dict("queues" => "build", "stack_key" => "julia-x")).stack_key == "julia-x"

    # Defaults for untagged jobs.
    @test size(parse(Dict("default" => Dict("cpus" => 4)))) == (4, 4, 0, 0)
    @test size(parse(Dict("default" => Dict("cpus" => 2, "cpus_limit" => 8, "mem_gib" => 16)))) == (2, 8, 16, 16)
    @test parse(Dict("default" => Dict("cpus" => 0), "max_slots" => 4)).default.cpus == 0
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 0)); slots=nothing)
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus_limit" => 4)))
    @test size(parse(Dict("default" => Dict("cpus" => 2, "cpus_limit" => 8, "mem_gib" => 12,
        "mem_limit_gib" => 40)))) == (2, 8, 12, 40)
    @test size(parse(Dict("default" => Dict("cpus" => 0, "cpus_limit" => 1), "max_slots" => 2))) == (0, 1, 0, 0)
    # `cpuset_limited` is advertised only where every job gets a cpuset.
    @test parse(Dict()).tags["cpuset_limited"] == "true"
    @test !haskey(parse(Dict("default" => Dict("cpus" => 0), "max_slots" => 4)).tags, "cpuset_limited")
    @test parse(Dict("default" => Dict("cpus" => 0, "cpus_limit" => 1), "max_slots" => 4)).tags["cpuset_limited"] == "true"
    # Limits may not be below their request.
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 4, "cpus_limit" => 2)))
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 4, "mem_gib" => 16, "mem_limit_gib" => 8)))
    # `threads` was renamed; the error says to what.
    err = try parse(Dict("default" => Dict("cpus" => 4, "threads" => 8))) catch err; err end
    @test err isa ArgumentError && occursin("`cpus_limit`", err.msg)
    err = try parse(Dict("default" => Dict("test" => Dict("cpus" => 4, "threads" => 8)))) catch err; err end
    @test err isa ArgumentError && occursin("`cpus_limit`", err.msg)
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 200)))
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 4, "cpus_limit" => 0)))
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 4, "mem_gib" => 0)))
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 4, "mem_limit_gib" => 17179869184)))
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 4, "cores" => 4)))
    @test_throws ArgumentError parse(Dict("default" => Dict()))
    # Per-queue tables are complete sizes, for queues the group serves.
    g = parse(Dict("default" => Dict(
        "build" => Dict("cpus" => 4, "cpus_limit" => 16, "mem_gib" => 40),
        "test" => Dict("cpus" => 12, "mem_gib" => 64))))
    @test g.default === nothing
    @test size(g.queue_defaults["build"]) == (4, 16, 40, 40)
    @test size(g.queue_defaults["test"]) == (12, 12, 64, 64)
    g = parse(Dict("default" => Dict("cpus" => 1, "test" => Dict("cpus" => 2))))
    @test size(g) == (1, 1, 0, 0) && size(g.queue_defaults["test"]) == (2, 2, 0, 0)
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 4, "test" => Dict("mem_gib" => 8))))
    @test_throws ArgumentError parse(Dict("default" => Dict("launch" => Dict("cpus" => 1))))
    @test_throws ArgumentError parse(Dict("queues" => "test", "default" => Dict("build" => Dict("cpus" => 1))))
    @test_throws ArgumentError parse(Dict("default" => Dict("test" => 4)))
    @test_throws ArgumentError parse(Dict("default" => Dict("test" => Dict("cpus" => 0))); slots=nothing)
    @test parse(Dict("default" => Dict("test" => Dict("cpus" => 0)), "max_slots" => 2)).max_slots == 2

    # KVM shape clamps are KVM-only, and a guest must fit the host.
    @test_throws ArgumentError parse(Dict("max_cpus" => 6))
    kvm(extra) = parse(merge(Dict{String,Any}("backend" => "kvm", "guest" => "windows",
        "tags" => Dict("os" => "windows", "arch" => "x86_64")), extra))
    @test kvm(Dict("max_cpus" => 6, "max_mem_gib" => 32)).max_cpus == 6
    @test_throws ArgumentError kvm(Dict("max_mem_gib" => 511))
    @test_throws ArgumentError kvm(Dict("default" => Dict("cpus" => 4)))
    @test_throws ArgumentError kvm(Dict("default" => Dict("cpus" => 0, "mem_gib" => 8), "max_slots" => 1))
    @test_throws ArgumentError kvm(Dict("default" => Dict("test" => Dict("cpus" => 6))))
    @test_throws ArgumentError kvm(Dict("default" => Dict("test" => Dict("cpus" => 6, "mem_gib" => 511))))
    @test size(kvm(Dict("default" => Dict("test" => Dict("cpus" => 6, "mem_gib" => 24)))).queue_defaults["test"]) == (6, 6, 24, 24)

    # macOS runs one job per host unless told otherwise.
    mac = parse(Dict(); host=:macos, total_cpus=4, total_mem_gib=6, slots=nothing)
    @test size(mac) == (4, 4, 6, 6) && mac.max_slots == 1
    @test_throws ArgumentError parse(Dict("default" => Dict("cpus" => 1)); host=:macos, total_cpus=4)
    @test_throws ArgumentError parse(Dict("default" => Dict("build" => Dict("cpus" => 1))); host=:macos, total_cpus=4)

    # Keys of earlier formats are rejected with a pointer to their replacement.
    for key in ("job_cpus", "max_jobs", "threads", "max_threads", "mem_gib", "size", "num_agents", "num_cpus")
        @test_throws ArgumentError parse(Dict(key => 1))
    end
    err = try parse(Dict("size" => Dict("cpus" => 1))) catch err; err end
    @test err isa ArgumentError && occursin("`default`", err.msg)
end

@testset "runner group backend config" begin
    linux_group = BuildkiteRunnerGroup("linux", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "default" => Dict("cpus" => 1),
    ); host=:linux)
    @test linux_group.backend == BACKEND_LINUX_SANDBOX

    mac_group = BuildkiteRunnerGroup("mac", Dict{String,Any}(
        "queues" => "build",
    ); host=:macos)
    @test mac_group.backend == BACKEND_MACOS_SEATBELT

    kvm_group = BuildkiteRunnerGroup("windows", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "windows",
        "default" => Dict("cpus" => 2, "mem_gib" => 8),
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
    ); host=:linux)
    @test kvm_group.backend == BACKEND_KVM
    @test kvm_guest(kvm_group) == "windows"
    @test kvm_group.tags["os"] == "windows"

    freebsd_group = BuildkiteRunnerGroup("freebsd", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "freebsd",
        "default" => Dict("cpus" => 2, "mem_gib" => 8),
        "tags" => Dict{String,String}("arch" => "x86_64"),
    ); host=:linux)
    @test freebsd_group.tags["os"] == "freebsd"

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}("max_slots" => 2,
        "backend" => BACKEND_KVM,
        "default" => Dict("cpus" => 1, "mem_gib" => 4),
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}("max_slots" => 2,
        "backend" => BACKEND_LINUX_SANDBOX,
        "guest" => "freebsd",
        "default" => Dict("cpus" => 1),
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}("max_slots" => 2,
        "backend" => "wat",
        "default" => Dict("cpus" => 1),
    ); host=:linux)

    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}(
        "backend" => BACKEND_MACOS_SEATBELT,
        "default" => Dict("cpus" => 1),
    ); host=:linux)

    stack_group = BuildkiteRunnerGroup("stack", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "default" => Dict("cpus" => 1),
        "stack_key" => "julia_stack_1",
    ); host=:linux)
    @test stack_key_override(stack_group) == "julia_stack_1"
    @test_throws ArgumentError BuildkiteRunnerGroup("bad", Dict{String,Any}("max_slots" => 2,
        "stack_key" => "not ok",
        "default" => Dict("cpus" => 1),
    ); host=:linux)

    err = try
        BuildkiteRunnerGroup("typo", Dict{String,Any}("queues" => "build", "max_slots" => 1,
            "default" => Dict("cpus" => 1), "num_agent" => 2); host=:linux)
    catch err
        err
    end
    @test err isa ArgumentError && occursin("num_agent", err.msg)
    # So is the removed rootless docker option.
    @test_throws ArgumentError BuildkiteRunnerGroup("docker", Dict{String,Any}("queues" => "build",
        "max_slots" => 1, "start_rootless_docker" => true); host=:linux)
    @test_throws ArgumentError BuildkiteRunnerGroup("old", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "num_agents" => 2,
        "default" => Dict("cpus" => 1),
    ); host=:linux)
    @test_throws ArgumentError BuildkiteRunnerGroup("old", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "num_cpus" => 2,
        "default" => Dict("cpus" => 1),
    ); host=:linux)
    @test_throws ArgumentError BuildkiteRunnerGroup("zero", Dict{String,Any}(
        "queues" => "build",
        "default" => Dict("cpus" => 0),
    ); host=:linux)
    zero = BuildkiteRunnerGroup("zero", Dict{String,Any}(
        "queues" => "launch",
        "default" => Dict("cpus" => 0),
        "max_slots" => 2,
    ); host=:linux)
    @test zero.max_slots == 2
    @test_throws ArgumentError BuildkiteRunnerGroup("defaulted", Dict{String,Any}(
        "queues" => "build",
        "default" => Dict("cpus" => 2),
    ); host=:linux, total_cpus=6)
    @test zero.priority == 10
end

# Runs `on_poll` while polling, e.g. to finish a job meanwhile.
mutable struct ReleasingSource <: JobSource
    jobs::Vector{Job}
    on_poll::Function
end
function SandboxedBuildkiteAgent.poll_result(source::ReleasingSource; dispatch::Bool=true)
    source.on_poll()
    return SandboxedBuildkiteAgent.JobPollResult(source.jobs, false)
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
    cleanup::Int
end
ConfigBackend() = ConfigBackend(String[], String[], 0)

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

function SandboxedBuildkiteAgent.cleanup_config!(backend::ConfigBackend)
    backend.cleanup += 1
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

    @test cleanup_backend_configs!(backends) === nothing
    @test backend.cleanup == 1
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
      "priority": 1,
      "pipeline": {"uuid": "01800000-0000-0000-0000-000000000000"},
      "build": {"uuid": "build-uuid", "number": 1, "branch": "main"},
      "agent_query_rules": ["queue=build", "os=linux"],
      "scheduled_at": "2026-10-30T12:58:21.679Z"
    }
    """))
    @test scheduled.id == "scheduled-job"
    @test scheduled.scheduled_at == "2026-10-30T12:58:21.679Z"
    @test scheduled_job_from_json(Dict("id" => "job")).scheduled_at == ""
    @test scheduled.pipeline_id == "01800000-0000-0000-0000-000000000000"
    @test scheduled.agent_query_rules == ["queue=build", "os=linux"]
    @test scheduled.priority == 1
    @test scheduled_job_from_json(Dict("id" => "job")).priority == 0

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
    brg = BuildkiteRunnerGroup("julia", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "default" => Dict("cpus" => 1),
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
    source = stacks_test_source("http://127.0.0.1:9")

    err = try
        stacks_request(source, "GET", "/stacks/julia-test-stack/scheduled-jobs";
            max_attempts=1)
        nothing
    catch err
        err
    end
    @test err isa StacksTransportError
    @test is_transient_poll_error(err)
end

@testset "Stacks HTTP request handling" begin
    @test pkgversion(HTTP).major == 1
    requests = Dict{String,Tuple{String,String,String,String}}()
    requests_lock = ReentrantLock()
    retries = Ref(0)
    handler = function (request)
        target = request.target
        lock(requests_lock) do
            requests[target] = (
                request.method,
                HTTP.header(request, "Authorization"),
                HTTP.header(request, "Content-Type"),
                String(request.body),
            )
        end
        if target == "/empty"
            return HTTP.Response(200)
        elseif target == "/rate-limit"
            return HTTP.Response(429, [
                "RateLimit-Reset" => "90",
                "RateLimit-User-Reset" => "45",
                "Retry-After" => "30",
            ])
        elseif target == "/bad-request"
            return HTTP.Response(400, "{\"detail\":\"bad request\"}")
        elseif target == "/retry"
            retries[] += 1
            return retries[] == 1 ? HTTP.Response(500) : HTTP.Response(200, "{\"ok\":true}")
        elseif target == "/timeout"
            sleep(2)
            return HTTP.Response(200)
        end
        return HTTP.Response(200, "{\"ok\":true}")
    end

    with_http_server(handler) do endpoint
        source = stacks_test_source(endpoint)
        @test stacks_request(source, "GET", "/empty") == Dict{String,Any}()
        @test stacks_request(source, "GET", "/get") == Dict("ok" => true)
        @test stacks_request(source, "PUT", "/put"; payload=Dict("job_uuids" => ["job-1"])) ==
              Dict("ok" => true)
        @test stacks_request(source, "POST", "/post"; payload=Dict("exit_status" => 0)) ==
              Dict("ok" => true)

        bad_request = try
            stacks_request(source, "GET", "/bad-request")
            nothing
        catch err
            err
        end
        @test bad_request isa BuildkiteHTTPError
        @test occursin("bad request", bad_request.message)

        rate_limit = try
            stacks_request(source, "GET", "/rate-limit")
            nothing
        catch err
            err
        end
        @test rate_limit == BuildkiteRateLimited(30.0)

        @test stacks_request(source, "GET", "/retry"; max_attempts=2,
            sleep_fn=_ -> nothing) == Dict("ok" => true)
        @test retries[] == 2

        timeout = try
            stacks_http_request("GET", "$(endpoint)/timeout", String[], ""; readtimeout=1)
            nothing
        catch err
            err
        end
        @test timeout isa StacksTransportError
    end

    @test requests["/get"] == ("GET", "Token agent-token", "", "")
    @test requests["/put"] == ("PUT", "Token agent-token", "application/json",
        "{\"job_uuids\":[\"job-1\"]}")
    @test requests["/post"] == ("POST", "Token agent-token", "application/json",
        "{\"exit_status\":0}")
end

@testset "Stacks HTTP concurrency" begin
    request_count = Ref(0)
    count_lock = ReentrantLock()
    handler = function (request)
        lock(count_lock) do
            request_count[] += 1
        end
        if request.target == "/claim"
            return HTTP.Response(200, "{\"reserved_job_uuids\":[]}")
        end
        return HTTP.Response(200, "{\"ok\":true}")
    end

    with_http_server(handler) do endpoint
        source = stacks_test_source(endpoint)
        tasks = Task[]
        for _ in 1:4
            push!(tasks, @async begin
                for _ in 1:25
                    stacks_request(source, "GET", "/poll"; max_attempts=1) == Dict("ok" => true) ||
                        error("unexpected poll response")
                end
            end)
        end
        for id in 1:20
            push!(tasks, @async begin
                stacks_request(source, "PUT", "/claim";
                    payload=Dict("job_uuids" => ["job-$(id)"]), max_attempts=1)
                stacks_request(source, "GET", "/job/$(id)"; max_attempts=1)
                stacks_request(source, "POST", "/job/$(id)/finish";
                    payload=Dict("exit_status" => 0), max_attempts=1)
            end)
        end

        for task in tasks
            @test Base.timedwait(() -> istaskdone(task), 15) == :ok
            fetch(task)
        end
    end

    @test request_count[] == 4 * 25 + 20 * 3
end

@testset "Stacks job acquisition tokens" begin
    requests = Tuple{String,String,Any}[]
    responses = Any[]
    handler = function (request)
        push!(requests, (request.target, HTTP.header(request, "Authorization"),
            JSON.parse(String(request.body))))
        return popfirst!(responses)
    end
    issued(pairs...; not_issued=String[]) = HTTP.Response(201, JSON.json(Dict(
        "job_acquisition_tokens" => [Dict("job_uuid" => id, "job_acquisition_token" => token,
            "expires_at" => "2026-11-06T12:00:00Z") for (id, token) in pairs],
        "not_issued" => not_issued)))
    error_text(f) = try
        f()
        ""
    catch err
        sprint(showerror, err)
    end

    with_http_server(handler) do endpoint
        source = stacks_test_source(endpoint)

        # The token is matched by job, whatever the order.
        push!(responses, issued("other" => "bkjat_other", "job-1" => "bkjat_one"))
        @test job_acquisition_token(source, "job-1"; lifetime=600) == "bkjat_one"
        @test requests[end] == ("/stacks/julia-test-stack/job-acquisition-tokens",
            "Token agent-token", Dict("job_uuids" => ["job-1"], "token_lifetime_seconds" => 600))
        push!(responses, issued(; not_issued=["job-1"]))
        @test job_acquisition_token(source, "job-1"; lifetime=600) === nothing
        push!(responses, issued("job-1" => "bkjat_a", "job-1" => "bkjat_b"))
        @test job_acquisition_token(source, "job-1"; lifetime=600) === nothing
        push!(responses, issued("job-1" => "bkjat_one"; not_issued=["job-1"]))
        @test job_acquisition_token(source, "job-1"; lifetime=600) === nothing
        @test_throws ArgumentError job_acquisition_token(source, "job-1"; lifetime=0)
        @test_throws ArgumentError job_acquisition_token(source, "job-1"; lifetime=3601)

        # A response that may hold a token is not quoted when it cannot be parsed.
        push!(responses, HTTP.Response(201, "{\"job_acquisition_tokens\": [\"bkjat_leak"))
        message = error_text(() -> job_acquisition_token(source, "job-1"; lifetime=600))
        @test occursin("malformed JSON", message)
        @test !occursin("bkjat_leak", message)

        # Rate limits, 5xx and transport errors are retried; the lifetime is
        # what is left of the reservation, at most an hour.
        empty!(requests)
        append!(responses, [HTTP.Response(429, ["Retry-After" => "3"]),
            HTTP.Response(503, ["Retry-After" => "7"]), issued("job-1" => "bkjat_one")])
        delays = Float64[]
        now = Ref(1000.0)
        token = mint_job_token(source, "job-1"; deadline=1000.0 + 7200,
            sleep_fn=d -> (push!(delays, d); now[] += d), now_fn=() -> now[])
        @test token == "bkjat_one"
        @test length(requests) == 3
        @test requests[1][3]["token_lifetime_seconds"] == 3600
        @test delays[1] >= 3 && delays[2] >= 7
        empty!(requests)
        push!(responses, issued("job-1" => "bkjat_one"))
        mint_job_token(source, "job-1"; deadline=time() + 120.5)
        @test requests[end][3]["token_lifetime_seconds"] in (119, 120)

        # An unchanged 4xx is not retried; a job without a token never gets one.
        empty!(requests)
        push!(responses, HTTP.Response(422, "{\"message\":\"job is not reserved\"}"))
        err = try
            mint_job_token(source, "job-1"; deadline=time() + 60, sleep_fn=_ -> error("retried"))
        catch err
            err
        end
        @test err isa JobTokenUnavailable
        @test occursin("job is not reserved", err.reason)
        @test length(requests) == 1
        push!(responses, issued(; not_issued=["job-1"]))
        @test_throws JobTokenUnavailable mint_job_token(source, "job-1"; deadline=time() + 60,
            sleep_fn=_ -> error("retried"))

        # A token that arrives after the reservation ended is not used.
        push!(responses, issued("job-1" => "bkjat_late"))
        calls = Ref(0)
        err = try
            mint_job_token(source, "job-1"; deadline=50.0,
                now_fn=() -> (calls[] += 1; calls[] == 1 ? 0.0 : 100.0))
        catch err
            err
        end
        @test err isa JobTokenUnavailable && occursin("reservation expired", err.reason)
        @test !occursin("bkjat_late", sprint(showerror, err))

        # Nor one for a job that was stopped while it was being minted.
        stopped = Ref(false)
        push!(responses, issued("job-1" => "bkjat_late"))
        err = try
            mint_job_token(source, "job-1"; deadline=time() + 60,
                cancelled=() -> (s = stopped[]; stopped[] = true; s))
        catch err
            err
        end
        @test err isa JobTokenUnavailable && occursin("stopped", err.reason)
    end

    # Transient failures are retried until the reservation ends, or the job is stopped.
    with_logger(NullLogger()) do
        with_http_server(_ -> HTTP.Response(502)) do endpoint
            source = stacks_test_source(endpoint)
            now = Ref(0.0)
            attempts = Ref(0)
            err = try
                mint_job_token(source, "job-1"; deadline=100.0, now_fn=() -> now[],
                    sleep_fn=d -> (attempts[] += 1; now[] += d))
            catch err
                err
            end
            @test err isa JobTokenUnavailable && occursin("reservation expired", err.reason)
            @test attempts[] > 3
            @test now[] <= 100.0
            stopped = Ref(false)
            err = try
                mint_job_token(source, "job-1"; deadline=time() + 60, cancelled=() -> stopped[],
                    sleep_fn=_ -> (stopped[] = true))
            catch err
                err
            end
            @test err isa JobTokenUnavailable && occursin("stopped", err.reason)
        end
    end
end

@testset "process errors do not quote credentials" begin
    S = SandboxedBuildkiteAgent
    message(f) = try
        f()
        ""
    catch err
        sprint(showerror, err)
    end
    missing_binary = addenv(`/nonexistent/buildkite-agent`, "BUILDKITE_AGENT_TOKEN" => "bkjat_secret")
    # What Julia itself reports
    @test contains(message(() -> run(missing_binary; wait=false)), "bkjat_secret")
    m = message(() -> S.run_with_secret(missing_binary, "the agent"))
    @test startswith(m, "Could not start the agent") && !contains(m, "bkjat_secret")
    m = message(() -> S.read_with_secret(`false bkjat_secret`, "guest-exec"))
    @test m == "guest-exec failed: exit code 1, signal 0"
    @test S.read_with_secret(`echo ok`, "echo") == "ok\n"
    proc = S.run_with_secret(`true`, "true")
    @test success(proc)
end

@testset "scheduler assignment" begin
    build = runner_group(; cachedir_root=mktempdir())
    test = BuildkiteRunnerGroup("tester2", Dict{String,Any}("max_slots" => 2,
        "queues" => "test",
        "default" => Dict("cpus" => 1),
        "cachedir" => mktempdir(),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64"),
    ); host=:linux)
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
    @test [a.alloc.cpus_limit for a in assignments] == [1, 1]
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

    # Higher priorities run first; equal ones keep Buildkite's oldest-first order.
    prioritized = [job(; id=string(i), priority=p) for (i, p) in enumerate([0, -1, 1, 0, 1])]
    replace_pending_jobs!(scheduler, build.name, prioritized)
    @test [j.id for j in scheduler.pending_jobs[build.name]] == ["3", "5", "1", "4", "2"]

    two_slot_group = runner_group(; cachedir_root=mktempdir(), max_slots=2)
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
        cpus=2, max_slots=2, priority=1, host=:linux)
    test = BuildkiteRunnerGroup("narrow-test", Dict{String,Any}(
        "queues" => "test",
        "default" => Dict("cpus" => 1),
        "max_slots" => 1,
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
    # Without free CPUs both groups only probe the queue, which admits nothing,
    # even once the slot frees up: that waits for the full poll `release!` triggers.
    @test scheduler.probed_sources == Set([build.name, test.name])
    @test take_assignment!(scheduler) === nothing
    release!(scheduler, running_build)
    @test take_assignment!(scheduler) === nothing
    @test @elapsed(SandboxedBuildkiteAgent.wait_for_poll(scheduler, build.name, 60)) < 30
    @test poll_jobs!(scheduler, build.name) == 1
    next_build = take_assignment!(scheduler)
    @test next_build.job.id == "build-2"
    release!(scheduler, next_build)

    # Pollers refresh independently after a probe. Until the higher-priority
    # group has listed its jobs, the lower-priority one must not take the CPUs.
    build_source = StaticJobSource([job(; id="build-1", agent_query_rules=["queue=build", "os=linux"])])
    test_source = StaticJobSource(Job[])
    scheduler = test_scheduler(no_backfill_config, [build, test],
        Dict(build.name => build_source, test.name => test_source), NullBackend())
    @test poll_jobs!(scheduler, build.name) == 1
    running_build = take_assignment!(scheduler)
    build_source.jobs = [job(; id="build-2", agent_query_rules=["queue=build", "os=linux"])]
    test_source.jobs = [job(; id="test-1", agent_query_rules=["queue=test", "os=linux"])]
    @test poll_jobs!(scheduler, build.name) == 1
    @test poll_jobs!(scheduler, test.name) == 1
    @test scheduler.probed_sources == Set([build.name, test.name])
    release!(scheduler, running_build)
    @test poll_jobs!(scheduler, test.name) == 1
    @test take_assignment!(scheduler) === nothing
    @test poll_jobs!(scheduler, build.name) == 1
    next_build = take_assignment!(scheduler)
    @test next_build.job.id == "build-2"
    release!(scheduler, next_build)

    # A failing poll leaves nothing to wait for.
    build_source = StaticJobSource([job(; id="build-3", agent_query_rules=["queue=build", "os=linux"])])
    test_source = StaticJobSource([job(; id="test-2", agent_query_rules=["queue=test", "os=linux"])])
    scheduler = test_scheduler(no_backfill_config, [build, test],
        Dict(build.name => build_source, test.name => test_source), NullBackend())
    @test poll_jobs!(scheduler, build.name) == 1
    running_build = take_assignment!(scheduler)
    @test poll_jobs!(scheduler, build.name) == 1
    release!(scheduler, running_build)
    @test poll_jobs!(scheduler, test.name) == 1
    @test take_assignment!(scheduler) === nothing
    claims = Channel{Any}(1)
    @async put!(claims, SandboxedBuildkiteAgent.take_dispatch_claims!(scheduler; block=true))
    yield()
    SandboxedBuildkiteAgent.record_poll_error!(scheduler, build.name, ErrorException("poll failed"))
    @test build.name ∉ scheduler.probed_sources
    @test isempty(scheduler.pending_jobs[build.name])
    @test timedwait(() -> isready(claims), 10) === :ok
    @test isready(claims) && only(take!(claims)).job.id == "test-2"

    # A slot released while a probe is in flight still wakes the poller.
    source = ReleasingSource([job(; id="queued", agent_query_rules=["queue=build", "os=linux"])],
        () -> nothing)
    scheduler = test_scheduler(no_backfill_config, [build],
        Dict(build.name => source), NullBackend())
    slot = lease!(scheduler.lease_pools[build.name])
    allocate!(scheduler.cpu_pool, build.default.cpus)
    alloc = Allocation(build.default.cpus)
    running_job = job(; id="running", agent_query_rules=["queue=build", "os=linux"])
    source.on_poll = () -> release!(scheduler, slot, running_job, alloc)
    @test poll_jobs!(scheduler, build.name) == 1
    @test build.name in scheduler.probed_sources
    @test @elapsed(SandboxedBuildkiteAgent.wait_for_poll(scheduler, build.name, 60)) < 30
end

@testset "multi-queue groups" begin
    brg = linux_group("linux"; max_slots=2,
        extra=Dict{String,Any}("tags" => Dict("os" => "linux", "arch" => "x86_64",
            "sandbox_capable" => "true")))
    # One Buildkite stack per queue.
    config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 8, 64, 0)
    @test SandboxedBuildkiteAgent.source_name(brg, "test") == "linux/test"
    sources = SandboxedBuildkiteAgent.default_job_sources(config, [brg])
    @test sort(collect(keys(sources))) == ["linux/build", "linux/test"]
    host = SandboxedBuildkiteAgent.get_short_hostname()
    @test sources["linux/test"].stack_key == "julia-linux-test-$(host)"
    @test sources["linux/test"].queue_key == "test"
    single = runner_group(; name="tester")
    @test SandboxedBuildkiteAgent.default_stack_key(single) == "julia-tester-$(host)"

    at(minute) = "2026-10-30T10:0$(minute):00.000Z"
    sizes(cpus, cpus_limit) = ["sched_cpus=$(cpus)", "sched_cpus_limit=$(cpus_limit)", "sched_mem_gib=8"]
    build_source = StaticJobSource([sized_job("b1"; queue="build", scheduled_at=at(2), tags=sizes(4, 16))])
    test_source = StaticJobSource([sized_job("t1"; scheduled_at=at(1), tags=sizes(4, 4)),
                                   sized_job("t2"; scheduled_at=at(3), tags=sizes(1, 1)),
                                   sized_job("untagged"; scheduled_at=at(0), tags=["sched_cpus=2"]),
                                   sized_job("renamed"; scheduled_at=at(0),
                                       tags=["sched_cpus=1", "sched_threads=4", "sched_mem_gib=8"])])
    scheduler = test_scheduler(config, [brg],
        Dict("linux/build" => build_source, "linux/test" => test_source), NullBackend())
    @test_throws ErrorException test_scheduler(config, [brg],
        Dict("linux/build" => build_source), NullBackend())
    with_logger(NullLogger()) do
        poll_jobs!(scheduler, "linux/build")
        poll_jobs!(scheduler, "linux/test")
        # Both queues share the group's two slots, oldest job first. Jobs
        # without all size tags, or with an outdated one, are failed with an
        # explanation instead of waiting.
        first = take_assignment!(scheduler)
        second = take_assignment!(scheduler)
        @test (first.job.id, first.source) == ("t1", "linux/test")
        @test (second.job.id, second.source) == ("b1", "linux/build")
        # The host has 8 CPUs, so the build may run on all of them, not 16.
        @test second.alloc == Allocation(4, 8, 8, 8, 0)
        rejected = Dict(id => (status, detail) for (id, status, detail) in test_source.finished)
        @test sort(collect(keys(rejected))) == ["renamed", "untagged"]
        @test rejected["untagged"][1] == 1
        @test occursin("- `sched_mem_gib` is missing", rejected["untagged"][2])
        @test occursin("- `sched_threads` was renamed to `sched_cpus_limit`", rejected["renamed"][2])
        @test "untagged" ∉ scheduler.claimed_jobs && "renamed" ∉ scheduler.claimed_jobs
        @test "t1" in test_source.reserved && "b1" in build_source.reserved
        @test take_assignment!(scheduler) === nothing
        @test SandboxedBuildkiteAgent.available(scheduler.cpu_pool) == 0
        # Without a free slot the sources only probe their queue.
        @test !SandboxedBuildkiteAgent.group_can_dispatch(scheduler, "linux/test")
        release!(scheduler, first)
        @test SandboxedBuildkiteAgent.group_can_dispatch(scheduler, "linux/test")
        third = take_assignment!(scheduler)
        @test (third.job.id, third.alloc.cpus) == ("t2", 1)

        # A job that keeps failing is finished through the stack it came from.
        for _ in 1:2
            SandboxedBuildkiteAgent.handle_runner_failure!(scheduler, second, ErrorException("boom"), nothing)
        end
        @test only(build_source.finished)[1] == "b1"

        snapshot = SandboxedBuildkiteAgent.scheduler_status_snapshot(scheduler)
        group = snapshot["pool"]["groups"]["linux"]
        @test group["queues"] == ["build", "test"]
        @test group["default"] == Dict("build" => "tags", "test" => "tags")
        @test group["max_slots"] == 2 && group["running"] == 2
        @test sort([p["runner_group"] for p in snapshot["pollers"]]) == ["linux/build", "linux/test"]
    end

    # A job listed by two groups of the host is failed once; a dry run fails none.
    other = linux_group("other"; queues=["test"], max_slots=1)
    untagged = sized_job("untagged"; scheduled_at=at(0))
    for dry_run in (false, true)
        first_source, second_source = StaticJobSource([untagged]), StaticJobSource([untagged])
        scheduler = test_scheduler(config, [brg, other],
            Dict("linux/build" => StaticJobSource(Job[]), "linux/test" => first_source,
                 "other" => second_source), NullBackend(); dry_run)
        with_logger(NullLogger()) do
            poll_jobs!(scheduler)
            claims = SandboxedBuildkiteAgent.take_dispatch_claims!(scheduler)
            @test length(claims) == (dry_run ? 0 : 1)
            foreach(c -> SandboxedBuildkiteAgent.reject_unsized_job!(scheduler, c.source, c.job), claims)
        end
        @test length(first_source.finished) + length(second_source.finished) == (dry_run ? 0 : 1)
        @test isempty(scheduler.claimed_jobs)
    end
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

@testset "scheduler metrics" begin
    metrics_config(metrics_dir) =
        SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 4, 16, 0, metrics_dir)
    parsed = SchedulerConfig(Dict{String,Any}("metrics_dir" => "metrics"); config_dir="/tmp")
    @test parsed.metrics_dir == "/tmp/metrics"
    @test SchedulerConfig(Dict{String,Any}()).metrics_dir === nothing

    # Rendering a synthetic snapshot: zeros for idle group/queue pairs, label escaping.
    snapshot = Dict{String,Any}(
        "pool" => Dict{String,Any}(
            "total_cpus" => 128, "free_cpus" => 100,
            "total_mem_gib" => 440, "free_mem_gib" => 400,
            "memory_braked" => true,
            "groups" => Dict{String,Any}(
                "linux" => Dict{String,Any}("queues" => ["build", "test"], "running" => 2,
                    "max_slots" => 22, "blocked" => true),
                "launch" => Dict{String,Any}("queues" => ["launch"], "running" => 0,
                    "max_slots" => 1, "blocked" => false),
            ),
        ),
        "slots" => [
            Dict{String,Any}("runner_group" => "linux", "queue" => "test"),
            Dict{String,Any}("runner_group" => "linux", "queue" => "test"),
        ],
    )
    text = SandboxedBuildkiteAgent.scheduler_metrics(snapshot; version="abc\"1")
    samples = filter(line -> !startswith(line, "#"), split(chomp(text), '\n'))
    @test samples == [
        "sba_cpus_capacity 128",
        "sba_cpus_allocated 28",
        "sba_mem_gib_capacity 440",
        "sba_mem_gib_allocated 40",
        "sba_memory_braked 1",
        "sba_jobs_running{group=\"launch\",queue=\"launch\"} 0",
        "sba_jobs_running{group=\"linux\",queue=\"build\"} 0",
        "sba_jobs_running{group=\"linux\",queue=\"test\"} 2",
        "sba_slots_used{group=\"launch\"} 0",
        "sba_slots_used{group=\"linux\"} 2",
        "sba_slots_quarantined{group=\"launch\"} 0",
        "sba_slots_quarantined{group=\"linux\"} 0",
        "sba_slots_max{group=\"launch\"} 1",
        "sba_slots_max{group=\"linux\"} 22",
        "sba_group_blocked{group=\"launch\"} 0",
        "sba_group_blocked{group=\"linux\"} 1",
        "sba_io_accounting_stuck 0",
        "sba_scheduler_info{version=\"abc\\\"1\"} 1",
    ]
    @test count(startswith("# TYPE "), split(text, '\n')) == 12
    # A failed io_accounting rollback shows.
    snapshot["io_accounting_stuck"] = true
    @test occursin("\nsba_io_accounting_stuck 1\n", SandboxedBuildkiteAgent.scheduler_metrics(snapshot))
    delete!(snapshot, "io_accounting_stuck")
    @test all(endswith(" gauge"), filter(startswith("# TYPE "), split(text, '\n')))

    # The live scheduler writes the file from the status heartbeat, atomically.
    metrics_dir = mktempdir()
    config = metrics_config(metrics_dir)
    path = joinpath(metrics_dir, "sandboxed_buildkite_agent.prom")
    brg = runner_group(; cachedir_root=mktempdir())
    scheduler = test_scheduler(config, [brg], StaticJobSource([job(; id="metrics-job")]),
        NullBackend())
    SandboxedBuildkiteAgent.write_scheduler_status_best_effort!(scheduler)
    @test isfile(path) && isfile(scheduler_status_path(config))
    @test contains(read(path, String), "sba_jobs_running{group=\"tester\",queue=\"build\"} 0\n")
    @test contains(read(path, String), "sba_scheduler_info{version=\"")
    poll_jobs!(scheduler)
    assignment = take_assignment!(scheduler)
    SandboxedBuildkiteAgent.write_scheduler_status_best_effort!(scheduler)
    text = read(path, String)
    @test contains(text, "\nsba_cpus_allocated 1\n")
    @test contains(text, "sba_jobs_running{group=\"tester\",queue=\"build\"} 1\n")
    @test contains(text, "sba_slots_used{group=\"tester\"} 1\n")
    @test readdir(metrics_dir) == ["sandboxed_buildkite_agent.prom"]
    release!(scheduler, assignment)

    # A failing write is logged, leaves no temporary file and keeps the status file.
    blocked_dir = joinpath(mktempdir(), "not-a-dir")
    write(blocked_dir, "")
    blocked = test_scheduler(metrics_config(blocked_dir), [brg], StaticJobSource(Job[]),
        NullBackend())
    @test_logs (:warn, "Unable to write scheduler metrics") match_mode=:any begin
        SandboxedBuildkiteAgent.write_scheduler_status_best_effort!(blocked)
    end
    @test isfile(scheduler_status_path(blocked.config))
    @test readdir(dirname(blocked_dir)) == ["not-a-dir"]

    # Unset `metrics_dir` and dry runs write nothing.
    unset = test_scheduler(metrics_config(nothing), [brg], StaticJobSource(Job[]), NullBackend())
    @test SandboxedBuildkiteAgent.write_scheduler_metrics!(unset) === nothing
    dry_dir = mktempdir()
    dry = test_scheduler(metrics_config(dry_dir), [brg], StaticJobSource(Job[]), NullBackend();
        dry_run=true)
    SandboxedBuildkiteAgent.write_scheduler_status_best_effort!(dry)
    @test isempty(readdir(dry_dir))

    # Clean shutdown removes the file, and a late heartbeat does not bring it back.
    SandboxedBuildkiteAgent.cleanup_scheduler!(scheduler)
    @test !ispath(path)
    SandboxedBuildkiteAgent.write_scheduler_status_best_effort!(scheduler)
    @test !ispath(path)
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

struct UnavailableBackend <: PlatformBackend end

SandboxedBuildkiteAgent.backend_available(::UnavailableBackend, brg::BuildkiteRunnerGroup) = false

@testset "scheduler backend registry" begin
    linux = runner_group(;
        name="linux",
        cachedir_root=mktempdir(),
        backend=BACKEND_LINUX_SANDBOX,
        host=:linux,
    )
    windows = BuildkiteRunnerGroup("windows", Dict{String,Any}("max_slots" => 2,
        "queues" => "test",
        "backend" => BACKEND_KVM,
        "guest" => "windows",
        "cachedir" => mktempdir(),
        "default" => Dict("cpus" => 2, "mem_gib" => 8),
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

struct HangingReapBackend <: PlatformBackend
    reaping::Channel{Nothing}
    release::Base.Event
end

struct HangingReapHandle
    backend::HangingReapBackend
end

prepare(backend::HangingReapBackend, slot::Slot, job::Job, plan::CachePlan,
        alloc::Allocation) =
    HangingReapHandle(backend)

run_job(::HangingReapHandle, ::Union{Nothing,Float64}=nothing) = 0

function reap(handle::HangingReapHandle)
    put!(handle.backend.reaping, nothing)
    wait(handle.backend.release)
end

@testset "scheduler flags leases overdue past their deadline" begin
    config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0)
    brg = runner_group(; cachedir_root=mktempdir())
    backend = HangingReapBackend(Channel{Nothing}(1), Base.Event())
    scheduler = test_scheduler(config, [brg], StaticJobSource([job(; id="wedged-job")]), backend)
    @test poll_jobs!(scheduler) == 1
    runner = @async with_logger(NullLogger()) do
        run_available_assignment!(scheduler)
    end
    try
        @test timedwait(() -> isready(backend.reaping), 60) === :ok

        deadline = only(values(scheduler.slot_status))["deadline_at"]
        grace = SandboxedBuildkiteAgent.LEASE_OVERDUE_GRACE_SECONDS
        flag_overdue_leases!(now) = SandboxedBuildkiteAgent.flag_overdue_leases!(scheduler; now)
        @test (@test_logs min_level=Logging.Warn flag_overdue_leases!(deadline + grace)) == 0
        @test (@test_logs (:error, "Lease is overdue: still held long after its assignment deadline") flag_overdue_leases!(deadline + grace + 1)) == 1
        @test (@test_logs min_level=Logging.Warn flag_overdue_leases!(deadline + grace + 2)) == 0

        SandboxedBuildkiteAgent.write_scheduler_status!(scheduler)
        snapshot = read_scheduler_status_snapshot(config)
        @test snapshot["overdue_leases"] == 1
        slot_status = only(snapshot["slots"])
        @test slot_status["state"] == "finishing"
        @test slot_status["overdue"]

        io = IOBuffer()
        SandboxedBuildkiteAgent.print_scheduler_status_human(io,
            Dict{String,Any}("installed" => true, "running" => true, "state" => "active"),
            nothing, scheduler_status_path(config), snapshot)
        output = String(take!(io))
        @test occursin("WARNING: 1 lease(s) held over 60 min past the assignment deadline", output)
        @test occursin(r"finishing .* job=wedged-job deadline=\S+ OVERDUE", output)
    finally
        notify(backend.release)
    end
    @test timedwait(() -> istaskdone(runner), 60) === :ok
    @test fetch(runner)
    SandboxedBuildkiteAgent.write_scheduler_status!(scheduler)
    snapshot = read_scheduler_status_snapshot(config)
    @test snapshot["overdue_leases"] == 0
    @test isempty(snapshot["slots"])
end

@testset "scheduler blocks unavailable backends before reservation" begin
    brg = runner_group(;
        cachedir_root=mktempdir(),
        backend=BACKEND_LINUX_SANDBOX,
        host=:linux,
    )
    source = StaticJobSource([job(; id="blocked-job")])
    scheduler = test_scheduler(test_scheduler_config(), [brg], source,
        Dict(BACKEND_LINUX_SANDBOX => UnavailableBackend()))

    @test poll_jobs!(scheduler, brg.name) == 1
    @test !run_available_assignment!(scheduler)
    @test isempty(source.reserved)
    @test isempty(source.finished)

    status = SandboxedBuildkiteAgent.scheduler_status_snapshot(scheduler)
    group_status = status["pool"]["groups"][brg.name]
    @test group_status["blocked"]
    @test !group_status["backend_available"]
end

@testset "scheduler finishes failed reserved jobs" begin
    S = SandboxedBuildkiteAgent
    brg = runner_group(; cachedir_root=mktempdir())
    source = StaticJobSource([job(; id="prepare-failure")])
    scheduler = test_scheduler(test_scheduler_config(), [brg], source, FailingPrepareBackend())
    replace_pending_jobs!(scheduler, poll_jobs(source))

    # The first failure does not finish the job, which would fail it for good:
    # this host skips it until its reservation has expired and another host
    # (or this one) may take it.
    before = time()
    with_logger(NullLogger()) do
        @test run_available_assignment!(scheduler)
    end
    @test isempty(source.finished)
    @test isempty(scheduler.claimed_jobs)
    @test all(running(pool) == 0 for pool in values(scheduler.lease_pools))
    @test scheduler.job_failures["prepare-failure"] == 1
    @test scheduler.quarantined_jobs["prepare-failure"] >= before + scheduler.config.reservation_expiry_seconds
    replace_pending_jobs!(scheduler, poll_jobs(source))
    @test isempty(scheduler.pending_jobs[brg.name])
    snapshot = S.scheduler_status_snapshot(scheduler)
    @test haskey(snapshot["quarantined_jobs"], "prepare-failure")
    @test snapshot["job_failures"]["prepare-failure"] == 1
    status_io = IOBuffer()
    S.print_scheduler_status_human(status_io, Dict("installed" => true, "running" => true), nothing,
        "/tmp/scheduler-status.json", JSON.parse(JSON.json(snapshot)))
    @test occursin(r"Quarantined jobs.*\n  prepare-failure: for \d+\.\ds failures=1", String(take!(status_io)))

    # Records do not outlive their use when the job never shows up again
    # (another host finished it): an expired quarantine leaves the status, and
    # the failure is forgotten after `JOB_FAILURE_MEMORY_SECONDS`.
    let records = test_scheduler(test_scheduler_config(), [brg], StaticJobSource(Job[]), NullBackend())
        now = time()
        records.job_failures["gone"] = 1
        records.job_failed_at["gone"] = now - S.JOB_FAILURE_MEMORY_SECONDS - 1
        records.quarantined_jobs["gone"] = now - 1
        records.job_failures["recent"] = 1
        records.job_failed_at["recent"] = now - 60
        records.quarantined_jobs["recent"] = now - 1
        snapshot = S.scheduler_status_snapshot(records)
        @test isempty(snapshot["quarantined_jobs"])
        @test snapshot["job_failures"] == Dict("recent" => 1)
        replace_pending_jobs!(records, Job[])
        @test !haskey(records.job_failures, "gone") && !haskey(records.job_failed_at, "gone")
        @test records.job_failures["recent"] == 1
    end

    # Once the reservation has expired, the job is taken again; failing a
    # second time finishes it with -1 and a detail saying where and why.
    scheduler.quarantined_jobs["prepare-failure"] = time() - 1
    empty!(source.reserved)
    replace_pending_jobs!(scheduler, poll_jobs(source))
    with_logger(NullLogger()) do
        @test run_available_assignment!(scheduler)
    end
    finished_job, exit_status, detail = only(source.finished)
    @test finished_job == "prepare-failure"
    @test exit_status == -1
    @test occursin("on $(gethostname()) failed to run this job 2 times", detail)
    @test occursin("prepare failed", detail)
    @test !haskey(scheduler.job_failures, "prepare-failure")
    @test all(running(pool) == 0 for pool in values(scheduler.lease_pools))

    # When finishing fails, the job is quarantined with backoff instead.
    retry_source = StaticJobSource([job(; id="finish-failure")])
    push!(retry_source.finish_failures, "finish-failure")
    retry_scheduler = test_scheduler(test_scheduler_config(), [brg], retry_source, FailingPrepareBackend())
    retry_scheduler.job_failures["finish-failure"] = 1
    replace_pending_jobs!(retry_scheduler, poll_jobs(retry_source))
    with_logger(NullLogger()) do
        @test run_available_assignment!(retry_scheduler)
    end
    @test isempty(retry_scheduler.claimed_jobs)
    @test all(running(pool) == 0 for pool in values(retry_scheduler.lease_pools))
    @test haskey(retry_scheduler.quarantined_jobs, "finish-failure")
    @test retry_scheduler.job_failures["finish-failure"] == 2

    empty!(retry_source.reserved)
    replace_pending_jobs!(retry_scheduler, poll_jobs(retry_source))
    @test isempty(retry_scheduler.pending_jobs[brg.name])

    retry_scheduler.quarantined_jobs["finish-failure"] = time() - 1
    replace_pending_jobs!(retry_scheduler, poll_jobs(retry_source))
    assignment = take_assignment!(retry_scheduler)
    @test assignment.job.id == "finish-failure"
    release!(retry_scheduler, assignment)
end

# A backend whose jobs outlive their teardown: `reap` reports failure until it
# has been called `confirm_after` times. With `fail_run`, the job's runner
# fails instead of the agent ending the job.
mutable struct StuckBackend <: PlatformBackend
    confirm_after::Int
    reaps::Int
    fail_run::Bool
end
StuckBackend(confirm_after) = StuckBackend(confirm_after, 0, false)

struct StuckHandle
    backend::StuckBackend
end

prepare(backend::StuckBackend, slot::Slot, job::Job, plan::CachePlan, alloc::Allocation) =
    StuckHandle(backend)
run_job(handle::StuckHandle, ::Union{Nothing,Float64}=nothing) =
    handle.backend.fail_run ? error("guest agent timed out") : 0
function reap(handle::StuckHandle)
    handle.backend.reaps += 1
    return handle.backend.reaps > handle.backend.confirm_after
end

@testset "scheduler holds slots whose teardown failed" begin
    S = SandboxedBuildkiteAgent
    linux = runner_group(; cachedir_root=mktempdir(), cpus=2)
    windows = BuildkiteRunnerGroup("windows", Dict{String,Any}("max_slots" => 1,
        "queues" => "build", "backend" => BACKEND_KVM, "guest" => "windows",
        "cachedir" => mktempdir(), "default" => Dict("cpus" => 2, "mem_gib" => 8),
        "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64")); host=:linux)
    quarantined(scheduler) = [slot for (slot, job) in scheduler.active_jobs if job.quarantined_since !== nothing]
    function start_stuck(brg, backend, id)
        source = StaticJobSource([job(; id)])
        scheduler = test_scheduler(test_scheduler_config(), [brg], source, backend)
        replace_pending_jobs!(scheduler, poll_jobs(source))
        assignment = take_assignment!(scheduler)
        runner = with_logger(NullLogger()) do
            @async S.run_assignment!(scheduler, assignment)
        end
        @test timedwait(() -> !isempty(quarantined(scheduler)), 10.0) == :ok
        return scheduler, assignment, runner
    end
    retry = S.TEARDOWN_RETRY_SECONDS[], S.TEARDOWN_RETRY_STOPPING_SECONDS[]
    S.TEARDOWN_RETRY_SECONDS[] = 0.5
    S.TEARDOWN_RETRY_STOPPING_SECONDS[] = 0.05
    try
        # Held: the slot stays leased and its CPUs (and a guest's memory)
        # charged, and a stop waits for it.
        for (brg, mem) in ((linux, 0), (windows, SandboxedBuildkiteAgent.kvm_reserved_mem_gib(8)))
            backend = StuckBackend(2)
            scheduler, assignment, runner = start_stuck(brg, backend, "stuck")
            cpus, mem_total = scheduler.cpu_pool.total, scheduler.mem_pool.total
            @test quarantined(scheduler) == [assignment.slot.name]
            @test available(scheduler.cpu_pool) == cpus - 2
            @test available(scheduler.mem_pool) == mem_total - mem
            @test running(scheduler.lease_pools[brg.name]) == 1
            @test S.running_assignments(scheduler) == 1
            snapshot = S.scheduler_status_snapshot(scheduler)
            @test only(snapshot["slots"])["state"] == "quarantined"
            @test snapshot["pool"]["groups"][brg.name]["quarantined"] == 1
            @test occursin("sba_slots_quarantined{group=\"$(brg.name)\"} 1", S.scheduler_metrics(snapshot))
            # Released once a retried teardown succeeds.
            wait(runner)
            @test backend.reaps == 3
            @test isempty(scheduler.active_jobs)
            @test available(scheduler.cpu_pool) == cpus
            @test available(scheduler.mem_pool) == mem_total
            @test running(scheduler.lease_pools[brg.name]) == 0
            @test isempty(S.scheduler_status_snapshot(scheduler)["slots"])
        end

        # A stop reaches a held job. One whose runner failed (the agent may
        # still run, as in a guest that could not be destroyed) is reported
        # for a retry; one that the agent ended only holds its slot. Neither
        # makes the report complete, and the slot stays held until its
        # teardown succeeds.
        for fail_run in (true, false)
            backend = StuckBackend(typemax(Int), 0, fail_run)
            scheduler, assignment, runner = start_stuck(windows, backend, "stuck-forever")
            with_logger(NullLogger()) do
                S.stop_scheduler!(scheduler; grace=0.2, kill_grace=0.2, sleep_fn=t -> sleep(0.05))
            end
            report = JSON.parsefile(S.stop_report_path(scheduler.config))
            @test !report["complete"]
            if fail_run
                entry = only(report["jobs"])
                @test entry["id"] == "stuck-forever" && entry["retry"] == "once_failed" && !entry["ended"]
                @test isempty(report["held_slots"])
            else
                @test isempty(report["jobs"])
                @test report["held_slots"] == [assignment.slot.name]
            end
            @test running(scheduler.lease_pools[windows.name]) == 1
            backend.confirm_after = 0
            @test timedwait(() -> istaskdone(runner), 10.0) == :ok
            @test running(scheduler.lease_pools[windows.name]) == 0
            @test isempty(scheduler.active_jobs)
        end

        # A stop cuts even a long teardown backoff short.
        S.TEARDOWN_RETRY_SECONDS[] = 600.0
        S.TEARDOWN_RETRY_STOPPING_SECONDS[] = 1.0
        backend = StuckBackend(1)
        scheduler, assignment, runner = start_stuck(linux, backend, "backoff")
        sleep(0.5)
        stopping = time()
        stopper = with_logger(NullLogger()) do
            @async S.stop_scheduler!(scheduler; grace=60, kill_grace=60, sleep_fn=t -> sleep(0.05))
        end
        @test timedwait(() -> istaskdone(runner), 30.0) == :ok
        @test time() - stopping < 10
        wait(stopper)
        @test backend.reaps == 2
        @test JSON.parsefile(S.stop_report_path(scheduler.config))["complete"]
    finally
        S.TEARDOWN_RETRY_SECONDS[], S.TEARDOWN_RETRY_STOPPING_SECONDS[] = retry
    end
end

@testset "KVM bridge STP detection" begin
    sysfs = mktempdir()
    # No such bridge (or not a Linux host): nothing to warn about.
    @test !kvm_bridge_stp_enabled("virbr0"; sysfs)
    mkpath(joinpath(sysfs, "virbr0", "bridge"))
    Base.write(joinpath(sysfs, "virbr0", "bridge", "stp_state"), "1\n")
    @test kvm_bridge_stp_enabled("virbr0"; sysfs)
    Base.write(joinpath(sysfs, "virbr0", "bridge", "stp_state"), "0\n")
    @test !kvm_bridge_stp_enabled("virbr0"; sysfs)
end

@testset "KVM backend planning" begin
    secrets = mktempdir()
    token_path = joinpath(secrets, "buildkite-agent-token")
    Base.write(token_path, "secret-token\n")
    chmod(token_path, 0o600)

    brg = BuildkiteRunnerGroup("freebsd-x86_64", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "freebsd",
        "cachedir" => mktempdir(),
        "tempdir" => mktempdir(),
        "secrets_dir" => secrets,
        "default" => Dict("cpus" => 4, "mem_gib" => 16),
        "tags" => Dict{String,String}("os" => "freebsd", "arch" => "x86_64"),
    ); host=:linux, total_mem_gib=512)
    slot = Slot(brg, 2)
    plan = cache_plan(slot, job(; id="kvm-job"), :untrusted)
    backend = KVMBackend(mktempdir(), [brg])
    kvm_config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 16, 512, 0)
    alloc = SandboxedBuildkiteAgent.job_allocation(brg, job(; id="kvm-job"), kvm_config)
    # The guest reserves the host overhead (2 GiB) on top of its RAM.
    @test alloc == Allocation(4, 4, 16, 16, 18)

    # The orphan sweep matches domains by hostname-qualified prefix and by the
    # cache overlay basename inside the scheduler's roots.
    @test backend.groups == ["freebsd-x86_64"]
    @test only(backend.domain_prefixes) == string("freebsd-x86_64-", SandboxedBuildkiteAgent.get_short_hostname(), ".")
    @test backend.scratch_roots == [joinpath(tempdir(brg), "kvm-agent-scratch")]
    @test backend.cache_roots == [SandboxedBuildkiteAgent.cachedir(brg)]
    @test basename(kvm_cache_overlay_path(plan)) == "cache.qcow2-1"
    # The Makefiles produce <arch>/worker.qcow2 (+ the "-1" cache disk) under
    # platforms/<guest>-kvm/buildkite-worker/images/.
    @test endswith(kvm_pristine_os_image(brg), joinpath("platforms", "freebsd-kvm", "buildkite-worker", "images", "x86_64", "worker.qcow2"))
    @test kvm_pristine_cache_image(brg) == string(kvm_pristine_os_image(brg), "-1")

    image_dir = mktempdir()
    legacy_image = joinpath(image_dir, "worker.qcow2")
    staged_image = joinpath(image_dir, "x86_64", "worker.qcow2")
    @test kvm_pristine_os_image(brg, image_dir) == staged_image
    touch(legacy_image)
    # Unqualified images from the retired layout must not be selected.
    @test kvm_pristine_os_image(brg, image_dir) == staged_image


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
    @test vars["cpu_shares"] == "400"

    # vCPUs follow the CPU limit and RAM the memory limit, not the CPU request.
    decoupled = BuildkiteRunnerGroup("freebsd-decoupled", Dict{String,Any}("max_slots" => 2,
        "backend" => "kvm", "guest" => "freebsd", "queues" => "test",
        "tags" => Dict{String,String}("os" => "freebsd", "arch" => "x86_64"),
    ); host=:linux, total_mem_gib=512)
    decoupled_alloc = SandboxedBuildkiteAgent.job_allocation(decoupled, job(; id="kvm-job",
        agent_query_rules=["queue=test", "sched_cpus=4", "sched_cpus_limit=8", "sched_mem_gib=32"]),
        kvm_config)
    @test decoupled_alloc == Allocation(4, 8, 32, 32, 32 + 2)
    decoupled_vars = kvm_template_vars(KVMHandle(backend, slot, job(; id="kvm-job"), plan,
        decoupled_alloc, slot.name, kvm_xml_path(slot),
        kvm_os_overlay_path(slot), kvm_cache_overlay_path(plan), handle.log_path))
    @test decoupled_vars["num_cpus"] == "8"
    @test decoupled_vars["memory_kb"] == string(32 * 1024 * 1024)
    @test decoupled_vars["cpu_shares"] == "400"
    # A memory request below the limit: the guest gets, and reserves, the limit.
    split_alloc = SandboxedBuildkiteAgent.job_allocation(decoupled, job(; id="kvm-split",
        agent_query_rules=["queue=test", "sched_cpus=4", "sched_mem_gib=16", "sched_mem_limit_gib=32"]),
        kvm_config)
    @test split_alloc == Allocation(4, 4, 16, 32, 32 + 2)
    split_vars = kvm_template_vars(KVMHandle(backend, slot, job(; id="kvm-split"), plan,
        split_alloc, slot.name, kvm_xml_path(slot),
        kvm_os_overlay_path(slot), kvm_cache_overlay_path(plan), handle.log_path))
    @test split_vars["memory_kb"] == string(32 * 1024 * 1024)
    @test SandboxedBuildkiteAgent.kvm_reserved_mem_gib(24) == 26
    for template in ("windows-kvm/buildkite-worker/kvm_machine.xml.template",
                     "freebsd-kvm/buildkite-worker/kvm_machine.xml.template",
                     "freebsd-kvm/buildkite-worker/kvm_machine.aarch64.xml.template")
        @test occursin("<shares>\${cpu_shares}</shares>",
            read(joinpath(dirname(@__DIR__), "platforms", template), String))
    end
    @test vars["cache_disk_path"] == kvm_cache_overlay_path(plan)
    # The serial console log must be a separate file next to the job log,
    # where `sba logs --serial` looks for it.
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
    # The guest is told its grant: its vCPUs and its RAM.
    for var in ("SBA_CPUS=4", "SBA_CPUS_LIMIT=4", "SBA_MEM_GIB=16", "SBA_MEM_LIMIT_GIB=16")
        @test var in payload["arguments"]["env"]
    end
    @test !any(env -> startswith(env, "JULIA_CPU_THREADS=") || startswith(env, "OMP_THREAD_LIMIT="),
        payload["arguments"]["env"])
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

    windows_brg = BuildkiteRunnerGroup("windows", Dict{String,Any}("max_slots" => 2,
        "queues" => "build",
        "backend" => BACKEND_KVM,
        "guest" => "windows",
        "cachedir" => mktempdir(),
        "tempdir" => mktempdir(),
        "secrets_dir" => secrets,
        "default" => Dict("cpus" => 4, "mem_gib" => 16),
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
    ); host=:linux, total_mem_gib=512)
    windows_slot = Slot(windows_brg, 1)
    windows_plan = cache_plan(windows_slot, job(; id="windows-job"), :trusted)
    windows_handle = KVMHandle(
        backend,
        windows_slot,
        job(; id="windows-job"),
        windows_plan,
        Allocation(4),
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
    @test "SBA_CPUS_LIMIT=4" in windows_payload["arguments"]["env"]
    @test !any(startswith("SBA_MEM"), windows_payload["arguments"]["env"])

    arm_brg = BuildkiteRunnerGroup("freebsd-aarch64", Dict{String,Any}("max_slots" => 2,
        "queues" => "test", "backend" => BACKEND_KVM, "guest" => "freebsd",
        "cachedir" => mktempdir(), "tempdir" => mktempdir(), "secrets_dir" => secrets,
        "default" => Dict("cpus" => 4, "mem_gib" => 16), "tags" => Dict("os" => "freebsd", "arch" => "aarch64"),
    ); host=:linux, total_mem_gib=512)
    arm_slot = Slot(arm_brg, 1)
    arm_handle = KVMHandle(backend, arm_slot, job(), plan, alloc, arm_slot.name,
        kvm_xml_path(arm_slot), kvm_os_overlay_path(arm_slot),
        kvm_cache_overlay_path(plan), joinpath(backend.logdir, "arm.log"))
    arm_vars = kvm_template_vars(arm_handle)
    @test haskey(arm_vars, "firmware")
    @test kvm_pristine_os_image(arm_brg, image_dir) == joinpath(image_dir, "aarch64", "worker.qcow2")
    @test kvm_xml_template(arm_brg) != kvm_xml_template(brg)
    arm_xml = SandboxedBuildkiteAgent.render_template(kvm_xml_template(arm_brg), arm_vars)
    @test occursin("arch='aarch64' machine='virt'", arm_xml)
    @test occursin("type='pflash' stateless='yes'", arm_xml)
    @test occursin("name='pl011'", arm_xml)
    @test !occursin("isa-serial", arm_xml)
    @test !occursin("ps2", arm_xml)
    @test !occursin("nvram", arm_xml)
    @test_throws ErrorException SandboxedBuildkiteAgent.render_template(
        kvm_xml_template(arm_brg), Dict("agent_hostname" => "incomplete"))

    # Every placeholder in the XML templates must be provided by the scheduler.
    for (template_brg, template_vars) in ((brg, vars), (arm_brg, arm_vars), (windows_brg, kvm_template_vars(windows_handle)))
        template = read(kvm_xml_template(template_brg), String)
        for m in eachmatch(r"\$\{(\w+)\}", template)
            @test haskey(template_vars, m.captures[1])
        end
        # The serial console goes to the per-job file `sba logs --serial` reads,
        # and the guest agent channel guest-exec relies on is present.
        @test occursin("<serial type='file'>", template)
        @test occursin("org.qemu.guest_agent.0", template)
    end

    # A stateful stand-in for virsh: `list` prints the domains in `running`,
    # `shutdown` stops a cooperative guest (and is recorded), and `destroy` is
    # recorded and stops any guest.  The stubborn domain ignores shutdown
    # requests, like a guest whose agent is gone and that ignores ACPI.
    fake_virsh_root = mktempdir()
    fakebin = joinpath(fake_virsh_root, "bin")
    mkpath(fakebin)
    fake_virsh = joinpath(fakebin, "virsh")
    running_path = joinpath(fake_virsh_root, "running")
    shutdown_path = joinpath(fake_virsh_root, "shutdown")
    barrier_path = joinpath(fake_virsh_root, "shutdown-barrier")
    destroyed_path = joinpath(fake_virsh_root, "destroyed")
    detached_path = joinpath(fake_virsh_root, "cache-detached")
    agent_stop_ok_path = joinpath(fake_virsh_root, "agent-stop-ok")
    agent_stops_path = joinpath(fake_virsh_root, "agent-stops")
    agent_stop_exit_path = joinpath(fake_virsh_root, "agent-stop-exit")
    status_fails_path = joinpath(fake_virsh_root, "status-fails")
    exec_lost_path = joinpath(fake_virsh_root, "exec-lost")
    current_domain = string(only(kvm_group_prefixes([brg.name])), "1")
    renamed_domain = "renamed-runner-oldhost.1"
    foreign_domain = "foreign-domain"
    stubborn_domain = string(only(kvm_group_prefixes([brg.name])), "2")
    rejected_domain = string(only(kvm_group_prefixes([brg.name])), "3")
    wedged_domain = string(only(kvm_group_prefixes([brg.name])), "4")
    renamed_disk = joinpath(tempdir(brg), "kvm-agent-scratch", "renamed", "renamed.qcow2")
    foreign_disk = joinpath(mktempdir(), "foreign.qcow2")
    Base.write(fake_virsh, """
        #!/bin/sh
        cmd="\$3"
        domain="\$4"
        stop_domain() {
            while ! mkdir "$(running_path).lock" 2>/dev/null; do sleep 0.01; done
            grep -v -x -F "\$1" "$(running_path)" > "$(running_path).tmp" || true
            mv "$(running_path).tmp" "$(running_path)"
            rmdir "$(running_path).lock"
        }
        if [ "\$cmd" = "list" ]; then
            cat "$(running_path)"
        elif [ "\$cmd" = "domblklist" ]; then
            printf '%s\\n' "Type Device Target Source"
            printf '%s\\n' "--------------------------------"
            case "\$domain" in
                "$(renamed_domain)") printf '%s\\n' "file disk vda $(renamed_disk)" ;;
                "$(foreign_domain)") printf '%s\\n' "file disk vda $(foreign_disk)" ;;
                *) printf '%s\\n' "file disk vda -" ;;
            esac
        elif [ "\$cmd" = "shutdown" ]; then
            printf '%s\\n' "\$domain \$5 \$6" >> "$(shutdown_path)"
            if [ -f "$(barrier_path)" ]; then
                attempts=0
                until [ "\$(wc -l < "$(shutdown_path)")" -ge 2 ]; do
                    attempts=\$((attempts + 1))
                    [ "\$attempts" -lt 500 ] || exit 1
                    sleep 0.01
                done
            fi
            [ "\$domain" != "$(rejected_domain)" ] || exit 1
            [ "\$domain" = "$(stubborn_domain)" ] || [ "\$domain" = "$(wedged_domain)" ] ||
                stop_domain "\$domain"
        elif [ "\$cmd" = "qemu-agent-command" ]; then
            case "\$5" in
                *guest-file-open*)
                    [ -f "$(detached_path)" ] || exit 1
                    printf '{"return":1}' ;;
                *guest-file-read*)
                    printf '{"return":{"buf-b64":"%s","eof":true}}' "\$(base64 < "$(detached_path)" | tr -d '\n')" ;;
                *guest-file-close*) printf '{"return":{}}' ;;
                *guest-exec-status*)
                    [ ! -f "$(status_fails_path)" ] || exit 1
                    code="\$(cat "$(agent_stop_exit_path)" 2>/dev/null || echo running)"
                    if [ "\$code" = running ]; then
                        printf '{"return":{"exited":false}}'
                    else
                        printf '{"return":{"exited":true,"exitcode":%s}}' "\$code"
                    fi ;;
                *guest-exec*)
                    [ -f "$(agent_stop_ok_path)" ] || exit 1
                    printf '%s %s\\n' "\$domain" "\$6 \$7" >> "$(agent_stops_path)"
                    [ ! -f "$(exec_lost_path)" ] || exit 1
                    printf '{"return":{"pid":1}}' ;;
                *) exit 2 ;;
            esac
        elif [ "\$cmd" = "destroy" ]; then
            printf '%s\\n' "\$domain" >> "$(destroyed_path)"
            [ "\$domain" != "$(wedged_domain)" ] || exit 1
            stop_domain "\$domain"
        else
            exit 2
        fi
        """)
    chmod(fake_virsh, 0o755)
    recorded(path) = isfile(path) ? split(strip(read(path, String)), '\n') : String[]

    # Startup cleanup shuts stale scheduler domains down cleanly and leaves
    # unrelated domains alone. Both shutdown requests must arrive before either
    # guest stops, so a serial sweep would fall back to destroy and fail the test.
    Base.write(running_path, join([current_domain, renamed_domain, foreign_domain], '\n') * "\n")
    touch(barrier_path)
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        cleanup(backend)
    end
    rm(barrier_path)
    shut_down = recorded(shutdown_path)
    @test "$(current_domain) --mode agent,acpi" in shut_down
    @test "$(renamed_domain) --mode agent,acpi" in shut_down
    @test !any(startswith(foreign_domain), shut_down)
    @test isempty(recorded(destroyed_path))
    @test recorded(running_path) == [foreign_domain]

    # Job teardown: a cooperative guest is never destroyed, a guest that ignores
    # the request is destroyed once the shutdown budget is spent, a rejected
    # request falls back immediately, and a domain
    # that already stopped triggers neither.  Every path removes the scratch
    # files.
    reap_handle(domain, guest_slot=windows_slot) = KVMHandle(
        backend,
        guest_slot,
        job(; id="reap-job"),
        windows_plan,
        Allocation(4),
        domain,
        joinpath(mktempdir(), "$(domain).xml"),
        joinpath(mktempdir(), "$(domain).qcow2"),
        kvm_cache_overlay_path(windows_plan),
        joinpath(backend.logdir, domain, "reap-job.log"),
    )
    for (domain, expect_destroyed) in ((current_domain, false), (stubborn_domain, true), (rejected_domain, true), ("already-stopped", false))
        rm(shutdown_path; force=true)
        rm(destroyed_path; force=true)
        Base.write(running_path, join([current_domain, stubborn_domain, rejected_domain], '\n') * "\n")
        handle = reap_handle(domain)
        touch(handle.xml_path)
        touch(handle.os_overlay)
        withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
            @test reap(handle; shutdown_timeout=0.5) === true
        end
        @test (domain == "already-stopped") == isempty(recorded(shutdown_path))
        @test (domain in recorded(destroyed_path)) == expect_destroyed
        @test domain ∉ recorded(running_path)
        @test !isfile(handle.xml_path)
        @test !isfile(handle.os_overlay)
    end

    # A guest that survives `virsh destroy` keeps its disks, and its teardown
    # is reported as failed so the scheduler holds the slot.
    Base.write(running_path, wedged_domain * "\n")
    rm(destroyed_path; force=true)
    wedged = reap_handle(wedged_domain)
    touch(wedged.xml_path)
    touch(wedged.os_overlay)
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        with_logger(NullLogger()) do
            @test reap(wedged; shutdown_timeout=0.5, destroy_timeout=0.5) === false
        end
    end
    @test wedged_domain in recorded(destroyed_path)
    @test isfile(wedged.xml_path) && isfile(wedged.os_overlay)
    # Killing it as part of a stop is unconfirmed, not failed.
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        with_logger(NullLogger()) do
            @test SandboxedBuildkiteAgent.stop_job(wedged; force=true, shutdown_timeout=0.5,
                destroy_timeout=0.5) == :unconfirmed
        end
    end
    # Once it is gone, a retried teardown succeeds and removes them.
    Base.write(running_path, "")
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        @test reap(wedged; shutdown_timeout=0.5, destroy_timeout=0.5) === true
    end
    @test !isfile(wedged.xml_path) && !isfile(wedged.os_overlay)

    # A stop first stops the guest's agent, so Buildkite can record
    # `agent_stop`. Only a script that reports the agent stopped within the
    # bound counts; otherwise the guest is shut down as before.
    S = SandboxedBuildkiteAgent
    freebsd_stop = S.agent_stop_payload("freebsd")
    @test freebsd_stop["arguments"]["path"] == "/bin/sh"
    @test occursin("kill -QUIT", last(freebsd_stop["arguments"]["arg"]))
    @test occursin("exit 3", last(freebsd_stop["arguments"]["arg"]))
    # FreeBSD's qemu-ga wedges on commands longer than 1920 bytes.
    @test ncodeunits(JSON.json(freebsd_stop)) < 1900
    # The FreeBSD script's logic, against a fake process table: `pgrep`, `ps`,
    # `kill` and `sleep` are shell functions, and the agent (102, below `su`)
    # exits right on SIGQUIT, once its job's processes are gone, or never.
    # 105 is a job process that left the agent's process tree.
    fake_ps = raw"""
pgrep() {
    case "$1" in
        -x) awk -F'\t' -v n="$2" '$4 == n { print $1 }' "$T" ;;
        -U) awk -F'\t' -v u="$2" '$3 == u { print $1 }' "$T" ;;
    esac
}
ps() {
    case "$2" in args=) c=5 ;; ppid=) c=2 ;; user=) c=3 ;; esac
    awk -F'\t' -v p="$4" -v c="$c" '$1 == p { print $c }' "$T"
}
gone() { awk -F'\t' -v p="$1" '$1 != p' "$T" > "$T.tmp"; mv "$T.tmp" "$T"; }
present() { awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$T"; }
kill() {
    sig=$1; shift
    for p in "$@"; do
        if [ "$sig" = -0 ]; then present "$p"; return; fi
        echo "$sig $p" >> "$L"
        present "$p" || continue
        case "$sig" in
            -KILL) gone "$p" ;;
            -QUIT) [ "$MODE" = prompt ] && gone "$p" ;;
        esac
    done
}
sleep() {
    echo "sleep $1" >> "$L"
    if [ "$MODE" = after_kill ] && [ -z "$(awk -F'\t' '$3 == "bk" && $5 !~ /buildkite-agent start/' "$T")" ]; then
        for p in $(awk -F'\t' '$5 ~ /buildkite-agent start/ { print $1 }' "$T"); do gone "$p"; done
    fi
}
"""
    table = join(["1\t0\troot\tinit\t/sbin/init",
        "101\t100\troot\tsu\tsu -m bk -c /usr/local/bin/buildkite-agent start --acquire-job J",
        "102\t101\tbk\tbuildkite-agent\t/usr/local/bin/buildkite-agent start --acquire-job J",
        "103\t102\tbk\tbuildkite-agent\t/usr/local/bin/buildkite-agent bootstrap",
        "104\t103\tbk\tjulia\tjulia test",
        "105\t1\tbk\tjulia\tjulia daemon"], "\n") * "\n"
    function run_freebsd_stop(mode, rows=table)
        dir = mktempdir()
        Base.write(joinpath(dir, "prelude.sh"), fake_ps)
        Base.write(joinpath(dir, "script.sh"), S.FREEBSD_AGENT_STOP_SCRIPT)
        Base.write(joinpath(dir, "table"), rows)
        Base.write(joinpath(dir, "log"), "")
        proc = run(ignorestatus(setenv(`sh -c ". ./prelude.sh; . ./script.sh"`,
            "T" => joinpath(dir, "table"), "L" => joinpath(dir, "log"), "MODE" => mode,
            "PATH" => ENV["PATH"]; dir)))
        return proc.exitcode, split(read(joinpath(dir, "log"), String), '\n'; keepempty=false)
    end
    killed(log) = sort([parse(Int, last(split(line))) for line in log if startswith(line, "-KILL")])
    # An agent that exits on SIGQUIT is a success, though its user is gone by then.
    code, log = run_freebsd_stop("prompt")
    @test code == 0 && log == ["-QUIT 102", "sleep 2"]
    # Otherwise the job's processes go, also those outside the agent's tree,
    # but not the agent, `su` above it, or anything of another user.
    code, log = run_freebsd_stop("after_kill")
    @test code == 0 && killed(log) == [103, 104, 105]
    code, log = run_freebsd_stop("never")
    @test code == 4 && killed(log) == [103, 104, 105]
    # No agent yet: nothing is signalled.
    code, log = run_freebsd_stop("never", join(filter(!contains("buildkite-agent start --acquire"),
        split(table, '\n')), "\n"))
    @test code == 3 && isempty(log)

    windows_stop = S.agent_stop_payload("windows")
    encoded = last(windows_stop["arguments"]["arg"])
    @test transcode(String, reinterpret(UInt16, S.Base64.base64decode(encoded))) ==
        S.WINDOWS_AGENT_STOP_SCRIPT
    @test occursin("GenerateConsoleCtrlEvent", S.WINDOWS_AGENT_STOP_SCRIPT)
    # It confirms on the agent's exit; the launcher writes the exit file only
    # after detaching the cache, which can take longer than a stop may.
    @test occursin("Get-Process -Id \$ids", S.WINDOWS_AGENT_STOP_SCRIPT)
    @test !occursin("run-buildkite-job.exit", S.WINDOWS_AGENT_STOP_SCRIPT)
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        with_logger(NullLogger()) do
            committed(h) = (S.commit_launch!(h.launch); h)
            for guest_slot in (windows_slot, slot)
                # The agent was never launched: Buildkite only holds the
                # reservation, and the runner will not launch it any more.
                unlaunched = reap_handle(current_domain, guest_slot)
                @test S.stop_job(unlaunched; timeout=1.0) == :not_acquired
                @test_throws S.StoppedBeforeLaunch S.commit_launch!(unlaunched.launch)
                # Once `virsh` ran, a failure does not show the script did not
                # run: an error, or a response lost after the guest ran it.
                rm(agent_stop_ok_path; force=true)
                @test S.stop_job(committed(reap_handle(current_domain, guest_slot)); timeout=1.0) == :unconfirmed
                touch(agent_stop_ok_path)
                touch(exec_lost_path)
                @test S.stop_job(committed(reap_handle(current_domain, guest_slot)); timeout=1.0) == :unconfirmed
                rm(exec_lost_path)
                # Only a deadline that passed before anything was sent is a failure.
                @test S.stop_guest_agent(committed(reap_handle(current_domain, guest_slot));
                    deadline=time() - 1) == :failed
                # No agent running (3), or the script failed (4).
                Base.write(agent_stop_exit_path, "3")
                @test S.stop_job(committed(reap_handle(current_domain, guest_slot)); timeout=5.0) == :no_agent
                Base.write(agent_stop_exit_path, "4")
                @test S.stop_job(committed(reap_handle(current_domain, guest_slot)); timeout=5.0) == :unconfirmed
                # The script never finishes: given up at the bound.
                rm(agent_stop_exit_path; force=true)
                @test @elapsed(@test S.stop_job(committed(reap_handle(current_domain, guest_slot));
                    timeout=1.0) == :unconfirmed) < 5
                # The runner destroys the guest before the script's result
                # arrives: the stop was sent, so it may have taken.
                touch(status_fails_path)
                @test S.stop_job(committed(reap_handle(current_domain, guest_slot)); timeout=5.0) == :unconfirmed
                rm(status_fails_path)
                # The agent stopped.
                Base.write(agent_stop_exit_path, "0")
                @test S.stop_job(committed(reap_handle(current_domain, guest_slot)); timeout=5.0) == :stopped
            end
        end
    end
    # A `virsh` that hangs past its deadline is killed.
    @test @elapsed(@test_throws ErrorException S.read_bounded(`sleep 60`, time() + 0.2)) < 10
    @test S.read_bounded(`echo hi`, time() + 5) == "hi\n"
    # Every command was given what was left of the deadline.
    stops = recorded(agent_stops_path)
    @test length(stops) == 12
    @test all(line -> occursin(r"^\S+ --timeout [1-5]$", line), stops)
    rm(agent_stop_exit_path; force=true)

    # Only confirmation for this job skips guest shutdown. A partial/stale
    # marker must fall back, for both Windows and FreeBSD guests.
    for guest_slot in (windows_slot, slot), marker in ("reap-job\n", "previous-job\n", "")
        Base.write(detached_path, marker)
        Base.write(running_path, current_domain * "\n")
        rm(shutdown_path; force=true)
        rm(destroyed_path; force=true)
        withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
            reap(reap_handle(current_domain, guest_slot); shutdown_timeout=0.5)
        end
        confirmed = strip(marker) == "reap-job"
        @test isempty(recorded(shutdown_path)) == confirmed
        @test (current_domain in recorded(destroyed_path)) == confirmed
        @test isempty(strip(read(running_path, String)))
    end

    # Cross-file contracts with the guest images, not guest-internal control
    # flow: the guest-exec entry points, the env the scheduler injects, the
    # exit/log files the host polls, and the cache-disk repair/detach that
    # guards the shared overlay against `virsh destroy` power-offs.
    windows_agent_setup = read(SandboxedBuildkiteAgent.repo_path("platforms", "windows-kvm", "buildkite-worker", "setup_scripts", "0-02-install-buildkite-agent.ps1"), String)
    @test occursin("run-buildkite-job.ps1", windows_agent_setup)
    @test occursin("BUILDKITE_AGENT_TOKEN=\$env:BUILDKITE_AGENT_TOKEN", windows_agent_setup)
    @test occursin("BUILDKITE_AGENT_TAGS=\$env:BUILDKITE_AGENT_TAGS", windows_agent_setup)
    @test occursin("BUILDKITE_ACQUIRE_JOB_ID=\$JobId", windows_agent_setup)
    # The agent runs as a service, not under guest-exec, so the launcher hands
    # it the job's grant, leaving out what the job was not granted.
    for name in ("SBA_CPUS", "SBA_CPUS_LIMIT", "SBA_MEM_GIB", "SBA_MEM_LIMIT_GIB")
        @test occursin("\"$(name)\"", windows_agent_setup)
    end
    @test occursin("if (-not [string]::IsNullOrEmpty(\$value))", windows_agent_setup)
    @test occursin("AppEnvironmentExtra @agentEnv", windows_agent_setup)
    # The token is injected per job over guest-exec, never baked into the image.
    @test occursin("placeholder-token", windows_agent_setup)
    @test occursin("run-buildkite-job.exit", windows_agent_setup)
    @test occursin("run-buildkite-job.log", windows_agent_setup)
    @test occursin("chkdsk", windows_agent_setup)
    # The launcher outlives the console interrupts that stop the agent.
    @test occursin("SetConsoleCtrlHandler(ignoreInterrupts, true)", windows_agent_setup)

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

@testset "scheduler log records reach a file promptly" begin
    # Under launchd stderr is a regular file; a record must be on disk while the
    # scheduler is still running, not only once it exits.
    dir = mktempdir()
    log_path = joinpath(dir, "scheduler.log")
    ready_path = joinpath(dir, "ready")
    code = """
        using SandboxedBuildkiteAgent
        SandboxedBuildkiteAgent.flush_log_records!()
        @info "scheduler log marker"
        touch($(repr(ready_path)))
        sleep(300)
        """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
    proc = open(log_path, "w") do io
        run(pipeline(cmd; stdout=io, stderr=io); wait=false)
    end
    try
        @test timedwait(() -> isfile(ready_path) || !process_running(proc), 300.0) === :ok
        @test process_running(proc)
        @test occursin("scheduler log marker", read(log_path, String))
    finally
        kill(proc, Base.SIGKILL)
        wait(proc)
    end
end

@testset "scheduler stop job report" begin
    running_id = "0190046e-e199-453b-a302-a21a4d649d31"
    reserved_id = "0190046e-e199-453b-a302-a21a4d649d32"
    snapshot = Dict{String,Any}(
        "generated_at" => time(),
        "slots" => Any[
            Dict("name" => "tester.1", "runner_group" => "tester", "state" => "running",
                "job" => Dict("id" => running_id)),
            Dict("name" => "builder.1", "runner_group" => "builder", "state" => "reserved",
                "job" => Dict("id" => reserved_id)),
            # A duplicate lease should not emit a duplicate retry command.
            Dict("name" => "tester.2", "runner_group" => "tester", "state" => "running",
                "job" => Dict("id" => running_id)),
        ],
    )

    jobs = stop_snapshot_jobs(snapshot)
    @test [job.id for job in jobs] == [reserved_id, running_id]
    @test [job.state for job in jobs] == ["reserved", "running"]

    # Exact: the jobs the stop interrupted, by when they can be retried.
    stop_report = Dict{String,Any}("complete" => true, "jobs" => Any[
        Dict("id" => running_id, "slot" => "tester.1", "runner_group" => "tester",
            "backend" => "linux-sandbox", "retry" => "now"),
        Dict("id" => reserved_id, "slot" => "windows.1", "runner_group" => "windows",
            "backend" => "kvm", "retry" => "once_failed"),
    ])
    io = IOBuffer()
    print_stop_job_report(io, stop_report, "/tmp/scheduler-status.json", snapshot)
    report = String(take!(io))
    now_part, later_part = split(report, "Retry once Buildkite shows them failed")
    @test occursin("The stop interrupted 2 job(s). Nothing retries them", now_part)
    @test occursin("Retry now", now_part)
    @test occursin("  bk job retry $(running_id)  # tester.1", now_part)
    @test occursin("  bk job retry $(reserved_id)  # windows.1", later_part)
    @test !occursin("snapshot", report)
    @test !occursin("pipeline", report)
    # Jobs that only held a reservation, uncertain ones and slots left held
    # each get their own section; reservations get no retry command.
    io = IOBuffer()
    print_stop_job_report(io, Dict{String,Any}("jobs" => Any[
            Dict("id" => "res-job", "slot" => "windows.2", "retry" => "reservation"),
            Dict("id" => "unsure-job", "slot" => "tester.2", "retry" => "uncertain")],
        "held_slots" => Any["freebsd.3"]))
    report = String(take!(io))
    @test occursin("The stop interrupted 1 job(s)", report)
    @test occursin("Stopped while their agent was not running", report)
    @test occursin("  bk job retry unsure-job  # tester.2", report)
    @test occursin("Reservation only", report)
    @test occursin("  res-job  # windows.2", report) && !occursin("bk job retry res-job", report)
    @test occursin("Slots still held", report) && occursin("  freebsd.3", report)

    # A report from a stop that interrupted nothing prints nothing, not the snapshot.
    io = IOBuffer()
    print_stop_job_report(io, Dict("jobs" => Any[]), "/tmp/scheduler-status.json", snapshot)
    @test isempty(String(take!(io)))

    # Without a report, the jobs that were running in the snapshot, to be checked first.
    io = IOBuffer()
    print_stop_job_report(io, nothing, "/tmp/scheduler-status.json", snapshot)
    report = String(take!(io))
    @test occursin("did not report which jobs its stop interrupted", report)
    @test occursin("/tmp/scheduler-status.json", report)
    @test count("bk job retry $(running_id)", report) == 1
    @test !occursin(reserved_id, report)

    empty_io = IOBuffer()
    @test print_stop_job_report(empty_io, nothing, nothing, Dict("slots" => Any[])) === nothing
    @test isempty(String(take!(empty_io)))

    # The report is the one this stop's scheduler wrote: an older one is removed
    # with the request.
    config_path = tempname()
    logdir = mktempdir()
    Base.write(config_path, "[scheduler]\nlogdir = \"$(logdir)\"\n")
    config = read_scheduler_config(config_path)
    SandboxedBuildkiteAgent.write_stop_report(config, stop_report)
    @test SandboxedBuildkiteAgent.read_stop_report(config_path)["jobs"][1]["id"] == running_id
    with_logger(NullLogger()) do
        @test SandboxedBuildkiteAgent.request_graceful_stop(config_path; running=() -> false)
    end
    @test SandboxedBuildkiteAgent.read_stop_report(config_path) === nothing
    @test isfile(SandboxedBuildkiteAgent.stop_request_path(config))
end

@testset "scheduler service replacement" begin
    job_id = "0190046e-e199-453b-a302-a21a4d649d31"
    snapshot = Dict{String,Any}(
        "generated_at" => time(),
        "slots" => Any[
            Dict("name" => "tester.1", "runner_group" => "tester", "state" => "running",
                "job" => Dict("id" => job_id)),
        ],
    )
    events = Symbol[]
    service = (;
        installed=() -> true,
        running=() -> true,
        stop=() -> push!(events, :stop),
        uninstall=() -> push!(events, :uninstall),
        start=() -> push!(events, :start),
    )
    snapshot_reader = _ -> begin
        push!(events, :snapshot)
        return "/tmp/scheduler-status.json", snapshot
    end
    cleanup_resources = (config_path; host) -> begin
        @test config_path == "config.toml"
        push!(events, Symbol("cleanup_$(host)"))
    end
    graceful_stop = (config_path; running) -> push!(events, :graceful_stop)
    report_reader = _ -> Dict("jobs" => Any[Dict("id" => job_id, "slot" => "tester.1", "retry" => "now")])
    io = IOBuffer()
    restart_scheduler_service("config.toml"; host=:linux, io, service, snapshot_reader,
        report_reader, cleanup_resources, graceful_stop)
    @test events == [:snapshot, :graceful_stop, :stop, :cleanup_linux, :start]
    @test occursin("bk job retry $(job_id)", String(take!(io)))

    empty!(events)
    io = IOBuffer()
    reinstall_scheduler_service("config.toml"; host=:linux, io, service, snapshot_reader,
        report_reader, cleanup_resources, graceful_stop,
        enable_service=(config_path; host) -> begin
            @test config_path == "config.toml"
            push!(events, Symbol("enable_$(host)"))
        end)
    @test events == [:snapshot, :graceful_stop, :uninstall, :cleanup_linux, :enable_linux, :start]
    @test occursin("bk job retry $(job_id)", String(take!(io)))

    empty_events = Symbol[]
    stopped_service = (;
        installed=() -> true,
        running=() -> false,
        stop=() -> push!(empty_events, :stop),
        start=() -> push!(empty_events, :start),
    )
    restart_scheduler_service("config.toml"; host=:linux, service=stopped_service,
        snapshot_reader=_ -> error("unexpected snapshot read"),
        cleanup_resources=(config_path; host) -> error("unexpected cleanup"))
    @test empty_events == [:start]

    absent_service = (;
        installed=() -> false,
        running=() -> false,
        stop=() -> error("unexpected stop"),
        uninstall=() -> push!(empty_events, :uninstall),
        start=() -> push!(empty_events, :start),
    )
    @test_throws ErrorException restart_scheduler_service("config.toml";
        host=:linux, service=absent_service)

    empty!(empty_events)
    reinstall_scheduler_service("config.toml"; host=:linux, service=absent_service,
        snapshot_reader=_ -> error("unexpected snapshot read"),
        cleanup_resources=(config_path; host) -> push!(empty_events, :cleanup),
        enable_service=(config_path; host) -> push!(empty_events, :enable))
    @test empty_events == [:uninstall, :cleanup, :enable, :start]

    failure_io = IOBuffer()
    failing_start = merge(service, (; start=() -> error("start failed")))
    @test_throws ErrorException restart_scheduler_service("config.toml";
        host=:linux, io=failure_io, service=failing_start, snapshot_reader,
        report_reader, cleanup_resources, graceful_stop)
    @test occursin("bk job retry $(job_id)", String(take!(failure_io)))

    failure_io = IOBuffer()
    @test_throws ErrorException reinstall_scheduler_service("config.toml";
        host=:linux, io=failure_io, service, snapshot_reader, report_reader, cleanup_resources,
        graceful_stop, enable_service=(config_path; host) -> error("enable failed"))
    @test occursin("bk job retry $(job_id)", String(take!(failure_io)))
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

# A job that runs until its agent is stopped, then exits like a stopped agent.
struct StoppableBackend <: PlatformBackend
    started::Channel{String}
    events::Vector{String}
    stoppable::Bool
end

mutable struct StoppableHandle
    backend::StoppableBackend
    job::Job
    stopped::Base.Event
end

prepare(backend::StoppableBackend, slot::Slot, job::Job, plan::CachePlan,
        alloc::Allocation) = StoppableHandle(backend, job, Base.Event())

function run_job(handle::StoppableHandle, ::Union{Nothing,Float64}=nothing)
    put!(handle.backend.started, handle.job.id)
    wait(handle.stopped)
    handle.backend.stoppable || error("guest went away")
    return -1
end

function SandboxedBuildkiteAgent.stop_job(handle::StoppableHandle; force::Bool=false)
    push!(handle.backend.events, "$(force ? "kill" : "stop") $(handle.job.id)")
    (force || handle.backend.stoppable) || return :failed
    notify(handle.stopped)
    return :stopped
end

function reap(handle::StoppableHandle)
    push!(handle.backend.events, "reap $(handle.job.id)")
    notify(handle.stopped)
    return nothing
end

# A job whose backend's stop answers `outcome`. With `ends`, the job's runner
# ends the job (and tears it down) while the stop is still in flight, as a KVM
# runner can before the guest's stop script reports back.
mutable struct ScriptedStopBackend <: PlatformBackend
    started::Channel{String}
    outcome::Symbol
    ends::Bool
end
struct ScriptedStopHandle
    backend::ScriptedStopBackend
    release::Base.Event
end
function prepare(backend::ScriptedStopBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    return ScriptedStopHandle(backend, Base.Event())
end
function run_job(handle::ScriptedStopHandle, ::Union{Nothing,Float64}=nothing)
    put!(handle.backend.started, "started")
    wait(handle.release)
    return 0
end
function SandboxedBuildkiteAgent.stop_job(handle::ScriptedStopHandle; force::Bool=false)
    if force
        handle.release.set && return :ended
        notify(handle.release)
        return :stopped
    end
    if handle.backend.ends
        notify(handle.release)
        sleep(0.2)
    end
    handle.backend.outcome == :throw && error("lost the response")
    return handle.backend.outcome
end

# A job whose backend can neither stop nor kill it.
struct UnkillableBackend <: PlatformBackend
    started::Channel{String}
    release::Base.Event
end
struct UnkillableHandle
    backend::UnkillableBackend
end
function prepare(backend::UnkillableBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    put!(backend.started, job.id)
    return UnkillableHandle(backend)
end
run_job(handle::UnkillableHandle, ::Union{Nothing,Float64}=nothing) = (wait(handle.backend.release); 0)

# Stops the scheduler while registering, as a stop racing a registration would.
mutable struct RacingRegistrationSource <: JobSource
    jobs::Vector{Job}
    registered::Int
    deregistered::Int
    scheduler::Any
    RacingRegistrationSource(jobs, registered, deregistered) = new(jobs, registered, deregistered, nothing)
end
function SandboxedBuildkiteAgent.register_stack(source::RacingRegistrationSource)
    source.registered += 1
    source.scheduler.stopping = true
    return nothing
end
function SandboxedBuildkiteAgent.deregister_stack(source::RacingRegistrationSource)
    source.deregistered += 1
    return nothing
end

@testset "scheduler stop" begin
    for stoppable in (true, false)
        backend = StoppableBackend(Channel{String}(2), String[], stoppable)
        source = StaticJobSource([job(; id="a"), job(; id="b")])
        scheduler = test_scheduler(test_scheduler_config(),
            [runner_group(; cachedir_root=mktempdir(), max_slots=2, cpus=1)],
            source, backend)
        with_logger(NullLogger()) do
            poll_jobs!(scheduler)
            tasks = [@async(run_available_assignment!(scheduler)) for _ in 1:2]
            @test sort([take!(backend.started), take!(backend.started)]) == ["a", "b"]
            sleeps = Float64[]
            source.jobs = [job(; id="c")]
            @test SandboxedBuildkiteAgent.stop_scheduler!(scheduler;
                sleep_fn=t -> (push!(sleeps, t); sleep(0.01))) == 2
            @test timedwait(() -> all(istaskdone, tasks), 5.0) == :ok
            # The report lists the jobs the stop interrupted, and whether their
            # agent reported the stop (it did unless it had to be killed).
            report = JSON.parsefile(SandboxedBuildkiteAgent.stop_report_path(scheduler.config))
            @test report["complete"]
            @test [job["id"] for job in report["jobs"]] == ["a", "b"]
            @test all(job -> job["forced"] == !stoppable && job["ended"], report["jobs"])
            @test all(job -> job["retry"] == (stoppable ? "now" : "once_failed"), report["jobs"])
            # Staggered, each job stopped once (killed if its agent cannot be
            # stopped), and reaped exactly once, by its runner.
            @test SandboxedBuildkiteAgent.STOP_STAGGER_SECONDS in sleeps
            @test count(startswith("stop"), backend.events) == 2
            @test count(startswith("kill"), backend.events) == (stoppable ? 0 : 2)
            @test count(startswith("reap"), backend.events) == 2
            # Interrupted jobs are left to Buildkite's retry, not finished here.
            @test isempty(source.finished)
            # Nothing is admitted or polled once stopping.
            @test poll_jobs!(scheduler) == 0
            @test isempty(SandboxedBuildkiteAgent.take_dispatch_claims!(scheduler))
            @test isempty(scheduler.active_jobs)
        end
    end

    # A job that ends by itself while the stop is staggered is not reported.
    backend = StoppableBackend(Channel{String}(2), String[], true)
    scheduler = test_scheduler(test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir(), max_slots=2, cpus=1)],
        StaticJobSource([job(; id="a"), job(; id="b")]), backend)
    with_logger(NullLogger()) do
        poll_jobs!(scheduler)
        tasks = [@async(run_available_assignment!(scheduler)) for _ in 1:2]
        sort([take!(backend.started), take!(backend.started)])
        last_slot = maximum(keys(scheduler.active_jobs))
        finishing = scheduler.active_jobs[last_slot]
        function stagger(t)
            # The second job finishes on its own before its turn comes.
            t == SandboxedBuildkiteAgent.STOP_STAGGER_SECONDS && notify(finishing.handle.stopped)
            sleep(0.05)
        end
        @test SandboxedBuildkiteAgent.stop_scheduler!(scheduler; sleep_fn=stagger) == 2
        @test timedwait(() -> all(istaskdone, tasks), 5.0) == :ok
        report = JSON.parsefile(SandboxedBuildkiteAgent.stop_report_path(scheduler.config))
        @test report["complete"]
        @test [job["id"] for job in report["jobs"]] == [only(id for id in ("a", "b")
            if id != finishing.assignment.job.id)]
        @test count(==("stop $(finishing.assignment.job.id)"), backend.events) == 0
    end

    # What a stop learns from the backend decides how the job is reported.
    function scripted_stop(outcome, ends)
        backend = ScriptedStopBackend(Channel{String}(1), outcome, ends)
        scheduler = test_scheduler(test_scheduler_config(),
            [runner_group(; cachedir_root=mktempdir(), max_slots=1, cpus=1)],
            StaticJobSource([job(; id="scripted")]), backend)
        with_logger(NullLogger()) do
            poll_jobs!(scheduler)
            task = @async run_available_assignment!(scheduler)
            take!(backend.started)
            SandboxedBuildkiteAgent.stop_scheduler!(scheduler; sleep_fn=t -> sleep(0.05))
            @test timedwait(() -> istaskdone(task), 5.0) == :ok
        end
        return JSON.parsefile(SandboxedBuildkiteAgent.stop_report_path(scheduler.config))
    end
    retries(report) = [(job["id"], job["retry"]) for job in report["jobs"]]
    # A stop was sent, and the runner tore the job down before the backend
    # heard back: still interrupted.
    @test retries(scripted_stop(:unconfirmed, true)) == [("scripted", "once_failed")]
    # The agent was never launched: only Buildkite's reservation is affected.
    @test retries(scripted_stop(:not_acquired, false)) == [("scripted", "reservation")]
    # The agent was not running: killed while it may have acquired the job,
    # or gone because the job ended by itself.
    @test retries(scripted_stop(:no_agent, false)) == [("scripted", "uncertain")]
    @test isempty(retries(scripted_stop(:no_agent, true)))
    # The stop took effect (the runner ended and tore down the job), but the
    # backend then threw: the job is reported all the same.
    @test retries(scripted_stop(:throw, true)) == [("scripted", "once_failed")]
    # Nothing was sent, and the job then ended by itself.
    @test isempty(retries(scripted_stop(:failed, true)))

    # Which group a job lands in, after each stop attempt.
    group(previous, outcome; backend=BACKEND_LINUX_SANDBOX, forced=false) =
        SandboxedBuildkiteAgent.stop_retry_group(previous, outcome; backend, forced)
    for (previous, outcome, backend, forced, expected) in [
            (nothing, :stopped, BACKEND_LINUX_SANDBOX, false, "now"),
            (nothing, :stopped, BACKEND_MACOS_SEATBELT, false, "now"),
            (nothing, :stopped, BACKEND_KVM, false, "once_failed"),
            (nothing, :stopped, BACKEND_LINUX_SANDBOX, true, "once_failed"),
            ("now", :stopped, BACKEND_LINUX_SANDBOX, true, "once_failed"),
            # Escalated to a kill that was not confirmed: the agent may be dead.
            ("now", :unconfirmed, BACKEND_LINUX_SANDBOX, true, "once_failed"),
            (nothing, :unconfirmed, BACKEND_LINUX_SANDBOX, false, "once_failed"),
            (nothing, nothing, BACKEND_KVM, false, "once_failed"),
            ("now", nothing, BACKEND_LINUX_SANDBOX, true, "once_failed"),
            (nothing, :not_acquired, BACKEND_KVM, false, "reservation"),
            ("reservation", :stopped, BACKEND_KVM, true, "reservation"),
            ("reservation", nothing, BACKEND_KVM, true, "reservation"),
            (nothing, :no_agent, BACKEND_LINUX_SANDBOX, false, "uncertain"),
            ("uncertain", :stopped, BACKEND_LINUX_SANDBOX, true, "uncertain"),
            ("uncertain", :ended, BACKEND_LINUX_SANDBOX, true, nothing),
            ("once_failed", :ended, BACKEND_KVM, true, "once_failed"),
            (nothing, :ended, BACKEND_KVM, false, nothing),
            (nothing, :failed, BACKEND_KVM, false, nothing),
            ("once_failed", :failed, BACKEND_KVM, true, "once_failed"),
        ]
        @test group(previous, outcome; backend, forced) === expected
    end

    # A job that not even a kill ends is still reported, to retry once it failed.
    stuck = UnkillableBackend(Channel{String}(1), Base.Event())
    stuck_scheduler = test_scheduler(test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir(), max_slots=1, cpus=1)],
        StaticJobSource([job(; id="unkillable")]), stuck)
    stuck_task = with_logger(NullLogger()) do
        poll_jobs!(stuck_scheduler)
        task = @async run_available_assignment!(stuck_scheduler)
        @test take!(stuck.started) == "unkillable"
        SandboxedBuildkiteAgent.stop_scheduler!(stuck_scheduler; grace=0, kill_grace=0)
        task
    end
    report = JSON.parsefile(SandboxedBuildkiteAgent.stop_report_path(stuck_scheduler.config))
    @test !report["complete"]
    @test only(report["jobs"])["id"] == "unkillable"
    @test only(report["jobs"])["retry"] == "once_failed" && !only(report["jobs"])["ended"]
    notify(stuck.release)
    wait(stuck_task)

    # A claim made just before the stop is let go without reserving the job.
    source = StaticJobSource([job(; id="late")])
    brg = runner_group(; cachedir_root=mktempdir())
    scheduler = test_scheduler(test_scheduler_config(), [brg], source, NullBackend())
    poll_jobs!(scheduler)
    claim = only(SandboxedBuildkiteAgent.take_dispatch_claims!(scheduler))
    with_logger(NullLogger()) do
        SandboxedBuildkiteAgent.stop_scheduler!(scheduler; grace=0, kill_grace=0)
    end
    @test SandboxedBuildkiteAgent.assignment_from_claim!(scheduler, claim.slot, claim.job,
        claim.alloc, claim.source) === nothing
    # It was never running, so the stop interrupted nothing.
    @test isempty(JSON.parsefile(SandboxedBuildkiteAgent.stop_report_path(scheduler.config))["jobs"])
    @test isempty(source.reserved)
    @test SandboxedBuildkiteAgent.running_assignments(scheduler) == 0

    # Registration does not outlive the stop: none is attempted once stopping,
    # and one that completes after the stop began is undone.
    @test SandboxedBuildkiteAgent.register_scheduler_source_until_success!(scheduler, brg.name) === nothing
    @test source.registered == 0
    racing = test_scheduler(test_scheduler_config(), [brg], RacingRegistrationSource(Job[], 0, 0),
        NullBackend())
    racing.sources[brg.name].scheduler = racing
    SandboxedBuildkiteAgent.register_scheduler_source_until_success!(racing, brg.name)
    @test racing.sources[brg.name].registered == 1
    @test racing.sources[brg.name].deregistered == 1

    # The stop request is a file in the log directory.
    config = test_scheduler_config()
    scheduler = test_scheduler(config, [runner_group(; cachedir_root=mktempdir())],
        StaticJobSource(Job[]), NullBackend())
    path = SandboxedBuildkiteAgent.stop_request_path(config)
    @test dirname(path) == config.logdir
    waiter = @async SandboxedBuildkiteAgent.wait_for_stop_request(scheduler; interval=0.01)
    sleep(0.05)
    @test !istaskdone(waiter)
    write(path, "now\n")
    @test timedwait(() -> istaskdone(waiter), 5.0) == :ok
    @test !ispath(path)

    # At startup, a leftover request is removed, but one written while starting is kept.
    write(path, "old\n")
    run(`touch -t 200001010000 $path`)
    SandboxedBuildkiteAgent.clear_stale_stop_request(scheduler)
    @test !ispath(path)
    write(path, "now\n")
    SandboxedBuildkiteAgent.clear_stale_stop_request(scheduler)
    @test ispath(path)
    rm(path)

    # Linux finds the agent among the job cgroup's processes.
    cgroup = mktempdir()
    proc_root = mktempdir()
    mkpath(joinpath(cgroup, "inner"))
    write(joinpath(cgroup, "cgroup.procs"), "10\n11\n")
    write(joinpath(cgroup, "inner", "cgroup.procs"), "12\n13\n")
    for (pid, argv) in (10 => ["/bin/sh", "wrapper"],
                        11 => ["/usr/bin/buildkite-agent", "start", "--acquire-job=x"],
                        12 => ["/usr/bin/buildkite-agent", "bootstrap"],
                        13 => ["buildkite-agent", "start"])
        mkpath(joinpath(proc_root, string(pid)))
        write(joinpath(proc_root, string(pid), "cmdline"), join(argv, '\0') * '\0')
    end
    @test sort(SandboxedBuildkiteAgent.cgroup_agent_pids(cgroup; proc_root)) == [11, 13]
    @test isempty(SandboxedBuildkiteAgent.cgroup_agent_pids(joinpath(cgroup, "gone"); proc_root))

    # A stop kills the job's processes, but not the agents or the sandbox above them:
    # 10 (sandbox) -> 11 (agent) -> 12 (bootstrap) -> 14 (job); 13 is a second agent
    # whose parent is outside the cgroup; 15 was reparented to the sandbox.
    write(joinpath(cgroup, "inner", "cgroup.procs"), "12\n13\n14\n15\n")
    for (pid, ppid) in (10 => 1, 11 => 10, 12 => 11, 13 => 2, 14 => 12, 15 => 10)
        mkpath(joinpath(proc_root, string(pid)))
        write(joinpath(proc_root, string(pid), "stat"), "$pid (some (odd) name) S $ppid $pid $pid 0")
    end
    for pid in (14, 15)
        write(joinpath(proc_root, string(pid), "cmdline"), "julia\0")
    end
    @test sort(SandboxedBuildkiteAgent.cgroup_job_pids(cgroup; proc_root)) == [12, 14, 15]
    @test SandboxedBuildkiteAgent.parent_pid(14; proc_root) == 12
    @test SandboxedBuildkiteAgent.parent_pid(99; proc_root) === nothing

    # macOS kills the agent's descendants.
    P = SandboxedBuildkiteAgent.MacOSProcess
    processes = [P(1, 0, 1, "launchd", nothing), P(20, 1, 20, "buildkite-agent start", nothing),
                 P(21, 20, 20, "buildkite-agent bootstrap", nothing), P(22, 21, 22, "julia", nothing),
                 P(23, 22, 22, "julia worker", nothing), P(30, 1, 30, "other", nothing)]
    @test SandboxedBuildkiteAgent.macos_descendant_pids(processes, 20) == [23, 22, 21]
    @test isempty(SandboxedBuildkiteAgent.macos_descendant_pids(processes, 30))
end

@testset "memory backstops" begin
    meminfo = tempname()
    write(meminfo, "MemTotal:       527000000 kB\nMemAvailable:    41943040 kB\n")
    @test SandboxedBuildkiteAgent.mem_available_gib(meminfo) == 40.0
    @test SandboxedBuildkiteAgent.mem_available_gib(tempname()) === nothing
    # Called about once a second, so it must not leave the file open for the
    # GC to close.
    fds = Sys.islinux() ? "/proc/self/fd" : "/dev/fd"
    GC.gc()
    GC.enable(false)
    try
        before = length(readdir(fds))
        for _ in 1:100
            SandboxedBuildkiteAgent.mem_available_gib(meminfo)
        end
        @test length(readdir(fds)) < before + 10
    finally
        GC.enable(true)
    end

    config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 2, 4, 2)
    brg = runner_group(; cachedir_root=mktempdir())
    source = StaticJobSource([job(; id="a")])
    scheduler = test_scheduler(config, [brg], source, NullBackend())
    replace_pending_jobs!(scheduler, brg.name, poll_jobs(source))
    with_logger(NullLogger()) do
        @test SandboxedBuildkiteAgent.memory_brake_engaged!(scheduler; available=1.5)
        @test scheduler.memory_braked
        @test !SandboxedBuildkiteAgent.memory_brake_engaged!(scheduler; available=2.5)
        @test !SandboxedBuildkiteAgent.memory_brake_engaged!(scheduler; available=nothing)
    end
    # Disabled by default.
    scheduler = test_scheduler(test_scheduler_config(), [brg], source, NullBackend())
    @test !SandboxedBuildkiteAgent.memory_brake_engaged!(scheduler; available=0.0)

    # OOM kills are reported from memory.events before the cgroup goes away.
    cgroup = mktempdir()
    @test isempty(SandboxedBuildkiteAgent.cgroup_memory_events(cgroup))
    write(joinpath(cgroup, "memory.events"), "low 0\nhigh 0\nmax 12\noom 1\noom_kill 3\noom_group_kill 0\n")
    write(joinpath(cgroup, "memory.max"), "68719476736\n")
    @test SandboxedBuildkiteAgent.cgroup_memory_events(cgroup)["oom_kill"] == 3
    log_path = tempname()
    @test_logs (:warn, "Job hit its memory limit") SandboxedBuildkiteAgent.log_job_oom_events(cgroup; log_path)
    @test occursin("memory.max=68719476736); the kernel OOM-killed 3 process(es)", read(log_path, String))
    write(joinpath(cgroup, "memory.events"), "oom 0\noom_kill 0\n")
    @test_logs SandboxedBuildkiteAgent.log_job_oom_events(cgroup; log_path=tempname())

    # The job cgroup gets the limit, without swap to escape into, and a CPU
    # weight in proportion to its request.
    root = mktempdir()
    write(joinpath(root, "memory.swap.max"), "max\n")
    job_root = SandboxedBuildkiteAgent.create_job_cgroup(root, "job-x"; cpus=12, mem_bytes=8 * 1024^3)
    @test strip(read(joinpath(job_root, "memory.max"), String)) == string(8 * 1024^3)
    @test !isfile(joinpath(job_root, "memory.oom.group"))
    @test strip(read(joinpath(job_root, "memory.swap.max"), String)) == "0"
    @test strip(read(joinpath(job_root, "cpu.weight"), String)) == "1200"
    unlimited = SandboxedBuildkiteAgent.create_job_cgroup(root, "job-y")
    @test !isfile(joinpath(unlimited, "memory.max"))
    @test strip(read(joinpath(unlimited, "cpu.weight"), String)) == "100"
    # Without swap accounting (no memory.swap.* files) the limit still applies.
    noswap = SandboxedBuildkiteAgent.create_job_cgroup(mktempdir(), "job-z"; cpus=1, mem_bytes=1024^3)
    @test strip(read(joinpath(noswap, "memory.max"), String)) == string(1024^3)
    @test !isfile(joinpath(noswap, "memory.swap.max"))
    @test SandboxedBuildkiteAgent.job_cpu_weight(4) == 400
    @test SandboxedBuildkiteAgent.job_cpu_weight(128) == 10_000
end

# Readings handed out in order, and what the sampler published. `fail` makes
# the next sample (:sample) or record (:details) throw.
mutable struct FakeResourceSource <: SandboxedBuildkiteAgent.ResourceSource
    readings::Vector{Any}
    published::Vector{String}
    fail_publish::Bool
    fail::Symbol
    delay::Float64
end
FakeResourceSource(readings=Any[]) = FakeResourceSource(readings, String[], false, :none, 0.0)
SandboxedBuildkiteAgent.resource_platform(::FakeResourceSource) = "fake"
function SandboxedBuildkiteAgent.sample_resources(s::FakeResourceSource)
    s.delay > 0 && sleep(s.delay)
    s.fail === :sample && (s.fail = :none; error("broken reading"))
    return isempty(s.readings) ? nothing : popfirst!(s.readings)
end
function SandboxedBuildkiteAgent.resource_details(s::FakeResourceSource)
    s.fail === :details && (s.fail = :none; error("broken details"))
    return Dict{String,Any}("left" => length(s.readings))
end
function SandboxedBuildkiteAgent.publish_resources(s::FakeResourceSource, content)
    s.fail_publish && error("guest agent gone")
    push!(s.published, content)
end

@testset "job resources" begin
    M = SandboxedBuildkiteAgent
    S = M.ResourceSample
    context = M.job_resource_context(; job=Job("job-1", "pipeline-1", ["queue=test"]),
        slot="linux-host.1", group="linux", queue="test", alloc=M.Allocation(2, 4, 64), host="host")
    sec(t) = UInt64(round(Int, t * 1e9))

    # The generic sampler. CPU busy at 4 for 2 s (startup), then at 1 for 8 s,
    # then at 2 for 10 s: the histogram has every interval.
    source = FakeResourceSource()
    sampler = M.ResourceSampler(source; context)
    sampler.started_at, sampler.started_ns = 1000.0, sec(0)
    cpu = 100.0
    readings = [(0, 0.0), (1, 4), (2, 4), (3, 1), (4, 1), (5, 1), (6, 1), (7, 1), (8, 1), (9, 1), (10, 1), (20, 2)]
    memory = Dict(0 => (1, nothing), 2 => (5, 7), 10 => (3, 9))
    for (t, rate) in readings
        cpu += rate * (t == 0 ? 0 : t <= 10 ? 1 : 10)
        needed, total = get(memory, t, (nothing, nothing))
        push!(source.readings, S(; cpu_seconds=cpu, wait_seconds=5.0 + t / 10,
                                 needed_bytes=needed, total_bytes=total))
        @test M.sample_resources_locked!(sampler; now_ns=sec(t), now=1000.0 + t)
    end
    @test !M.sample_resources_locked!(sampler; now_ns=sec(21))   # no reading: no sample
    record = @lock sampler.lock M.resource_record_locked(sampler)
    @test (record["schema"], record["platform"], record["host"], record["job"]) == (2, "fake", "host", "job-1")
    @test record["host_cpus"] === nothing
    @test (record["samples"], record["duration_seconds"], record["started_at"]) == (12, 20, 1000)
    # When the last sample was taken, and how many had memory figures and how
    # long before the last sample the last of them was.
    @test (record["sampled_at_ms"], record["memory_samples"], record["memory_age_seconds"]) == (1020000, 3, 10)
    @test record["peak_needed_is_lower_bound"] == false
    @test (record["cpu_seconds"], record["mean_cpus"]) == (36.0, 1.8)
    @test !haskey(record, "peak_cpus")
    @test record["busy_histogram"] == [0, 8, 10, 0, 2]          # threads + 1 buckets
    @test record["wait_seconds"] == 2.0
    @test (record["peak_needed_bytes"], record["peak_total_bytes"], record["peak_swap_bytes"]) == (5, 9, nothing)
    # Over the 10 s between the first and the last reading: 1 to 5 over 2 s,
    # then 5 to 3 over 8 s.
    @test record["mean_needed_bytes"] == round(Int, (2 * 3 + 8 * 4) / 10)
    @test record["details"] == Dict("left" => 0)
    @test M.busy_quantile(record["busy_histogram"], 0.9) == 2
    @test M.resource_summary(record) == "Resources: CPU 1.8 avg, 4 peak of 4 (2 requested); " *
        "memory 0.0 GiB mean, 0.0 GiB peak of 64 GiB; waited for a CPU 10% of the time"
    # The line has what people read; the parts that only sometimes matter
    # appear only then.
    line(changes...) = M.resource_summary(merge(record, Dict{String,Any}(changes...)))
    @test line("wait_seconds" => 0.5) ==
          "Resources: CPU 1.8 avg, 4 peak of 4 (2 requested); memory 0.0 GiB mean, 0.0 GiB peak of 64 GiB"
    @test line("wait_seconds" => 0.5, "mean_needed_bytes" => 3 * 1024^3, "peak_needed_bytes" => 5 * 1024^3) ==
          "Resources: CPU 1.8 avg, 4 peak of 4 (2 requested); memory 3.0 GiB mean, 5.0 GiB peak of 64 GiB"
    # Records of earlier schedulers have no mean.
    @test line("wait_seconds" => 0.5, "mean_needed_bytes" => nothing) ==
          "Resources: CPU 1.8 avg, 4 peak of 4 (2 requested); memory 0.0 GiB peak of 64 GiB"
    @test line("wait_seconds" => nothing, "peak_needed_bytes" => round(Int, 1.3 * 1024^3), "peak_needed_is_lower_bound" => true,
               "mean_needed_bytes" => 1024^3,
               "peak_total_bytes" => 3 * 1024^3, "peak_swap_bytes" => 512 * 1024^2, "oom_kills" => 2,
               "memory_age_seconds" => 20) ==
          "Resources: CPU 1.8 avg, 4 peak of 4 (2 requested); memory at least 1.0 GiB mean, 1.3 GiB peak of 64 GiB " *
          "(3.0 GiB with cache); swapped 0.5 GiB; OOM-killed 2 processes; memory reading 20 s old"
    @test line("wait_seconds" => nothing, "cpus_limit" => 0, "mem_limit_gib" => 0, "host_cpus" => 8,
               "details" => Dict("io_read_bytes" => 200 * 1024^2, "io_write_bytes" => 2 * 1024^3)) ==
          "Resources: CPU 1.8 avg, 4 peak (whole host, 8 CPUs; 2 requested); memory 0.0 GiB mean, 0.0 GiB peak; " *
          "disk 0.2 GiB read, 2.0 GiB written"
    @test endswith(line("details" => Dict("domain_cgroup" => Dict("io_read_bytes" => 0, "io_write_bytes" => 1024^3))),
                   "; disk 0 MiB read, 1.0 GiB written; waited for a CPU 10% of the time")
    @test line("mean_cpus" => nothing, "busy_histogram" => nothing, "peak_needed_bytes" => nothing) ==
          "Resources: no measurements"
    # On KVM the wait is the vCPUs' delays summed, which can exceed the wall
    # time; it is shared out over the vCPUs.
    @test endswith(line("details" => Dict("vcpus" => 4), "wait_seconds" => 48.0),
                   "; vCPUs waited for a host CPU 60% of the time")
    @test !occursin("waited", line("details" => Dict("vcpus" => 4), "wait_seconds" => 3.0))

    # Memory figures observed earlier than the sample are called out once
    # they are old.
    source = FakeResourceSource([S(; cpu_seconds=0.0, needed_bytes=1, memory_at=990.0),
                                 S(; cpu_seconds=0.0)])
    sampler = M.ResourceSampler(source; context)
    M.sample_resources_locked!(sampler; now_ns=sec(0), now=1000.0)
    @test (@lock sampler.lock M.resource_record_locked(sampler))["memory_age_seconds"] == 10
    M.sample_resources_locked!(sampler; now_ns=sec(10), now=1010.0)
    record = @lock sampler.lock M.resource_record_locked(sampler)
    @test (record["memory_samples"], record["memory_age_seconds"]) == (1, 20)
    @test endswith(M.resource_summary(record), "; memory reading 20 s old")

    # The mean memory is weighted by time, not by sample: readings come every
    # second at first, then every 10 s.
    gb = 1024^3
    source = FakeResourceSource([S(; needed_bytes=4gb), S(; needed_bytes=4gb), S(; needed_bytes=12gb)])
    sampler = M.ResourceSampler(source; context)
    for t in (0, 2, 10)
        M.sample_resources_locked!(sampler; now_ns=sec(t), now=1000.0 + t)
    end
    record = @lock sampler.lock M.resource_record_locked(sampler)
    @test record["mean_needed_bytes"] == round(Int, (2 * 4gb + 8 * 8gb) / 10)
    @test occursin("memory 7.2 GiB mean, 12.0 GiB peak", M.resource_summary(record))
    # A reading repeated with the time it was observed (a guest that has not
    # reported since) is not counted twice; one reading is its own mean.
    source = FakeResourceSource([S(; needed_bytes=2gb, memory_at=1000.0),
                                 S(; needed_bytes=2gb, memory_at=1000.0),
                                 S(; needed_bytes=6gb, memory_at=1015.0)])
    sampler = M.ResourceSampler(source; context)
    M.sample_resources_locked!(sampler; now_ns=sec(0), now=1000.0)
    @test (@lock sampler.lock M.resource_record_locked(sampler))["mean_needed_bytes"] == 2gb
    M.sample_resources_locked!(sampler; now_ns=sec(10), now=1010.0)
    M.sample_resources_locked!(sampler; now_ns=sec(20), now=1020.0)
    @test (@lock sampler.lock M.resource_record_locked(sampler))["mean_needed_bytes"] == 4gb
    # Without memory readings there is no mean.
    source = FakeResourceSource([S(; cpu_seconds=1.0)])
    sampler = M.ResourceSampler(source; context)
    M.sample_resources_locked!(sampler; now_ns=sec(0))
    @test (@lock sampler.lock M.resource_record_locked(sampler))["mean_needed_bytes"] === nothing

    # Without wait readings (macOS) there is no wait time; rates above
    # `threads` grow the histogram.
    source = FakeResourceSource([S(; cpu_seconds=0.0), S(; cpu_seconds=12.0), S(; cpu_seconds=13.0)])
    sampler = M.ResourceSampler(source; context)
    for t in 0:2
        M.sample_resources_locked!(sampler; now_ns=sec(t))
    end
    record = @lock sampler.lock M.resource_record_locked(sampler)
    @test record["mean_cpus"] == 6.5
    @test record["busy_histogram"] == [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    @test M.busy_quantile(record["busy_histogram"], 0.9) == 12
    @test record["wait_seconds"] === nothing
    @test M.resource_summary(record) == "Resources: CPU 6.5 avg, 12 peak of 4 (2 requested)"
    # Without two CPU readings the CPU figures are unknown, not zero.
    source = FakeResourceSource([S(; needed_bytes=1), S(; needed_bytes=2, cpu_seconds=3.0)])
    sampler = M.ResourceSampler(source; context)
    M.sample_resources_locked!(sampler; now_ns=sec(0))
    M.sample_resources_locked!(sampler; now_ns=sec(1))
    record = @lock sampler.lock M.resource_record_locked(sampler)
    @test all(record[k] === nothing for k in ("cpu_seconds", "mean_cpus", "busy_histogram"))
    @test record["peak_needed_bytes"] == 2
    @test M.resource_summary(record) == "Resources: memory 0.0 GiB mean, 0.0 GiB peak of 64 GiB"
    # A reading without CPU time still counts for memory.
    source = FakeResourceSource([S(; cpu_seconds=1.0), S(; needed_bytes=10), S(; cpu_seconds=3.0)])
    sampler = M.ResourceSampler(source; context)
    for t in 0:2
        M.sample_resources_locked!(sampler; now_ns=sec(t))
    end
    record = @lock sampler.lock M.resource_record_locked(sampler)
    @test (record["samples"], record["peak_needed_bytes"], record["cpu_seconds"], record["mean_cpus"]) ==
          (3, 10, 2.0, 1.0)
    @test record["busy_histogram"] == [0, 2, 0, 0, 0]

    # Every sample publishes the summary line and the JSON record; a failed
    # publish is retried by the next sample. Once stopped, nothing more.
    source = FakeResourceSource([S(; cpu_seconds=1.0), S(; cpu_seconds=2.0), S(; cpu_seconds=3.0)])
    sampler = M.ResourceSampler(source; context)
    M.sample_resources!(sampler)
    @test length(source.published) == 1
    summary, json, rest = split(only(source.published), "\n")
    @test startswith(summary, "Resources: ")
    @test JSON.parse(json)["samples"] == 1 && JSON.parse(json)["details"] == Dict("left" => 2) && isempty(rest)
    source.fail_publish = true
    M.sample_resources!(sampler)
    @test (sampler.samples, length(source.published)) == (2, 1)
    source.fail_publish = false
    M.stop_resources!(sampler)
    M.sample_resources!(sampler)
    @test (sampler.samples, length(source.published)) == (2, 1)

    # Telemetry never fails the job: a sample or record that throws is
    # skipped, and the next one goes ahead.
    source = FakeResourceSource([S(; cpu_seconds=1.0), S(; cpu_seconds=2.0), S(; cpu_seconds=3.0)])
    sampler = M.ResourceSampler(source; context)
    source.fail = :sample
    @test_logs (:warn, r"resource") M.sample_resources!(sampler)
    @test (sampler.samples, length(source.published)) == (0, 0)
    source.fail = :details
    M.sample_resources!(sampler)
    @test length(source.published) == 0
    M.sample_resources!(sampler)
    @test length(source.published) == 1
    @test sampler.failures == 2

    # Starting the sampler does not wait for a sample, nor fail with one.
    source = FakeResourceSource([S(; cpu_seconds=1.0)])
    source.delay, source.fail = 2.0, :sample
    sampler = M.ResourceSampler(source; context)
    @test @elapsed(timer = M.start_resource_sampler(sampler; interval=10.0, fast_samples=0)) < 1
    close(timer)
    M.stop_resources!(sampler)

    # The timer samples right away, every fast tick at first, then every
    # `interval`.
    source = FakeResourceSource([S(; cpu_seconds=Float64(i)) for i in 1:1000])
    sampler = M.ResourceSampler(source; context)
    timer = M.start_resource_sampler(sampler; interval=0.1, fast_interval=0.01, fast_samples=3)
    @test timedwait(() -> sampler.samples >= 1, 10.0) === :ok
    start = time()
    @test timedwait(() -> sampler.samples >= 6, 10.0) === :ok
    elapsed = time() - start
    close(timer)
    M.stop_resources!(sampler)
    n = sampler.samples
    sleep(0.05)
    @test sampler.samples == n
    @test n < 4 + 2 * elapsed / 0.1                         # not every tick after the first 3

    # The Linux source: the job cgroup's cpu.stat, cpu.pressure and memory.stat.
    cgroup, live = mktempdir(), mktempdir()
    source = M.CgroupResourceSource(cgroup; live_dir=live)
    @test M.sample_resources(source) === nothing              # no memory.stat yet
    write(joinpath(cgroup, "memory.stat"),
          "anon 3000\nfile 9000\nshmem 500\nkernel 999999\nkernel_stack 10\npagetables 20\n" *
          "percpu 30\nslab_reclaimable 5000\nslab_unreclaimable 40\n")
    write(joinpath(cgroup, "memory.current"), "12000\n")
    s = M.sample_resources(source)
    @test (s.cpu_seconds, s.wait_seconds, s.needed_bytes, s.total_bytes, s.swap_bytes) ==
          (nothing, nothing, 3600, 12000, nothing)            # not the aggregate `kernel`
    write(joinpath(cgroup, "memory.stat"), "anon 1000\nfile 20000\nshmem 100\n")
    write(joinpath(cgroup, "memory.swap.current"), "300\n")
    write(joinpath(cgroup, "cpu.stat"), "usage_usec 41000000\nuser_usec 900000\n")
    write(joinpath(cgroup, "cpu.pressure"), "some avg10=0.00 avg60=0.00 avg300=0.00 total=2500000\n" *
                                            "full avg10=0.00 avg60=0.00 avg300=0.00 total=1000000\n")
    s = M.sample_resources(source)
    @test (s.cpu_seconds, s.wait_seconds, s.needed_bytes, s.swap_bytes) == (41.0, 2.5, 1100, 300)
    write(joinpath(cgroup, "memory.events"), "low 0\nhigh 0\nmax 7\noom 0\noom_kill 0\n")
    write(joinpath(cgroup, "memory.swap.max"), "0\n")
    details = M.resource_details(source)
    @test (details["peak_anon_shmem_bytes"], details["peak_kernel_bytes"], details["peak_file_bytes"]) ==
          (3500, 100, 20000)
    @test (details["peak_anon_bytes"], details["peak_shmem_bytes"]) == (3000, 500)
    # Before Linux 5.19 there is no memory.peak, and the sampled maximum of
    # memory.current stands in; without pids.current there is no pid count.
    @test (details["memory_peak_bytes"], details["memory_peak_source"]) == (12000, "sampled")
    @test !haskey(details, "pids_peak") && !haskey(details, "io_read_bytes")
    @test details["swap_max"] == "0"
    @test details["memory_events"] == Dict("low" => 0, "high" => 0, "max" => 7, "oom" => 0, "oom_kill" => 0)
    @test (details["cpu_seconds"], details["cpu_pressure_some_seconds"], details["cpu_pressure_full_seconds"]) ==
          (41.0, 2.5, 1.0)
    # The pids and io controllers are enabled for job cgroups where the
    # scheduler's cgroup has them, for accounting; a failure only warns.
    for (controllers, expected) in (("cpu cpuset memory pids io", ["pids", "io"]),
                                    ("cpu cpuset memory pids", ["pids"]),
                                    ("cpu cpuset memory", String[]))
        fake = mktempdir()
        write(joinpath(fake, "cgroup.controllers"), controllers * "\n")
        write(joinpath(fake, "cgroup.subtree_control"), "")
        @test M.enable_accounting_controllers!(fake) == expected
        @test M.enable_accounting_controllers!(fake; io_accounting=false) == filter(!=("io"), expected)
    end
    fake = mktempdir()
    write(joinpath(fake, "cgroup.controllers"), "cpu io\n")
    mkdir(joinpath(fake, "cgroup.subtree_control"))          # writes fail
    @test (@test_logs (:warn, r"io controller") M.enable_accounting_controllers!(fake)) == String[]
    # Turning io_accounting off disables io for new job cgroups after the
    # stale ones are gone; when the kernel (here: a read-only file) refuses,
    # the scheduler says so and reports it instead of assuming it worked.
    fake = mktempdir()
    write(joinpath(fake, "cgroup.subtree_control"), "cpu memory\n")
    @test M.disable_io_accounting!(fake)
    write(joinpath(fake, "cgroup.subtree_control"), "cpu io memory\n")
    chmod(joinpath(fake, "cgroup.subtree_control"), 0o444)
    if !(try write(joinpath(fake, "cgroup.subtree_control"), "x"); true catch; false end)   # not as root
        @test !(@test_logs (:warn, r"io controller") M.disable_io_accounting!(fake))
        backend = M.LinuxSandboxBackend(mktempdir(); io_accounting=false)
        backend.root = fake
        @test_logs (:error, r"io_accounting is off") match_mode=:any M.cleanup(backend)
        @test M.io_accounting_stuck(backend)
        on = M.LinuxSandboxBackend(mktempdir())
        on.root = fake
        M.cleanup(on)
        @test !M.io_accounting_stuck(on)
    end
    # Newer kernels keep the peaks themselves; io.stat is summed over devices.
    write(joinpath(cgroup, "memory.peak"), "25000\n")
    write(joinpath(cgroup, "pids.current"), "7\n")
    M.sample_resources(source)
    @test (M.resource_details(source)["pids_peak"], M.resource_details(source)["pids_peak_source"]) == (7, "sampled")
    write(joinpath(cgroup, "pids.peak"), "42\n")
    write(joinpath(cgroup, "cpu.stat"), "usage_usec 41000000\nnr_periods 10\nnr_throttled 3\nthrottled_usec 1500000\n")
    write(joinpath(cgroup, "io.stat"), "259:0 rbytes=1000 wbytes=2000 rios=1 wios=2 dbytes=0 dios=0\n" *
                                      "8:0 rbytes=10 wbytes=20 rios=3 wios=4 dbytes=0 dios=0\n")
    write(joinpath(cgroup, "io.pressure"), "some avg10=0.00 avg60=0.00 avg300=0.00 total=4000000\n" *
                                           "full avg10=0.00 avg60=0.00 avg300=0.00 total=3000000\n")
    write(joinpath(cgroup, "memory.pressure"), "some avg10=0.00 avg60=0.00 avg300=0.00 total=200000\n" *
                                               "full avg10=0.00 avg60=0.00 avg300=0.00 total=100000\n")
    rm(joinpath(cgroup, "memory.swap.max"))
    details = M.resource_details(source)
    @test (details["memory_peak_bytes"], details["memory_peak_source"]) == (25000, "memory.peak")
    @test (details["pids_peak"], details["pids_peak_source"]) == (42, "pids.peak")
    @test (details["cpu_nr_throttled"], details["cpu_throttled_seconds"]) == (3, 1.5)
    @test (details["io_read_bytes"], details["io_write_bytes"], details["io_read_ops"], details["io_write_ops"]) ==
          (1010, 2020, 4, 6)
    @test (details["io_pressure_some_seconds"], details["io_pressure_full_seconds"],
           details["memory_pressure_some_seconds"], details["memory_pressure_full_seconds"]) == (4.0, 3.0, 0.2, 0.1)
    @test details["swap_max"] === nothing                     # no swap accounting
    # A removed cgroup gives no sample.
    @test M.sample_resources(M.CgroupResourceSource(joinpath(cgroup, "gone"))) === nothing

    # It publishes one file in a per-slot directory of the scheduler's log
    # directory (mounted read-only in the job).
    @test M.live_resources_path("/logs", "linux-host.1") == "/logs/live/linux-host.1"
    sampler = M.ResourceSampler(source; context)
    M.sample_resources!(sampler)
    summary, json = readlines(joinpath(live, M.LIVE_RECORD_NAME))
    @test startswith(summary, "Resources: ")
    record = JSON.parse(json)
    @test (record["platform"], record["peak_needed_bytes"], record["details"]["memory_peak_bytes"]) ==
          ("linux", 1100, 25000)
    @test readdir(live) == [M.LIVE_RECORD_NAME]

    # The pre-exit hook copies the summary into the log and the record into
    # meta-data. It waits a little for a sample taken after the command ended,
    # keeps away from records it cannot read, and never fails the job.
    hook = joinpath(dirname(@__DIR__), "agent", "hooks", "pre-exit")
    bin = mktempdir()
    calls, slow, os = joinpath(bin, "calls"), joinpath(bin, "slow"), joinpath(bin, "os")
    write(joinpath(bin, "buildkite-agent"),
          "#!/bin/sh\n[ -f '$slow' ] && exec sleep 60\nprintf '%s|' \"\$@\" >> '$calls'\nexit 1\n")
    write(joinpath(bin, "uname"), "#!/bin/sh\ncat '$os'\n")
    chmod(joinpath(bin, "buildkite-agent"), 0o755)
    chmod(joinpath(bin, "uname"), 0o755)
    write(os, "Darwin\n")
    file = joinpath(mktempdir(), "resources")
    function run_hook(; bash="bash")
        rm(calls; force=true)
        out = IOBuffer()
        cmd = addenv(`$bash $hook`, "SBA_RESOURCES_FILE" => file, "BUILDKITE_JOB_ID" => "job-1",
                     "SBA_RESOURCES_WAIT_SECONDS" => "2", "PATH" => "$bin:$(ENV["PATH"])")
        ok = success(pipeline(cmd; stdout=out, stderr=out))
        return ok, String(take!(out)), isfile(calls) ? read(calls, String) : ""
    end
    # Timestamps far from the hook's start, except where a test needs one close.
    now_ms() = floor(Int, 1000 * time())
    record(at) = "{\"a\":1,\"sampled_at_ms\":$(at)}"
    fresh = record(now_ms() + 3_600_000)
    @test run_hook() == (true, "", "")                         # no record
    write(file, "summary line\n$(fresh)\n")
    @test run_hook() == (true, "~~~ Resource usage\nsummary line\n", "meta-data|set|sba/job-1|$(fresh)|")
    # Only macOS gets the file's path from the environment.
    write(os, "Linux\n")
    @test run_hook() == (true, "", "")
    write(os, "Darwin\n")
    # A record from before the hook started: wait for a newer one, and say so
    # if none comes.
    stale = record(1_000_000)
    write(file, "summary line\n$(stale)\n")
    ok, out, meta = run_hook()
    @test ok && meta == "meta-data|set|sba/job-1|$(stale)|"
    @test startswith(out, "~~~ Resource usage\nsummary line\nsandboxed-buildkite-agent: no sample since the command ended; " *
                          "the last one is from ")
    write(file, "summary line\n$(stale)\n")
    writer = @async (sleep(1.2); M.publish_file_atomically(file, "final line\n$(fresh)\n"))
    @test run_hook() == (true, "~~~ Resource usage\nfinal line\n", "meta-data|set|sba/job-1|$(fresh)|")
    wait(writer)
    for torn in ("summary line\n{\"a\":", "summary line\n{\"a\": {}}", "summary line",
                 string("summary line\n{\"a\":\"", "x"^40000, "\"}\n"))
        write(file, torn)
        ok, out, meta = run_hook()
        @test ok && occursin("incomplete resource record", out) && meta == ""
    end
    # An unreadable record gets the same message, without bash's own error.
    write(file, "summary line\n$(fresh)\n")
    chmod(file, 0o000)
    if !(try read(file); true catch; false end)     # root reads it anyway
        ok, out, meta = run_hook()
        @test ok && out == "sandboxed-buildkite-agent: incomplete resource record in $(file)\n" && meta == ""
    end
    chmod(file, 0o644)
    # A sample from just before the command ended, most likely in the same
    # second as the hook's start, is not the final one; also under macOS's
    # bash 3.2, which has no clock finer than a second.
    bashes = ["bash"]
    Sys.isapple() && isfile("/bin/bash") && startswith(read(`/bin/bash -c 'echo $BASH_VERSION'`, String), "3.") &&
        push!(bashes, "/bin/bash")
    for bash in bashes
        just_before = record(now_ms() - 1)
        write(file, "summary line\n$(just_before)\n")
        ok, out, meta = run_hook(; bash)
        @test ok && meta == "meta-data|set|sba/job-1|$(just_before)|"
        @test occursin(r"no sample since the command ended; the last one is from \d+ s before", out)
    end
    # The sampler's own record: one published before the hook is stale, one
    # published while the hook waits is taken.
    source = FakeResourceSource([S(; cpu_seconds=1.0), S(; cpu_seconds=2.0)])
    sampler = M.ResourceSampler(source; context)
    M.sample_resources!(sampler)
    write(file, last(source.published))
    ok, out, meta = run_hook()
    @test ok && occursin("no sample since the command ended", out)
    @test JSON.parse(meta[length("meta-data|set|sba/job-1|")+1:end-1])["sampled_at_ms"] isa Integer
    writer = @async (sleep(1.2); M.sample_resources!(sampler); M.publish_file_atomically(file, last(source.published)))
    ok, out, meta = run_hook()
    wait(writer)
    @test ok && out == "~~~ Resource usage\n$(first(split(last(source.published), '\n')))\n"
    # The summary says when the kernel OOM-killed some of the job (Linux).
    cgroup, live = mktempdir(), mktempdir()
    write(joinpath(cgroup, "memory.stat"), "anon 1000\n")
    write(joinpath(cgroup, "memory.events"), "low 0\nhigh 0\nmax 159\noom 1\noom_kill 1\n")
    sampler = M.ResourceSampler(M.CgroupResourceSource(cgroup; live_dir=live); context)
    M.sample_resources!(sampler)
    cp(joinpath(live, M.LIVE_RECORD_NAME), file; force=true)
    ok, out, meta = run_hook()
    @test ok && occursin(r"; OOM-killed 1 process\n", out)
    @test JSON.parse(meta[length("meta-data|set|sba/job-1|")+1:end-1])["oom_kills"] == 1
    write(joinpath(cgroup, "memory.events"), "oom 0\noom_kill 0\n")
    M.sample_resources!(sampler)
    cp(joinpath(live, M.LIVE_RECORD_NAME), file; force=true)
    ok, out, meta = run_hook()
    @test ok && !occursin("OOM", out)
    # A meta-data upload that hangs is given up on.
    write(file, "summary line\n$(fresh)\n")
    touch(slow)
    elapsed = @elapsed (ok, out, meta) = run_hook()
    @test ok && out == "~~~ Resource usage\nsummary line\n" && elapsed < 15
    rm(slow)
end


@testset "KVM job resources" begin
    M = SandboxedBuildkiteAgent

    # `virsh domstats --vcpu --cpu-total` of a Windows guest on amdci6 (libvirt
    # 8.0), cut to two vCPUs.
    amdci6 = """
        Domain: 'windows-amdci6.1'
          cpu.time=5057655502000
          cpu.user=4333370646000
          cpu.system=724284855000
          cpu.cache.monitor.count=0
          cpu.haltpoll.success.time=13669722696
          cpu.haltpoll.fail.time=15713310583
          vcpu.current=2
          vcpu.maximum=2
          vcpu.0.state=1
          vcpu.0.time=773820000000
          vcpu.0.wait=0
          vcpu.0.delay=1383111530
          vcpu.1.state=1
          vcpu.1.time=552330000000
          vcpu.1.wait=0
          vcpu.1.delay=330567129

        """
    stats = M.parse_domstats(amdci6)
    @test stats["vcpu.1.time"] == "552330000000"
    r = M.kvm_cpu_reading(stats)
    @test (r.vcpus, r.vcpu_time, r.delay, r.domain_time) ==
          (2, 1326150000000, 1713678659, 5057655502000)
    # Hosts without delay figures; no vCPUs, no reading.
    @test M.kvm_cpu_reading(filter(kv -> !occursin("delay", kv[1]), stats)).delay === nothing
    @test M.kvm_cpu_reading(M.parse_domstats("Domain: 'x'\n  state.state=5\n")) === nothing

    # A stand-in for virsh: `domstats` prints the file `stats`, the guest file
    # commands write into `guest/`, and opening fails while `guest/` is missing
    # (an image without the resources directory). `guest-exec` starts pid 42,
    # whose status is the file `exec-status`. Every call is logged.
    root = mktempdir()
    fakebin, guest = joinpath(root, "bin"), joinpath(root, "guest")
    mkpath(fakebin)
    calls, statsfile = joinpath(root, "calls"), joinpath(root, "stats")
    exec_status, hang = joinpath(root, "exec-status"), joinpath(root, "hang")
    write(joinpath(fakebin, "virsh"), """
        #!/bin/sh
        printf '%s\\n' "\$3 \$5" >> "$calls"
        [ -f "$hang" ] && exec sleep 60
        for kind in guest-file-open guest-file-write guest-file-close; do
            case "\$5" in *"\\"execute\\":\\"\$kind\\""*) [ -f "$root/hang-\$kind" ] && exec sleep 60 ;; esac
        done
        case "\$3" in
            domstats) cat "$statsfile" ;;
            qemu-agent-command)
                case "\$5" in
                    *guest-file-open*)
                        [ -d "$guest" ] || { echo "error: internal error: unable to execute QEMU agent command 'guest-file-open': No such file or directory" >&2; exit 1; }
                        : > "$guest/record"
                        [ -f "$root/crash-guest-file-open" ] && exit 1
                        printf '{"return":7}' ;;
                    *guest-file-write*)
                        data="\$(printf '%s' "\$5" | sed 's/.*"buf-b64":"\\([^"]*\\)".*/\\1/')"
                        printf '%s' "\$data" | base64 -d >> "$guest/record"
                        printf '{"return":{"count":%d,"eof":false}}' "\$(printf '%s' "\$data" | base64 -d | wc -c)" ;;
                    *guest-file-close*) printf '{"return":{}}' ;;
                    *guest-exec-status*) [ -f "$exec_status" ] || exit 1; cat "$exec_status" ;;
                    *guest-exec*) printf '{"return":{"pid":42}}' ;;
                    *) exit 2 ;;
                esac ;;
            *) exit 2 ;;
        esac
        """)
    chmod(joinpath(fakebin, "virsh"), 0o755)
    ncalls(kind) = isfile(calls) ? count(l -> startswith(l, kind), eachline(calls)) : 0

    secrets = mktempdir()
    write(joinpath(secrets, "buildkite-agent-token"), "token\n")
    brg = BuildkiteRunnerGroup("windows", Dict{String,Any}("max_slots" => 1,
        "queues" => "build", "backend" => BACKEND_KVM, "guest" => "windows",
        "cachedir" => mktempdir(), "tempdir" => mktempdir(), "secrets_dir" => secrets,
        "default" => Dict("cpus" => 2, "mem_gib" => 16),
        "tags" => Dict{String,String}("os" => "windows", "arch" => "x86_64"),
    ); host=:linux, total_mem_gib=512)
    slot = Slot(brg, 1)
    plan = cache_plan(slot, job(; id="kvm-res-job"), :untrusted)
    handle = KVMHandle(KVMBackend(mktempdir(), [brg]), slot, job(; id="kvm-res-job"), plan,
        Allocation(2, 2, 16), slot.name, kvm_xml_path(slot), kvm_os_overlay_path(slot),
        kvm_cache_overlay_path(plan), joinpath(mktempdir(), "kvm-res-job.log"))
    sampler = handle.resources
    source = sampler.source
    @test M.resource_platform(source) == "windows-kvm"
    @test source.record_path == raw"C:\buildkite-agent\resources\resources"
    @test sampler.context["job"] == "kvm-res-job" && sampler.context["cpus_limit"] == 2
    @test M.resource_platform(M.KVMResourceSource("d", "freebsd")) == "freebsd-kvm"
    @test M.KVMResourceSource("d", "freebsd").record_path == "/var/run/sandboxed-buildkite-agent/resources"

    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        # No domain: no sample.
        @test M.sample_resources(source) === nothing
        # Busy time is the vCPU time, halt polling included; waiting is the
        # summed delay.
        write(statsfile, amdci6)
        s = M.sample_resources(source)
        @test s.cpu_seconds ≈ 1326150000000 / 1e9
        # Halt-poll figures that come and go do not move the busy time.
        source2 = M.KVMResourceSource("d", "windows")
        write(statsfile, join(filter(l -> !occursin("haltpoll", l), split(amdci6, '\n')), '\n'))
        @test M.sample_resources(source2).cpu_seconds ≈ 1326150000000 / 1e9
        @test s.wait_seconds ≈ 1713678659 / 1e9
        @test s.needed_bytes === nothing
        # Without the directory in the guest, publishing fails and the sampler
        # carries on; once it exists, the next sample writes the record there.
        sec(t) = UInt64(round(Int, t * 1e9))
        source.first = source.last = nothing
        @lock sampler.lock begin
            @test M.sample_resources_locked!(sampler; now_ns=sec(0))
            M.publish_resources_locked(sampler)
        end
        @test (ncalls("qemu-agent-command"), isdir(guest)) == (1, false)
        mkdir(guest)
        write(statsfile, replace(amdci6,
            "vcpu.0.time=773820000000" => "vcpu.0.time=$(773820000000 + 10_000_000_000)",
            "vcpu.1.time=552330000000" => "vcpu.1.time=$(552330000000 + 9_500_000_000)",
            "cpu.haltpoll.fail.time=15713310583" => "cpu.haltpoll.fail.time=$(15713310583 + 500_000_000)",
            "vcpu.0.delay=1383111530" => "vcpu.0.delay=$(1383111530 + 2_000_000_000)",
            "cpu.time=5057655502000" => "cpu.time=$(5057655502000 + 22_000_000_000)"))
        @lock sampler.lock begin
            @test M.sample_resources_locked!(sampler; now_ns=sec(10))
            M.publish_resources_locked(sampler)
        end
        summary, json = readlines(joinpath(guest, "record"))
        record = JSON.parse(json)
        @test (record["platform"], record["cpu_seconds"], record["mean_cpus"], record["wait_seconds"]) ==
              ("windows-kvm", 19.5, 1.95, 2.0)
        @test record["busy_histogram"] == [0, 0, 10]
        # This host reported no balloon statistics (no BalloonService).
        @test record["details"] == Dict("vcpus" => 2,
                                        "emulator_cpu_seconds" => 2.5, "qemu_rss_bytes" => nothing,
                                        "guest_memory_bytes" => nothing, "peak_file_cache_bytes" => nothing,
                                        "paged_in_bytes" => nothing, "paged_out_bytes" => nothing)
        @test record["peak_needed_bytes"] === nothing
        @test startswith(summary, "Resources: CPU 2.0 avg, 2 peak of 2 (2 requested)")
        @test (ncalls("domstats"), ncalls("qemu-agent-command")) == (5, 4)

        # A hung libvirt holds up neither a sample beyond its time budget nor
        # the stop before the VM's teardown, and nothing runs after the stop.
        touch(hang)
        @test @elapsed(@test M.sample_resources(M.KVMResourceSource("d", "windows"; budget=1.0)) === nothing) < 5
        hung = M.ResourceSampler(M.KVMResourceSource("d", "windows"); context=Dict{String,Any}())
        n = ncalls("domstats")
        task = @async M.sample_resources!(hung)
        @test timedwait(() -> ncalls("domstats") > n, 10.0) === :ok
        @test @elapsed(M.stop_resources!(hung)) < 2
        @test timedwait(() -> istaskdone(task), 5.0) === :ok
        rm(hang)
        n = ncalls("domstats")
        M.sample_resources!(hung)
        @test ncalls("domstats") == n

        # The domain's whole cgroup on the host: that of its QEMU process,
        # found by its exact `-name guest=` (not by the scope's name, which
        # libvirt shortens), less libvirt's `libvirt/emulator` below it; read
        # with file reads only, and its peak compared with the guest's RAM.
        cgroot, procroot = mktempdir(), mktempdir()
        slice = joinpath(cgroot, "machine.slice")
        function fake_process(pid, args, cgroup)
            mkpath(joinpath(procroot, string(pid)))
            write(joinpath(procroot, string(pid), "cmdline"), join(args, '\0') * '\0')
            write(joinpath(procroot, string(pid), "cgroup"), "0::$(cgroup)\n")
        end
        qemu(name) = ["/usr/bin/qemu-system-x86_64", "-name", "guest=$(name),debug-threads=on", "-S"]
        find(domain) = M.kvm_domain_cgroup(domain; proc_root=procroot, cgroup_root=cgroot)
        @test find("windows-host.2") === nothing                             # no QEMU at all
        scopes = Dict{String,String}()
        # Names libvirt shortens differently between versions (underscores
        # dropped, dashes and dots collapsed, cut to 64 bytes), a longer name
        # with the same prefix, a comma, and a non-QEMU process with the same
        # option; the layout without systemd too.
        for (pid, name, scope) in (
                (101, "windows-host.2", "machine-qemu\\x2d3\\x2dwindows\\x2dhost.2.scope"),
                (102, "windows_test.1", "machine-qemu\\x2d4\\x2dwindowstest.1.scope"),
                (103, "windows--host.1", "machine-qemu\\x2d5\\x2dwindows\\x2dhost.1.scope"),
                (104, "-windows-host.3.", "machine-qemu\\x2d6\\x2dwindows\\x2dhost.3.scope"),
                (105, "x"^57 * "-a", "machine-qemu\\x2d7\\x2d" * "x"^57 * ".scope"),
                (106, "x"^57 * "-b", "machine-qemu\\x2d8\\x2d" * "x"^57 * ".scope"),
                (107, "comma,host", "machine-qemu\\x2d9\\x2dcommahost.scope"))
            scopes[name] = joinpath(slice, scope)
            mkpath(joinpath(slice, scope, "libvirt", "emulator"))
            fake_process(pid, qemu(replace(name, "," => ",,")), "/machine.slice/$(scope)/libvirt/emulator")
        end
        mkpath(joinpath(cgroot, "machine", "qemu-1-nosystemd.libvirt-qemu", "emulator"))
        fake_process(108, qemu("nosystemd"), "/machine/qemu-1-nosystemd.libvirt-qemu/emulator")
        fake_process(109, ["/usr/bin/swtpm", "-name", "guest=windows-host.2"], "/system.slice/other.scope")
        for (name, scope) in scopes
            @test find(name) == scope
        end
        @test find("nosystemd") == joinpath(cgroot, "machine", "qemu-1-nosystemd.libvirt-qemu")
        @test find("windows-host.20") === nothing && find("comma") === nothing
        # Two QEMUs claiming one name: neither is trusted.
        fake_process(110, qemu("windows_test.1"), "/machine.slice/elsewhere.scope")
        @test find("windows_test.1") === nothing
        scope = scopes["windows-host.2"]
        write(joinpath(scope, "memory.current"), string(9 * 1024^3), "\n")
        write(joinpath(scope, "memory.stat"),
              "anon $(8 * 1024^3)\nfile $(512 * 1024^2)\nshmem 0\npagetables $(20 * 1024^2)\nslab_unreclaimable $(4 * 1024^2)\n")
        write(joinpath(scope, "memory.events"), "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n")
        write(joinpath(scope, "cpu.stat"), "usage_usec 90000000\nnr_throttled 0\nthrottled_usec 0\n")
        write(joinpath(scope, "io.stat"), "253:0 rbytes=4096 wbytes=8192 rios=1 wios=2 dbytes=0 dios=0\n")
        write(joinpath(scope, "pids.current"), "40\n")
        domain = M.KVMResourceSource("windows-host.2", "windows"; proc_root=procroot, cgroup_root=cgroot,
                                     guest_ram_bytes=8 * 1024^3)
        @test M.sample_resources(domain) !== nothing
        write(joinpath(scope, "memory.current"), string(8 * 1024^3), "\n")      # past its peak
        M.sample_resources(domain)
        usage = M.resource_details(domain)["domain_cgroup"]
        @test (usage["memory_peak_bytes"], usage["memory_peak_source"], usage["memory_current_bytes"]) ==
              (9 * 1024^3, "sampled", 8 * 1024^3)
        @test usage["guest_ram_bytes"] == 8 * 1024^3 && !haskey(usage, "overhead_peak_bytes")
        @test (usage["peak_anon_bytes"], usage["peak_file_bytes"], usage["pids_peak"]) == (8 * 1024^3, 512 * 1024^2, 40)
        # QEMU's kernel-side overhead (page tables, vhost) beside its anon memory.
        @test usage["peak_kernel_bytes"] == 24 * 1024^2
        @test (usage["cpu_seconds"], usage["io_read_bytes"], usage["io_write_ops"]) == (90.0, 4096, 2)
        write(joinpath(scope, "memory.peak"), string(10 * 1024^3), "\n")
        usage = M.resource_details(domain)["domain_cgroup"]
        @test (usage["memory_peak_bytes"], usage["memory_peak_source"], usage["guest_ram_bytes"]) ==
              (10 * 1024^3, "memory.peak", 8 * 1024^3)
        # No QEMU process found: no domain figures, no error.
        nodomain = M.KVMResourceSource("windows-host.9", "windows"; proc_root=procroot, cgroup_root=cgroot)
        M.sample_resources(nodomain)
        @test !haskey(M.resource_details(nodomain), "domain_cgroup")
        # A failed lookup is retried once a minute, a few times per job: the
        # QEMU appearing later is found at the next lookup, not every sample.
        mkpath(joinpath(slice, "machine-qemu\\x2d9\\x2dwindows\\x2dhost.9.scope"))
        fake_process(111, qemu("windows-host.9"), "/machine.slice/machine-qemu\\x2d9\\x2dwindows\\x2dhost.9.scope")
        M.sample_resources(nodomain)
        @test nodomain.scope === nothing && nodomain.scope_lookups == 1
        nodomain.scope_next_lookup = 0.0
        M.sample_resources(nodomain)
        @test nodomain.scope == joinpath(slice, "machine-qemu\\x2d9\\x2dwindows\\x2dhost.9.scope")
        exhausted = M.KVMResourceSource("windows-host.9", "windows"; proc_root=procroot, cgroup_root=cgroot)
        exhausted.scope_lookups = M.KVM_DOMAIN_CGROUP_LOOKUPS
        M.sample_resources(exhausted)
        @test exhausted.scope === nothing
        # Only a QEMU's command line counts.
        @test M.kvm_runs_domain(procroot, "111", "windows-host.9")
        @test !M.kvm_runs_domain(procroot, "109", "windows-host.2")    # swtpm
        @test !M.kvm_runs_domain(procroot, "999", "windows-host.9")    # gone

        # Larger contents go out in pieces the FreeBSD guest agent survives.
        rm(calls)
        content = string("x"^2500, "\n")
        writer = M.KVMResourceSource("d", "freebsd")
        M.kvm_start_sample!(writer)
        M.publish_resources(writer, content)
        @test read(joinpath(guest, "record"), String) == content
        @test ncalls("qemu-agent-command") == 5        # open, 3 writes, close

        # Running out of time while publishing still closes the file, in the
        # time kept for that; a close that fails is retried at the next
        # publication; an open whose result is unknown counts as a lost handle,
        # and after a few of those publishing stops.
        nclose() = count(l -> occursin("guest-file-close", l), eachline(calls))
        writer = M.KVMResourceSource("d", "windows"; budget=2.0)
        touch(joinpath(root, "hang-guest-file-write"))
        M.kvm_start_sample!(writer)
        n = nclose()
        @test_throws M.SampleCommandKilled M.publish_resources(writer, content)
        @test nclose() == n + 1 && isempty(writer.stale_handles) && writer.lost_handles == 0
        touch(joinpath(root, "hang-guest-file-close"))
        M.kvm_start_sample!(writer)
        @test_throws M.SampleCommandKilled M.publish_resources(writer, content)
        @test writer.stale_handles == Dict(7 => 1)
        rm(joinpath(root, "hang-guest-file-write"))
        rm(joinpath(root, "hang-guest-file-close"))
        M.kvm_start_sample!(writer)
        n = nclose()
        M.publish_resources(writer, content)
        @test nclose() == n + 2 && isempty(writer.stale_handles)    # the old handle, then this one
        @test read(joinpath(guest, "record"), String) == content
        touch(joinpath(root, "hang-guest-file-open"))
        for lost in 1:M.KVM_RESOURCE_MAX_LOST_HANDLES
            M.kvm_start_sample!(writer)
            @test_throws M.SampleCommandKilled M.publish_resources(writer, content)
            @test writer.lost_handles == lost
        end
        rm(joinpath(root, "hang-guest-file-open"))
        M.kvm_start_sample!(writer)
        n = ncalls("qemu-agent-command")
        @test_throws ErrorException M.publish_resources(writer, content)
        @test ncalls("qemu-agent-command") == n
        # An image without the directory: the guest agent refuses the open,
        # and nothing is lost. A virsh that fails after the guest opened the
        # file (a lost connection) may have lost a handle.
        mv(guest, guest * ".away")
        writer = M.KVMResourceSource("d", "windows")
        M.kvm_start_sample!(writer)
        @test_throws M.SampleCommandFailed M.publish_resources(writer, content)
        @test writer.lost_handles == 0
        mv(guest * ".away", guest)
        touch(joinpath(root, "crash-guest-file-open"))
        M.kvm_start_sample!(writer)
        @test_throws M.SampleCommandFailed M.publish_resources(writer, content)
        @test writer.lost_handles == 1
        rm(joinpath(root, "crash-guest-file-open"))
        # Nor does an open that is never sent.
        writer = M.KVMResourceSource("d", "freebsd"; record_path="/" * "x"^2000)
        M.kvm_start_sample!(writer)
        @test_throws ErrorException M.publish_resources(writer, content)
        @test writer.lost_handles == 0
        writer = M.KVMResourceSource("d", "windows")
        @test_throws M.SampleCommandNotRun M.publish_resources(writer, content)     # out of time
        @test writer.lost_handles == 0

        # Commands a FreeBSD guest agent would choke on are refused before
        # virsh; other guests take them.
        rm(calls)
        big = Dict("execute" => "guest-ping", "arguments" => Dict("pad" => "x"^2000))
        @test_throws ErrorException M.qga_command(handle.domain, big; max_bytes=M.qga_max_command_bytes("freebsd"))
        @test ncalls("qemu-agent-command") == 0
        @test M.qga_max_command_bytes("windows") === nothing
        @test_throws ProcessFailedException M.qga_command(handle.domain, big)    # the stand-in's "unknown"
        @test ncalls("qemu-agent-command") == 1
        chunk_command = Dict("execute" => "guest-file-write", "arguments" => Dict(
            "handle" => typemax(Int), "buf-b64" => M.Base64.base64encode(zeros(UInt8, M.QGA_WRITE_CHUNK))))
        @test ncodeunits(JSON.json(chunk_command)) <= M.QGA_MAX_COMMAND_BYTES
    end

    # `virsh domstats --balloon` of an idle 8 GiB Windows Server 2022 guest with
    # BalloonService (virtio-win 0.1.229) on pegasus, KiB except `last-update`.
    balloon(; unused=7383344, caches=26456, swap_in=631840, swap_out=0, updated=1793772670) = """
          balloon.current=8388608
          balloon.maximum=8388608
          balloon.swap_in=$(swap_in)
          balloon.swap_out=$(swap_out)
          balloon.major_fault=29402
          balloon.minor_fault=768962
          balloon.unused=$(unused)
          balloon.available=8388064
          balloon.usable=$(unused + caches ÷ 2)
          balloon.last-update=$(updated)
          balloon.disk_caches=$(caches)
          balloon.hugetlb_pgalloc=0
          balloon.hugetlb_pgfail=0
          balloon.rss=8468148
        """
    memory = M.kvm_guest_memory("windows")
    @test memory isa M.WindowsBalloonMemory && M.kvm_guest_memory("freebsd") isa M.FreeBSDSysctlMemory
    @test M.kvm_guest_memory("other") === nothing
    stats = M.parse_domstats(balloon())
    # In use is total less available physical memory; needed excludes the file cache.
    m = M.sample_guest_memory!(memory, "d", stats; now=1793772675)
    @test m == (; needed_bytes=1024 * (8388064 - 7383344 - 26456),
                total_bytes=1024 * (8388064 - 7383344), swap_bytes=nothing, memory_at=1793772670.0)
    # The same statistics again are no new reading.
    @test M.sample_guest_memory!(memory, "d", stats; now=1793772685) === nothing
    # Statistics QEMU kept from before the service stopped, or none at all.
    @test M.sample_guest_memory!(M.WindowsBalloonMemory(), "d", stats; now=1793772670 + 61) === nothing
    @test M.sample_guest_memory!(M.WindowsBalloonMemory(), "d",
        filter(kv -> kv[1] != "balloon.unused", stats); now=1793772675) === nothing
    # 2 GiB held, then released while 3 GiB of files are cached.
    m = M.sample_guest_memory!(memory, "d", M.parse_domstats(balloon(; unused=7383344 - 2 * 1024^2,
        swap_in=631840 + 1024^2, swap_out=4096, updated=1793772680)); now=1793772685)
    @test m.needed_bytes == 1024 * (8388064 - 7383344 + 2 * 1024^2 - 26456)
    m = M.sample_guest_memory!(memory, "d", M.parse_domstats(balloon(; unused=7383344 - 3 * 1024^2,
        caches=3 * 1024^2, updated=1793772690)); now=1793772695)
    @test m.needed_bytes == 1024 * (8388064 - 7383344) && m.total_bytes == m.needed_bytes + 3 * 1024^3
    @test M.guest_memory_details(memory) == Dict("guest_memory_bytes" => 1024 * 8388064,
        "peak_file_cache_bytes" => 3 * 1024^3, "paged_in_bytes" => 0, "paged_out_bytes" => 0)

    # Through the source and the sampler, with fresh statistics.
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        source = M.KVMResourceSource("d", "windows")
        sampler = M.ResourceSampler(source; context=Dict{String,Any}(
            "cpus" => 2, "cpus_limit" => 2, "mem_gib" => 8, "mem_limit_gib" => 8))
        now = round(Int, time())
        write(statsfile, string(amdci6, balloon(; updated=now)))
        s = M.sample_resources(source)
        @test (s.needed_bytes, s.total_bytes, s.swap_bytes) ==
              (1024 * (8388064 - 7383344 - 26456), 1024 * (8388064 - 7383344), nothing)
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(0))
        write(statsfile, string(amdci6, balloon(; unused=7383344 - 2 * 1024^2, swap_in=631840 + 1024^2,
                                                updated=now + 10)))
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(10_000_000_000))
        record = @lock sampler.lock M.resource_record_locked(sampler)
        @test record["peak_needed_bytes"] == 1024 * (8388064 - 7383344 + 2 * 1024^2 - 26456)
        @test record["peak_total_bytes"] == 1024 * (8388064 - 7383344 + 2 * 1024^2)
        @test record["peak_swap_bytes"] === nothing
        # The sampler's first reading repeated the statistics read above.
        @test (record["memory_samples"], record["peak_needed_is_lower_bound"]) == (1, false)
        @test record["details"]["qemu_rss_bytes"] == 1024 * 8468148
        @test record["details"]["paged_in_bytes"] == 1024^3
        @test occursin("; memory 2.9 GiB mean, 2.9 GiB peak of 8 GiB", M.resource_summary(record))
    end

    # The guest command of an idle 8 GiB FreeBSD 13.4 guest on pegasus.
    sysctl(; active=2843, inactive=4522, laundry=0, wired=49044, free=1967568, arc=41378904,
           swapin=0, swapout=0, swapused=0) = """
        hw.pagesize: 4096
        kstat.zfs.misc.arcstats.size: $(arc)
        vm.stats.vm.v_active_count: $(active)
        vm.stats.vm.v_free_count: $(free)
        vm.stats.vm.v_inactive_count: $(inactive)
        vm.stats.vm.v_laundry_count: $(laundry)
        vm.stats.vm.v_page_count: 2025825
        vm.stats.vm.v_swappgsin: $(swapin)
        vm.stats.vm.v_swappgsout: $(swapout)
        vm.stats.vm.v_wire_count: $(wired)
        vm.swap_total: 2147483648
        Total:           2097152          $(swapused)
        """
    pages(n) = 4096 * n
    r = M.parse_freebsd_memory(sysctl())
    @test r.total_bytes == pages(2843 + 4522 + 49044)
    @test r.needed_bytes == pages(2843 + 49044) - 41378904
    @test r.swap_bytes == 0
    @test r.bytes["pages"] == pages(2025825) && r.bytes["swap_total"] == 2147483648
    # The order does not matter, and a missing ARC (no ZFS) or swapctl line is no error.
    r = M.parse_freebsd_memory(join(reverse(filter(l -> !occursin(r"arcstats|Total", l),
                                                   split(sysctl(; swapused=0), '\n'))), '\n'))
    @test r.needed_bytes == pages(2843 + 49044) && r.swap_bytes === nothing
    @test M.parse_freebsd_memory(replace(sysctl(), "vm.swap_total: 2147483648" => "vm.swap_total: 0",
                                         r"Total:.*" => "")).swap_bytes == 0
    # Faked or broken output: no reading, or an ARC larger than the wired pages.
    @test M.parse_freebsd_memory("") === nothing
    @test M.parse_freebsd_memory(replace(sysctl(), "hw.pagesize: 4096" => "hw.pagesize: 4097")) === nothing
    @test M.parse_freebsd_memory(replace(sysctl(), r"vm.stats.vm.v_wire_count.*\n" => "")) === nothing
    @test M.parse_freebsd_memory(sysctl(; active="99999999999999999999")) === nothing
    @test M.parse_freebsd_memory(sysctl(; active=2^41)) === nothing
    @test M.parse_freebsd_memory(sysctl(; active=-1)) === nothing
    @test M.parse_freebsd_memory(sysctl(; arc=2^50)).needed_bytes == pages(2843)
    @test ncodeunits(JSON.json(Dict("execute" => "guest-exec", "arguments" => Dict("path" => "/bin/sh",
        "arg" => ["-c", M.FREEBSD_MEMORY_COMMAND], "capture-output" => true)))) < 600

    # Through the source, against the stand-in guest agent: each sample collects
    # the previous `guest-exec` and starts the next, one at a time.
    exited(output) = write(exec_status, JSON.json(Dict("return" => Dict("exited" => true, "exitcode" => 0,
        "out-data" => M.Base64.base64encode(output)))))
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        rm(calls; force=true)
        write(statsfile, replace(amdci6, "windows-amdci6.1" => "freebsd-amdci6.1"))
        source = M.KVMResourceSource("d", "freebsd")
        sampler = M.ResourceSampler(source; context=Dict{String,Any}(
            "cpus" => 2, "cpus_limit" => 2, "mem_gib" => 8, "mem_limit_gib" => 8))
        nexec(kind) = count(l -> occursin("\"execute\":\"$(kind)\"", l), eachline(calls))
        # First sample: CPU only, the command is started.
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(0))
        @test source.memory.pending == 42 && nexec("guest-exec") == 1
        started = source.memory.pending_at
        @test sampler.peak_needed === nothing
        # Still running: no new command.
        write(exec_status, """{"return":{"exited":false}}""")
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(1_000_000_000))
        @test nexec("guest-exec") == 1 && nexec("guest-exec-status") == 1
        # Done: its reading counts, the next one starts.
        exited(sysctl())
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(2_000_000_000))
        @test nexec("guest-exec") == 2 && sampler.peak_needed == pages(2843 + 49044) - 41378904
        @test sampler.memory_at == started
        # 2 GiB held, some of it swapped out; then released while the ARC holds 3 GiB.
        exited(sysctl(; active=2843 + 2^19, swapout=1024, swapused=4096))
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(10_000_000_000))
        exited(sysctl(; wired=49044 + 3 * 2^18, arc=41378904 + 3 * 1024^3, swapout=1024, swapused=4096))
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(20_000_000_000))
        # A faked reading is skipped.
        exited("vm.stats.vm.v_active_count: 999999999\n")
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(30_000_000_000))
        record = @lock sampler.lock M.resource_record_locked(sampler)
        @test record["peak_needed_bytes"] == pages(2843 + 2^19 + 49044) - 41378904
        @test record["peak_total_bytes"] == pages(2843 + 4522 + 49044 + 3 * 2^18)
        @test record["peak_swap_bytes"] == 4096 * 1024
        details = record["details"]
        @test details["at_needed_peak_bytes"] == Dict("active" => pages(2843 + 2^19), "inactive" => pages(4522),
            "laundry" => 0, "wired" => pages(49044), "arc" => 41378904, "free" => pages(1967568))
        @test (details["guest_memory_bytes"], details["swap_configured_bytes"], details["peak_arc_bytes"]) ==
              (pages(2025825), 2147483648, 41378904 + 3 * 1024^3)
        @test (details["swapped_in_bytes"], details["swapped_out_bytes"]) == (0, pages(1024))
        # A lower bound, from readings that lag one sample behind.
        @test occursin(r"; memory at least \d+\.\d GiB mean, 2.2 GiB peak of 8 GiB", M.resource_summary(record))
        @test endswith(M.resource_summary(record), "; swapped 4 MiB")
        @test record["peak_needed_is_lower_bound"] && record["memory_samples"] == 3
        # A guest agent that stops answering gives up the pending command after
        # a few tries and starts a new one.
        write(exec_status, """{"return":{"exited":false}}""")
        @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64(40_000_000_000))
        rm(exec_status)
        n = nexec("guest-exec")
        for i in 1:M.FREEBSD_MEMORY_MAX_FAILURES
            @lock sampler.lock M.sample_resources_locked!(sampler; now_ns=UInt64((40 + i) * 1_000_000_000))
        end
        @test nexec("guest-exec") == n + 1 && source.memory.pending == 42
    end
    # Nothing breaks without a guest agent at all.
    source = M.KVMResourceSource("no-such-domain", "freebsd")
    source.deadline = time() + 10
    @test M.sample_guest_memory!(source.memory, source, Dict{String,String}()) === nothing
    @test source.memory.pending === nothing
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

@testset "environment.d hook: job width from the grant" begin
    # Run the hook through the agent's `environment` hook, which sources every
    # file of `environment.d` under `set -euo pipefail`, and read the result
    # from a child process, which sees only what the hooks exported (as the
    # job's command does). The hooks directory holds the real runner and this
    # hook only: the other hooks check for Windows drives. A fake `uname`
    # exercises every OS branch on any host.
    hooks = mktempdir()
    mkpath(joinpath(hooks, "environment.d"))
    mkpath(joinpath(hooks, "environment.local.d"))
    repo_hooks = joinpath(dirname(@__DIR__), "agent", "hooks")
    symlink(joinpath(repo_hooks, "environment"), joinpath(hooks, "environment"))
    symlink(joinpath(repo_hooks, "environment.d", "101_julia_num_cores.sh"),
            joinpath(hooks, "environment.d", "101_julia_num_cores.sh"))
    bin = mktempdir()
    write(joinpath(bin, "uname"), "#!/bin/sh\nprintf '%s\\n' \"\$FAKE_UNAME\"\n")
    chmod(joinpath(bin, "uname"), 0o755)
    probe = raw"""
        source "$BUILDKITE_HOOKS_PATH/environment" >/dev/null
        exec bash -c '
            printf "JULIA_CPU_THREADS=%s\n" "${JULIA_CPU_THREADS-unset}"
            printf "OMP_THREAD_LIMIT=%s\n" "${OMP_THREAD_LIMIT-unset}"
            if [ "$(type -t nproc)" = function ]; then
                printf "nproc=%s\n" "$(nproc)"
            else
                printf "nproc=none\n"
            fi'
        """
    function run_hook(os; env...)
        vars = Dict{String,String}("PATH" => string(bin, ":/usr/bin:/bin"),
                                   "BUILDKITE_HOOKS_PATH" => hooks, "FAKE_UNAME" => os)
        for (k, v) in env
            vars[string(k)] = v
        end
        out, err = IOBuffer(), IOBuffer()
        proc = run(pipeline(ignorestatus(setenv(`bash -c $probe`, vars)); stdout=out, stderr=err))
        lines = split(strip(String(take!(out))), '\n'; keepempty=false)
        result = Dict{String,String}(String.(split(line, '='; limit=2)) for line in lines)
        return proc.exitcode, result, String(take!(err))
    end

    # The grant sets the width; on Linux `OMP_THREAD_LIMIT` follows, so that
    # coreutils `nproc` agrees.
    code, env, _ = run_hook("Linux"; SBA_CPUS_LIMIT="4")
    @test code == 0
    @test env["JULIA_CPU_THREADS"] == "4" && env["OMP_THREAD_LIMIT"] == "4"
    @test env["nproc"] == "none"
    # A width the step sets itself wins, and so does its own `OMP_THREAD_LIMIT`.
    code, env, _ = run_hook("Linux"; SBA_CPUS_LIMIT="4", JULIA_CPU_THREADS="2")
    @test code == 0 && env["JULIA_CPU_THREADS"] == "2" && env["OMP_THREAD_LIMIT"] == "2"
    code, env, _ = run_hook("Linux"; SBA_CPUS_LIMIT="4", OMP_THREAD_LIMIT="1")
    @test code == 0 && env["JULIA_CPU_THREADS"] == "4" && env["OMP_THREAD_LIMIT"] == "1"
    # macOS has no `nproc`; the hook's reports the job's width, not every core.
    code, env, _ = run_hook("Darwin"; SBA_CPUS_LIMIT="4")
    @test code == 0
    @test env["JULIA_CPU_THREADS"] == "4" && env["nproc"] == "4"
    @test env["OMP_THREAD_LIMIT"] == "unset"
    code, env, _ = run_hook("Darwin"; SBA_CPUS_LIMIT="4", JULIA_CPU_THREADS="3")
    @test code == 0 && env["nproc"] == "3"
    # FreeBSD and Windows (Git Bash) guests have their own `nproc`.
    for os in ("FreeBSD", "MINGW64_NT-10.0-20348")
        code, env, _ = run_hook(os; SBA_CPUS_LIMIT="8")
        @test code == 0
        @test env["JULIA_CPU_THREADS"] == "8" && env["nproc"] == "none"
        @test env["OMP_THREAD_LIMIT"] == "unset"
    end

    # Without a grant or an explicit width the job fails, saying why, rather
    # than guessing from the machine.
    for os in ("Linux", "Darwin", "FreeBSD"), bad in (nothing, "", "0", "four", "-2")
        vars = bad === nothing ? (;) : (; SBA_CPUS_LIMIT=bad)
        code, env, err = run_hook(os; vars...)
        @test code != 0
        @test !haskey(env, "JULIA_CPU_THREADS")
        @test occursin("SBA_CPUS_LIMIT", err) && occursin("JULIA_CPU_THREADS", err)
    end
end

@testset "scheduler startup cleanup" begin
    backend = CleanupBackend(0, 0)
    source = StaticJobSource(Job[])
    scheduler = test_scheduler(
        test_scheduler_config(),
        [runner_group(; cachedir_root=mktempdir(), max_slots=2)],
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
    # The sandbox rootfs artifact only exists for Linux platforms.
    if Sys.islinux()
        secrets = mktempdir()
        token_path = joinpath(secrets, "buildkite-agent-token")
        Base.write(token_path, "secret-token\n")
        brg = BuildkiteRunnerGroup("linux-env", Dict{String,Any}("max_slots" => 2,
            "queues" => "build",
            "default" => Dict("cpus" => 3),
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
            alloc=Allocation(3),
            rootfs_dir=mktempdir(),
            agent_token_path=token_path)
        @test sandbox_config.env["SBA_CPUS"] == "3"
        @test sandbox_config.env["SBA_CPUS_LIMIT"] == "3"
        # Memory is disclosed only when the job was granted some; the
        # Julia-specific names are the agent hook's business.
        for var in ("SBA_MEM_GIB", "SBA_MEM_LIMIT_GIB", "JULIA_CPU_THREADS", "OMP_THREAD_LIMIT")
            @test !haskey(sandbox_config.env, var)
        end
        mem_config = Sandbox.SandboxConfig(brg;
            agent_name=Slot(brg, 1).name,
            cache_path=mktempdir(),
            shared_cache_path=nothing,
            temp_path=mktempdir(),
            alloc=Allocation(2, 3, 1, 2, 0),
            rootfs_dir=mktempdir(),
            agent_token_path=token_path)
        @test mem_config.env["SBA_CPUS"] == "2"
        @test mem_config.env["SBA_CPUS_LIMIT"] == "3"
        @test mem_config.env["SBA_MEM_GIB"] == "1"
        @test mem_config.env["SBA_MEM_LIMIT_GIB"] == "2"

        # Unpinned groups with `cpus_limit` still tell the job how wide to go.
        threaded_config = Sandbox.SandboxConfig(brg;
            agent_name=Slot(brg, 1).name,
            cache_path=mktempdir(),
            shared_cache_path=nothing,
            temp_path=mktempdir(),
            alloc=Allocation(0, 16, 0),
            rootfs_dir=mktempdir(),
            agent_token_path=token_path)
        @test threaded_config.env["SBA_CPUS"] == "0"
        @test threaded_config.env["SBA_CPUS_LIMIT"] == "16"

        # Unpinned (cpus=0) groups run on every CPU the scheduler may use, and
        # are told that count.
        unpinned_config = Sandbox.SandboxConfig(brg;
            agent_name=Slot(brg, 1).name,
            cache_path=mktempdir(),
            shared_cache_path=nothing,
            temp_path=mktempdir(),
            alloc=Allocation(0),
            visible_cpus=24,
            rootfs_dir=mktempdir(),
            agent_token_path=token_path)
        @test unpinned_config.env["SBA_CPUS"] == "0"
        @test unpinned_config.env["SBA_CPUS_LIMIT"] == "24"
        @test !haskey(unpinned_config.env, "JULIA_CPU_THREADS")

        slot = Slot(runner_group(; name="linux", cachedir_root=mktempdir()), 1)
        @test job_cgroup_name(slot, job(; id="abc/def")) == string("job-", slot.name, "-unknown-job")

        cgroup_file = tempname()
        Base.write(cgroup_file, "0::/system.slice/buildkite.service\n")
        @test scheduler_cgroup_root(; cgroup_file, cgroup_mount="/sys/fs/cgroup") ==
              "/sys/fs/cgroup/system.slice/buildkite.service"

        wrapped = wrap_command_in_cgroup_join_file("/sys/fs/cgroup/test/cgroup.procs", `echo ok`)
        @test wrapped.exec[1] == joinpath(dirname(@__DIR__), "src", "backends", "assets", "host_cgroup_wrapper.sh")
        @test wrapped.exec[2] == "/sys/fs/cgroup/test/cgroup.procs"

        @testset "Linux persistence root probe cache" begin
            empty!(linux_persist_root_cache)
            rootfs = mktempdir()
            hint = mktempdir()
            calls = Ref(0)
            finder(rootfs_arg, hints_arg) = begin
                calls[] += 1
                @test rootfs_arg == rootfs
                @test hints_arg == [hint]
                return (hint, true)
            end

            @sync for _ in 1:8
                @async @test linux_persist_root_info(rootfs, [hint]; finder) == (hint, true)
            end
            @test calls[] == 1

            empty!(linux_persist_root_cache)
            @test_throws ErrorException linux_persist_root_info(
                rootfs, [hint]; finder=(rootfs_arg, hints_arg) -> (nothing, false))
            empty!(linux_persist_root_cache)
        end

        backend = LinuxSandboxBackend(mktempdir())
        backend.root = "/not/a/real/cgroup"
        cleanup(backend)
        @test backend.root == "/not/a/real/cgroup"

        # Jobs get a cpuset of `cpus_limit` CPUs, disjoint from other running
        # jobs while there are enough, chosen from the CPUs the scheduler's
        # cgroup may use, which need not start at 0 or be contiguous.
        S = SandboxedBuildkiteAgent
        @test S.choose_job_cpus(S.PinnedCPUs[], 4, 0:15) == [0, 1, 2, 3]
        @test S.choose_job_cpus([S.PinnedCPUs([0, 1, 2, 3])], 4, 0:15) == [4, 5, 6, 7]
        @test S.choose_job_cpus([S.PinnedCPUs(collect(0:11))], 8, 0:15) == [0, 1, 2, 3, 12, 13, 14, 15]
        @test S.choose_job_cpus(S.PinnedCPUs[], 32, 0:15) == collect(0:15)
        @test S.choose_job_cpus(S.PinnedCPUs[], 4, 8:15) == [8, 9, 10, 11]
        @test S.choose_job_cpus([S.PinnedCPUs([8, 9, 10, 11]), S.PinnedCPUs([0, 1])], 4, 8:15) == [12, 13, 14, 15]
        @test S.choose_job_cpus([S.PinnedCPUs([2, 3])], 3, [1, 2, 3, 7]) == [1, 2, 7]
        # Once sets must overlap, CPUs under a wide, lightly charged build
        # (4 CPUs on 16) go before CPUs under a test that fills its 8.
        test_set = S.PinnedCPUs(0:7; request=8)
        build_set = S.PinnedCPUs(8:23; request=4)
        @test S.choose_job_cpus([test_set, build_set], 8, 0:31) == collect(24:31)
        @test S.choose_job_cpus([test_set, build_set], 8, 0:23) == collect(8:15)
        @test S.choose_job_cpus([S.PinnedCPUs(0:3; request=0)], 2, 0:7) == [4, 5]
        @test S.parse_cpu_list("0-3,8,10-11\n") == [0, 1, 2, 3, 8, 10, 11]
        @test S.parse_cpu_list("5") == [5]
        @test isempty(S.parse_cpu_list("\n"))
        @test_throws ArgumentError S.parse_cpu_list("1-2-3")
        @test S.format_cpu_list([3, 1, 2]) == "1,2,3"
        @test S.pin_job_cpus!(backend, "/cg/x", 4; allowed=0:7) == [0, 1, 2, 3]
        @test S.pin_job_cpus!(backend, "/cg/y", 4; allowed=0:7) == [4, 5, 6, 7]
        S.unpin_job_cpus!(backend, "/cg/x")
        @test S.pin_job_cpus!(backend, "/cg/z", 2; allowed=0:7) == [0, 1]
        S.unpin_job_cpus!(backend, "/cg/y"); S.unpin_job_cpus!(backend, "/cg/z")
        @test isempty(backend.pinned)

        # `prepare` wires the CPU request into `cpu.weight`, the memory limit
        # (not the request) into `memory.max`, and the CPU limit into the
        # affinity and the environment.
        let root = mktempdir()
            Base.write(joinpath(root, "memory.swap.max"), "max\n")
            prep_backend = LinuxSandboxBackend(mktempdir())
            prep_backend.root = root
            prep_backend.cpus = [2, 3, 5, 9]
            prep_brg = BuildkiteRunnerGroup("prep", Dict{String,Any}(
                "queues" => "build", "max_slots" => 1, "cachedir" => mktempdir(),
                "secrets_dir" => secrets,
                "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64",
                    "sandbox_capable" => "true"),
            ); host=:linux)
            rootfs = SandboxedBuildkiteAgent.eval(
                :(@artifact_str("buildkite-agent-rootfs", $(prep_brg.platform))))
            linux_persist_root_info(rootfs, SandboxedBuildkiteAgent.linux_persistence_hints(prep_brg);
                finder=(_, _) -> (mktempdir(), false))
            prep_job = sized_job("wired"; queue="build", tags=["sched_cpus=2", "sched_cpus_limit=3",
                "sched_mem_gib=1", "sched_mem_limit_gib=2"])
            prep_config = SchedulerConfig(mktempdir(), 0.01, 0.01, 900, 60.0, 4, 8, 0)
            alloc = SandboxedBuildkiteAgent.job_allocation(prep_brg, prep_job, prep_config)
            @test alloc == Allocation(2, 3, 1, 2, 0)
            prep_slot = Slot(prep_brg, 1)
            handle = prepare(prep_backend, prep_slot, prep_job,
                cache_plan(prep_slot, prep_job, :trusted), alloc)
            try
                @test read(joinpath(handle.cgroup_path, "cpu.weight"), String) == "200\n"
                @test read(joinpath(handle.cgroup_path, "memory.max"), String) == "$(2 * 1024^3)\n"
                @test read(joinpath(handle.cgroup_path, "memory.swap.max"), String) == "0\n"
                @test handle.config.env["SBA_CPUS"] == "2"
                @test handle.config.env["SBA_CPUS_LIMIT"] == "3"
                @test handle.config.env["SBA_MEM_GIB"] == "1"
                @test handle.config.env["SBA_MEM_LIMIT_GIB"] == "2"
                @test handle.cpuset == [2, 3, 5]
                # A cgroup that cannot be read after the agent was signalled (the
                # runner removing it meanwhile) leaves the stop unconfirmed.
                @test SandboxedBuildkiteAgent.stop_job(handle) == :not_acquired
                handle.launch.closed = false
                SandboxedBuildkiteAgent.commit_launch!(handle.launch)
                victim = run(`sleep 60`; wait=false)
                with_logger(NullLogger()) do
                    @test SandboxedBuildkiteAgent.stop_job(handle; kill_delay=0.1, agent_pids=_ -> [getpid(victim)],
                        job_pids=_ -> error("cgroup gone")) == :unconfirmed
                end
                wait(victim)
                @test victim.termsignal == Base.SIGQUIT
                # A kill that leaves something behind is unconfirmed, not failed.
                Base.write(joinpath(handle.cgroup_path, "cgroup.procs"), "99999999\n")
                with_logger(NullLogger()) do
                    @test SandboxedBuildkiteAgent.stop_job(handle; force=true, kill_timeout=0.2) ==
                        :unconfirmed
                end
                rm(joinpath(handle.cgroup_path, "cgroup.procs"))
                @test read(joinpath(handle.cgroup_path, "cpuset.cpus"), String) == "2,3,5\n"
                # With fewer CPUs left than the limit, the job is told what it got.
                narrow_job = sized_job("narrow"; queue="build", tags=["sched_cpus=1", "sched_cpus_limit=8",
                    "sched_mem_gib=1"])
                narrow = with_logger(NullLogger()) do
                    prepare(prep_backend, Slot(prep_brg, 2), narrow_job,
                        cache_plan(Slot(prep_brg, 2), narrow_job, :trusted), Allocation(1, 8, 1, 1, 0))
                end
                @test narrow.cpuset == [2, 3, 5, 9]
                @test narrow.config.env["SBA_CPUS_LIMIT"] == "4"
                @test narrow.alloc.cpus_limit == 4
                SandboxedBuildkiteAgent.unpin_job_cpus!(prep_backend, narrow.cgroup_path)
                rm(narrow.cgroup_path; recursive=true)
                # An unpinned job sees all of the scheduler's CPUs.
                unpinned_job = sized_job("unpinned"; queue="build")
                unpinned = prepare(prep_backend, Slot(prep_brg, 3), unpinned_job,
                    cache_plan(Slot(prep_brg, 3), unpinned_job, :trusted), Allocation(0))
                @test isempty(unpinned.cpuset)
                @test unpinned.config.env["SBA_CPUS_LIMIT"] == "4"
                rm(unpinned.cgroup_path; recursive=true)
            finally
                SandboxedBuildkiteAgent.unpin_job_cpus!(prep_backend, handle.cgroup_path)
                rm(handle.cgroup_path; recursive=true)
                empty!(linux_persist_root_cache)
            end
        end

        kill_root = mktempdir()
        kill_path = joinpath(kill_root, "cgroup.kill")
        Base.write(kill_path, "")
        @test kill_cgroup(kill_root)
        @test read(kill_path, String) == "1\n"

        # Without `cgroup.kill` (5.4), every process listed in `cgroup.procs` is
        # SIGKILLed until the cgroup is empty. A stand-in `cgroup.procs` is
        # emptied once its process has died, as the kernel would.
        procs_root = mktempdir()
        procs_path = joinpath(procs_root, "cgroup.procs")
        victim = run(`sleep 1000`; wait=false)
        Base.write(procs_path, "$(getpid(victim))\n")
        emptier = @async (wait(victim); Base.write(procs_path, ""))
        @test kill_cgroup(procs_root; timeout=10)
        wait(emptier)
        @test victim.termsignal == Base.SIGKILL
        # A process that does not go away fails the teardown, and the cgroup stays.
        Base.write(procs_path, "99999999\n")
        with_logger(NullLogger()) do
            @test !kill_cgroup(procs_root; timeout=0.2)
            @test !SandboxedBuildkiteAgent.remove_job_cgroup(procs_root; kill_timeout=0.2)
        end
        @test isdir(procs_root)
        # ... and a startup cleanup that cannot remove a stale job refuses to start.
        stuck_root = mktempdir()
        mkpath(joinpath(stuck_root, "job-stuck"))
        Base.write(joinpath(stuck_root, "job-stuck", "cgroup.procs"), "99999999\n")
        with_logger(NullLogger()) do
            @test_throws ErrorException SandboxedBuildkiteAgent.cleanup_job_cgroups(stuck_root;
                kill_timeout=0.2)
        end

        # A job cgroup whose setup fails is removed again.
        failing_root = mktempdir()
        mkpath(joinpath(failing_root, "job-broken", "cpu.weight"))
        @test_throws SystemError SandboxedBuildkiteAgent.create_job_cgroup(failing_root, "job-broken"; cpus=1)
        @test !ispath(joinpath(failing_root, "job-broken"))

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
end

# Needs a cgroup v2 subtree delegated to this process with the cpu, cpuset and
# memory controllers, as the scheduler's systemd unit has, e.g.
#   sudo systemd-run --wait --pipe -p User=$USER -p Delegate="cpu cpuset memory" \
#       -E SANDBOXED_BUILDKITE_AGENT_TEST_CGROUPS=1 ... julia --project test/runtests.jl
# This moves the test process into the subtree's `supervisor` cgroup.
@testset "Linux job cgroups (delegated)" begin
    if Sys.islinux() && get(ENV, "SANDBOXED_BUILDKITE_AGENT_TEST_CGROUPS", "") == "1"
        S = SandboxedBuildkiteAgent
        root = scheduler_cgroup_root()
        cpus = S.setup_job_cgroups!(root)
        @test cpus == S.parse_cpu_list(read(joinpath(root, "cpuset.cpus.effective"), String))
        @test issubset(["cpu", "cpuset", "memory"], split(read(joinpath(root, "cgroup.subtree_control"), String)))
        # pids and io, for the records' process counts and I/O, where delegated.
        for controller in ("pids", "io")
            @test (controller in S.cgroup_controllers(root)) ==
                  (controller in split(read(joinpath(root, "cgroup.subtree_control"), String)))
        end

        # A job's processes, inside the sandbox, run on its cpuset: the CPUs
        # are taken from the scheduler's cgroup (not necessarily from 0), and
        # `nproc` and the environment agree with it.
        secrets = mktempdir()
        Base.write(joinpath(secrets, "buildkite-agent-token"), "secret-token\n")
        brg = BuildkiteRunnerGroup("cpuset", Dict{String,Any}(
            "queues" => "build", "max_slots" => 2, "cachedir" => mktempdir(),
            "secrets_dir" => secrets,
            "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64",
                "sandbox_capable" => "true"),
        ); host=:linux)
        backend = LinuxSandboxBackend(mktempdir())
        backend.root = root
        backend.cpus = cpus
        width = min(2, length(cpus))
        probe_job = sized_job("cpuset-probe"; queue="build",
            tags=["sched_cpus=1", "sched_cpus_limit=$(width)", "sched_mem_gib=1"])
        # Another job holds the first CPUs, so this one starts further in.
        S.pin_job_cpus!(backend, "/other-job", 1)
        slot = Slot(brg, 1)
        handle = prepare(backend, slot, probe_job, cache_plan(slot, probe_job, :trusted),
            Allocation(1, width, 1, 1, 0))
        try
            @test handle.cpuset == cpus[2:width+1]
            @test S.parse_cpu_list(read(joinpath(handle.cgroup_path, "cpuset.cpus.effective"), String)) ==
                handle.cpuset
            probe = `/bin/sh -c 'grep Cpus_allowed_list /proc/self/status; nproc; printenv SBA_CPUS_LIMIT'`
            lines = split(strip(read(S.sandbox_command(handle; cmd=probe), String)), '\n')
            @test length(lines) == 3
            @test S.parse_cpu_list(last(split(lines[1], '\t'))) == handle.cpuset
            @test lines[2] == string(width)
            @test lines[3] == string(width)
        finally
            @test reap(handle) === true
            S.unpin_job_cpus!(backend, "/other-job")
        end
        @test !isdir(handle.cgroup_path)

        # Teardown kills the whole process tree, also one that keeps forking,
        # with `cgroup.kill` and without it (as on 5.4), and only then
        # reports the cgroup gone.
        for use_cgroup_kill in (true, false)
            path = S.create_job_cgroup(root, "job-teardown"; cpus=1, mem_bytes=S.gib_bytes(1))
            cmd = `sh -c 'sleep 1000 & while :; do sleep 1000 & sleep 0.01; done'`
            proc = run(wrap_command_in_cgroup_join_file(joinpath(path, "cgroup.procs"), cmd);
                wait=false)
            timedwait(() -> length(S.cgroup_pids(path)) >= 5, 10.0)
            @test length(S.cgroup_pids(path)) >= 5
            @test S.kill_cgroup(path; use_cgroup_kill)
            @test isempty(S.cgroup_pids(path))
            @test S.remove_job_cgroup(path)
            @test !isdir(path)
            wait(proc)
            @test proc.termsignal == Base.SIGKILL
        end

        # io accounting can be turned off with a restart, also when the
        # scheduler's cgroup still has io enabled from before: new job
        # cgroups then have no io.stat. The kernel's additive
        # `subtree_control` is what the fixtures above cannot show.
        if "io" in S.cgroup_controllers(root)
            S.setup_job_cgroups!(root)
            path = S.create_job_cgroup(root, "job-io-on"; cpus=1)
            @test isfile(joinpath(path, "io.stat"))
            @test S.remove_job_cgroup(path)
            restarted = LinuxSandboxBackend(mktempdir(); io_accounting=false)
            restarted.root = root
            S.setup_job_cgroups!(root; io_accounting=false)
            @test "io" in split(read(joinpath(root, "cgroup.subtree_control"), String))  # still on
            S.cleanup(restarted)
            @test !S.io_accounting_stuck(restarted)
            @test !("io" in split(read(joinpath(root, "cgroup.subtree_control"), String)))
            path = S.create_job_cgroup(root, "job-io-off"; cpus=1)
            @test !isfile(joinpath(path, "io.stat"))
            @test S.remove_job_cgroup(path)
        end
    end
end

@testset "Linux scheduler systemd service" begin
    unit_path = tempname()
    @test !scheduler_systemd_service_installed(; unit_path)
    Base.write(unit_path, "unit")
    @test scheduler_systemd_service_installed(; unit_path)

    # systemd 245 (the POWER9 hosts) has no `systemctl show -P`; an empty
    # state would read as stopped.
    fakebin = mktempdir()
    Base.write(joinpath(fakebin, "systemctl"), """
        #!/bin/sh
        for arg in "\$@"; do
            [ "\$arg" = -P ] && { echo "systemctl: invalid option -- 'P'" >&2; exit 1; }
        done
        case " \$* " in *" --property=ActiveState --value "*) echo active ;; *) exit 1 ;; esac
        """)
    chmod(joinpath(fakebin, "systemctl"), 0o755)
    withenv("PATH" => string(fakebin, ":", ENV["PATH"])) do
        @test SandboxedBuildkiteAgent.scheduler_systemd_active_state("sba.service") == "active"
    end

    config_path = tempname()
    Base.write(config_path, """
    [scheduler]

    [builder]
    backend = "linux-sandbox"
    queues = "build"
    max_slots = 2

    [builder.tags]
    os = "linux"
    arch = "x86_64"
    sandbox_capable = "true"
    """)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, config_path; host=:linux)
    unit = String(take!(io))
    @test occursin("Delegate=cpu cpuset memory pids io", unit)
    @test occursin("bin/sba --config=$(abspath(config_path)) scheduler", unit)
    @test !occursin("--backend", unit)
    @test !occursin("--dry-run", unit)
    # Auto-recover, but bounded so a fatal fault still latches `failed`.
    @test occursin("Restart=on-failure", unit)
    @test occursin("RestartSec=30", unit)
    @test !occursin("Restart=always", unit)
    # systemd only honours the start-limit keys in `[Unit]`, not `[Service]`.
    @test occursin("StartLimitIntervalSec=1h", first(split(unit, "[Service]")))
    @test occursin("StartLimitBurst=5", first(split(unit, "[Service]")))
    @test occursin("After=network-online.target", unit)
    @test occursin("Wants=network-online.target", unit)
    @test occursin("RuntimeDirectory=sandboxed-buildkite-agent", unit)
    stop_request = SandboxedBuildkiteAgent.stop_request_path(read_scheduler_config(config_path))
    @test occursin("ExecStop=/bin/sh -c '[ -n \"\$\$MAINPID\" ] || exit 0; touch \"$(stop_request)\"; while kill -0 \"\$\$MAINPID\"", unit)
    @test occursin("TimeoutStopSec=10min", unit)

    kvm_config_path = tempname()
    Base.write(kvm_config_path, """
    [scheduler]

    [windows]
    backend = "kvm"
    guest = "windows"
    queues = "build"
    max_slots = 2

    [windows.tags]
    os = "windows"
    arch = "x86_64"
    """)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, kvm_config_path; host=:linux)
    unit = String(take!(io))
    @test !occursin("Delegate=", unit)
    @test occursin("virsh -c qemu:///system list --name", unit)

    # `sba status` maps the supervisor's own report into a verdict.
    active = systemd_status_from_properties(Dict("ActiveState" => "active",
        "SubState" => "running", "Result" => "success", "ExecMainStatus" => "0"))
    @test active["running"] && active["state"] == "active" && active["detail"] == ""
    failed = systemd_status_from_properties(Dict("ActiveState" => "failed",
        "SubState" => "failed", "Result" => "exit-code", "ExecMainStatus" => "1"))
    @test !failed["running"] && failed["state"] == "failed"
    @test occursin("Result=exit-code", failed["detail"]) && occursin("exit status=1", failed["detail"])
    # An auto-restarted scheduler looks `active`; the count is the only trace.
    @test active["restarts"] == 0
    restarted = systemd_status_from_properties(Dict("ActiveState" => "active",
        "SubState" => "running", "Result" => "success", "ExecMainStatus" => "0",
        "NRestarts" => "3"))
    @test restarted["running"] && restarted["restarts"] == 3
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
    max_slots = 2
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
    @test occursin("bin/sba", plist)
    @test !occursin("--backend", plist)
    @test occursin("--config=$(abspath(config_path))", plist)
    @test first(findfirst("--config=$(abspath(config_path))", plist)) <
          first(findfirst(">scheduler<", plist))
    @test !occursin("--dry-run", plist)
    @test occursin("<string>$(logdir)/scheduler.log</string>", plist)
    # Respawn after an unclean exit only; a clean shutdown stays down.
    @test occursin("KeepAlive", plist)
    @test occursin("<key>SuccessfulExit</key><false />", plist)

    token_path = joinpath(mktempdir(), "buildkite-agent-token")
    Base.write(token_path, "secret-token\n")
    seatbelt_env = build_seatbelt_env(mktempdir(), mktempdir();
        agent_token_path=token_path,
        julia_arch="aarch64",
        alloc=Allocation(2))
    @test seatbelt_env["BUILDKITE_AGENT_TOKEN"] == "secret-token"
    @test seatbelt_env["BUILDKITE_PLUGIN_JULIA_ARCH"] == "aarch64"
    @test seatbelt_env["SBA_CPUS"] == "2"
    @test seatbelt_env["SBA_CPUS_LIMIT"] == "2"
    for var in ("SBA_MEM_GIB", "SBA_MEM_LIMIT_GIB", "JULIA_CPU_THREADS", "OMP_THREAD_LIMIT")
        @test !haskey(seatbelt_env, var)
    end
    whole_host = build_seatbelt_env(mktempdir(), mktempdir();
        agent_token_path=token_path,
        alloc=Allocation(4, 4, 6))
    @test whole_host["SBA_CPUS_LIMIT"] == "4"
    @test whole_host["SBA_MEM_GIB"] == "6"
    @test whole_host["SBA_MEM_LIMIT_GIB"] == "6"

    # macOS groups must set a tempdir; check it from the parsed config.
    if Sys.isapple()
        mac_group(extra) = BuildkiteRunnerGroup("macos", Dict{String,Any}(extra); host=:macos,
            total_cpus=Sys.CPU_THREADS)
        @test SandboxedBuildkiteAgent.check_macos_runner_configs([mac_group(Dict("tempdir" => "/private/var/tmp"))]) === nothing
        @test_throws ErrorException SandboxedBuildkiteAgent.check_macos_runner_configs([mac_group(Dict())])
    end

    # `sba status` maps `launchctl print` output into a verdict.
    running = launchctl_status_from_output("\tstate = running\n\tpid = 4321\n")
    @test running["running"] && running["state"] == "running" && running["detail"] == ""
    stopped = launchctl_status_from_output("\tstate = not running\n\tlast exit code = 1\n")
    @test !stopped["running"] && stopped["state"] == "stopped"
    @test stopped["detail"] == "last exit code=1"
    clean = launchctl_status_from_output("\tstate = not running\n\tlast exit code = 0\n")
    @test !clean["running"] && clean["detail"] == ""
    # launchd counts every launch since load, so the first run is not a restart.
    @test running["restarts"] == 0
    respawned = launchctl_status_from_output("\tstate = running\n\tpid = 4321\n\truns = 4\n")
    @test respawned["running"] && respawned["restarts"] == 4 - 1
end

@testset "macOS coredump launchd service" begin
    io = IOBuffer()
    generate_macos_corefile_launchd_plist(io, "%N-pid%P.core")
    plist = String(take!(io))
    @test occursin("<string>org.julialang.buildkite.corefile</string>", plist)
    @test occursin("<string>/usr/sbin/sysctl</string>", plist)
    @test occursin("<string>kern.corefile=%N-pid%P.core</string>", plist)

    io = IOBuffer()
    generate_macos_core_cleanup_launchd_plist(io)
    plist = String(take!(io))
    @test occursin("<string>org.julialang.buildkite.core-cleanup</string>", plist)
    @test occursin("<string>/cores</string>", plist)
    @test occursin("<string>core.*</string>", plist)
    @test occursin("<string>+60</string>", plist)
    @test occursin("<key>StartInterval</key>", plist)
    @test occursin("<integer>3600</integer>", plist)
end

@testset "macOS process table" begin
    M = SandboxedBuildkiteAgent
    # `KERN_PROCARGS2` buffers: argc, the executable path, NUL padding, the
    # arguments, then the environment.
    procargs(argc, path, args...; pad=3, env=["HOME=/x"]) =
        vcat(reinterpret(UInt8, [htol(Int32(argc))]), codeunits(path), zeros(UInt8, pad),
             reduce(vcat, [vcat(codeunits(a), 0x00) for a in [args..., env...]]; init=UInt8[]))
    @test M.parse_macos_procargs(procargs(3, "/usr/bin/perl", "perl", "-e", "sleep 1")) == "perl -e sleep 1"
    @test M.parse_macos_procargs(procargs(1, "/bin/sh", "sh"; pad=1, env=String[])) == "sh"
    # Arguments are shown as Apple's `ps` shows them in the C locale (strvis).
    @test M.parse_macos_procargs(procargs(3, "/bin/x", "x", "two words", "a\nb\tc\e\x7f\\ü")) ==
          "x two words a\\012b\\011c^[^?\\M-CM-<"
    @test M.macos_vis(UInt8[0x01, 0x1f, 0x20, 0x80, 0x85, 0x9f, 0xa0, 0xad, 0xe9, 0xff]) ==
          "^A^_ M^@M^EM^_\\240M--M-iM^?"
    # Truncated or nonsensical buffers give nothing.
    @test M.parse_macos_procargs(procargs(4, "/bin/x", "x", "y"; env=String[])) === nothing
    @test M.parse_macos_procargs(procargs(0, "/bin/x")) === nothing
    @test M.parse_macos_procargs(UInt8[1, 0]) === nothing
    @test M.parse_macos_procargs(vcat(procargs(1, "/bin/x"; env=String[]), codeunits("x"))) === nothing

    # An unrelated process carrying multi-line data that mentions a slot is
    # not the slot's: in the shown form, as in `ps`, the name is not a word.
    # The slot's own agent is.
    identity = MacOSProcessIdentity("default-host.1", "/tmp-root/default-host.1", "/cache/default-host.1")
    processes = [
        MacOSProcess(10, 1, 10, M.parse_macos_procargs(procargs(3, "/usr/bin/logger", "logger",
            "diagnostic\n--name=default-host.1\nend", "/cache/default-host.1\n")), "/"),
        MacOSProcess(11, 10, 10, "logger child", "/"),
        MacOSProcess(20, 1, 20, M.parse_macos_procargs(procargs(3, "/usr/local/bin/buildkite-agent",
            "buildkite-agent", "start", "--name=default-host.1")), "/"),
    ]
    @test processes[1].command == "logger diagnostic\\012--name=default-host.1\\012end /cache/default-host.1\\012"
    @test M.macos_reap_process_ids(processes, [identity]; self_pid=0) == [20]

    # The pid list is retried larger when it fills the buffer, and given up
    # on rather than returned partial.
    function growing(start, step)
        n = Ref(start)
        return pids -> begin
            pids === nothing && return n[]
            n[] += step
            count = min(n[], length(pids))
            pids[1:count] .= 1:count
            return count
        end
    end
    @test M.macos_all_pids(growing(100, 0)) == 1:100
    @test M.macos_all_pids(growing(100, 300)) == 1:700        # 356 and 712 slots
    @test_throws ErrorException M.macos_all_pids(growing(100, 10_000))

    Sys.isapple() || @test isempty(M.macos_process_table())
    if Sys.isapple()
        # The same processes as `ps`, for this user's processes that exist
        # throughout, and the same command lines. `ps` (setuid root) can read
        # every command line; this user cannot read those of setuid processes
        # such as `login`, which then show as `(name)`. Zombies (`<defunct>`
        # in `ps`) are left out: they have no short BSD info any more.
        bytes = [String(UInt8[b]) for b in 0x01:0xff]
        child = run(`perl -e "sleep 30" -- "two words" $("line1\nline2") $("tab\there") "" $(bytes)`; wait=false)
        try
            sleep(0.5)
            # Not a regex: command lines can hold invalid UTF-8.
            function psline(line)
                pid, rest = split(lstrip(line), ' '; limit=2)
                ppid, rest = split(lstrip(rest), ' '; limit=2)
                pgid, command = split(lstrip(rest), ' '; limit=2)
                return parse(Int, pid) => (parse(Int, ppid), parse(Int, pgid), String(command))
            end
            # Commands are rendered as in the C locale.
            ps() = Dict(psline(line) for line in split(read(addenv(`ps -wwaxo pid=,ppid=,pgid=,command=`,
                        "LC_ALL" => "C"), String), '\n'; keepempty=false))
            mine = Set(parse.(Int, split(read(`ps -U $(Libc.getuid()) -o pid=`, String))))
            before = ps()
            table = M.macos_process_table()
            after = ps()
            compared, mismatches = 0, []
            for p in table
                (p.pid in mine && get(before, p.pid, 0) == get(after, p.pid, 1)) || continue
                ppid, pgid, command = before[p.pid]
                (p.ppid, p.pgid) == (ppid, pgid) || push!(mismatches, (p, before[p.pid]))
                startswith(p.command, "(") && endswith(p.command, ")") && continue
                p.command == command || push!(mismatches, (p, before[p.pid]))
                compared += 1
            end
            @test isempty(mismatches)
            @test compared > 10
            listed = Set(p.pid for p in table)
            @test isempty([pid for (pid, b) in before if pid in mine && get(after, pid, nothing) == b &&
                           b[3] != "<defunct>" && !(pid in listed)])
            # Every byte value is shown as `ps` shows it.
            record = only(filter(p -> p.pid == getpid(child), table))
            @test record.command == before[getpid(child)][3]
            @test startswith(record.command, "perl -e sleep 30 -- two words line1\\012line2 tab\\011here  ^A ^B")
            @test record.ppid == getpid() && record.cwd == realpath(pwd())
        finally
            kill(child)
        end

        # Jobs cannot leave behind processes whose command lines the
        # scheduler's user cannot read: under the seatbelt profile macOS does
        # not let them run setuid programs (sudo, su, login, top, at, crontab,
        # ps, ... all fail with "Operation not permitted" on macOS 26.7). The
        # profile has no rule for this; the sandbox enforces it.
        if Sys.which("sandbox-exec") !== nothing
            root = realpath(mktempdir("/private/tmp"))
            identity = MacOSProcessIdentity("macos-test.1", joinpath(root, "temp"), joinpath(root, "cache"))
            mkpath.([joinpath(identity.temp_path, "tmp"), joinpath(identity.temp_path, "home"), identity.cache_path])
            env = build_seatbelt_env(identity.temp_path, identity.cache_path;
                agent_token_path=let path = joinpath(root, "token"); write(path, "token\n"); path end)
            script = raw"""
            cd /
            for program in /usr/bin/sudo /usr/bin/su /usr/bin/login /usr/bin/top /bin/ps; do
                "$program" -h </dev/null >/dev/null 2>&1; echo "$program $?"
            done
            /bin/echo plain
            """
            M.with_seatbelt(M.generate_buildkite_seatbelt_config, [identity.cache_path],
                            identity.temp_path) do sb_path
                out = read(setenv(ignorestatus(`sandbox-exec -f $sb_path /bin/bash -c $script`), env), String)
                @test out == "/usr/bin/sudo 126\n/usr/bin/su 126\n/usr/bin/login 126\n/usr/bin/top 126\n/bin/ps 126\nplain\n"
            end
            rm(root; recursive=true)
        end
    end
end

@testset "macOS process reaper selection" begin
    identity = MacOSProcessIdentity(
        "default-host.1",
        "/tmp/agent-tempdirs/default-host.1",
        "/cache/default-host.1",
    )
    other_identity = MacOSProcessIdentity(
        "default-host.10",
        "/tmp/agent-tempdirs/default-host.10",
        "/cache/default-host.10",
    )
    processes = MacOSProcess[
        MacOSProcess(10, 1, 10, "/julia/bin/sba --config=config.toml scheduler", nothing),
        MacOSProcess(20, 10, 10,
            "/artifact/buildkite-agent start --name=default-host.1 --sockets-path=/tmp/agent-tempdirs/default-host.1 --build-path=/cache/default-host.1/pipeline/trusted/build",
            nothing),
        MacOSProcess(21, 20, 21, "buildkite-agent bootstrap", nothing),
        MacOSProcess(22, 21, 22, "bash .buildkite/utilities/test_julia.sh",
            "/cache/default-host.1/pipeline/trusted/build"),
        MacOSProcess(30, 1, 30, "bash .buildkite/utilities/test_julia.sh",
            "/cache/default-host.1/pipeline/trusted/build"),
        MacOSProcess(31, 1, 31, "/cache/default-host.1/pipeline/trusted/build/usr/bin/julia -e Base.runtests()",
            nothing),
        MacOSProcess(40, 1, 40,
            "/artifact/buildkite-agent start --name=default-host.10 --sockets-path=/tmp/agent-tempdirs/default-host.10 --build-path=/cache/default-host.10/pipeline/trusted/build",
            "/cache/default-host.10/pipeline/trusted/build"),
        MacOSProcess(50, 1, 50, "/cache/default-host.10/pipeline/trusted/build/usr/bin/julia",
            nothing),
    ]

    @test macos_process_matches(processes[2], [identity])
    @test macos_process_matches(processes[4], [identity])
    @test !macos_process_matches(processes[7], [identity])
    @test !macos_process_matches(processes[8], [identity])
    @test macos_process_matches(processes[7], [other_identity])

    selected = macos_reap_process_ids(processes, [identity]; self_pid=999)
    @test Set(selected) == Set([20, 21, 22, 30, 31])
end

@testset "macOS SysV semaphore listing" begin
    output = """
    IPC status from <running system> as of Thu Oct 29 17:33:53 EDT 2026
    T     ID     KEY        MODE       OWNER    GROUP
    Semaphores:
    s  65536 0x4d1226fe --ra-r-----    julia    staff
    s  65537 0x00000000 --ra-------     root    wheel
    s  65538 0x4d0e8161 --ra-r-----    julia    staff
    s  65539 0x00000000 --ra-r-----    julia    staff

    """
    @test parse_ipcs_semaphores(output, "julia") == [65536, 65538]
    @test parse_ipcs_semaphores(output, "nobody") == Int[]
    @test parse_ipcs_semaphores("Semaphores:\n", "julia") == Int[]
end

@testset "macOS SysV semaphore cleanup" begin
    if Sys.isapple()
        # Not in $TMPDIR, where the scheduler refuses to keep its live records.
        mktempdir("/private/tmp") do root
            root = realpath(root)  # as the kernel reports the cwd
            brg = BuildkiteRunnerGroup("default", Dict{String,Any}(
                "queues" => "test",
                "max_slots" => 2,
                "tempdir" => joinpath(root, "tmp-root"),
                "cachedir" => joinpath(root, "cache-root"),
                "tags" => Dict{String,String}("os" => "macos", "arch" => "aarch64"),
            ); host=:macos, total_cpus=2)
            removals = Ref(0)
            backend = MacSeatbeltBackend(joinpath(root, "logs"), [brg];
                remove_semaphores=() -> removals[] += 1)
            job = Job("job", "pipeline", ["queue=test", "os=macos"])
            handles = map(1:2) do index
                slot = Slot(brg, index)
                prepare(backend, slot, job, cache_plan(slot, job, :trusted), Allocation(1))
            end

            # Only once the last job is reaped
            reap(handles[1])
            @test removals[] == 0
            reap(handles[2])
            @test removals[] == 1

            # Not while a job process survives
            survivor_dir = joinpath(handles[1].temp_path, "survivor")
            mkpath(survivor_dir)
            survivor = run(Cmd(`sleep 60`; dir=survivor_dir); wait=false)
            try
                sleep(0.5)
                lock(() -> remove_idle_macos_sysv_semaphores_locked(backend),
                    backend.active_jobs_lock)
                @test removals[] == 1
            finally
                kill(survivor)
                wait(survivor)
            end
            cleanup(backend)
            @test removals[] == 2
        end
    end
end

@testset "macOS backend cleanup identities" begin
    # Not in macOS's per-user temp dir, which jobs can write to, so `prepare`
    # accepts the log directory for the live resource record.
    root = mktempdir(Sys.isapple() ? "/private/tmp" : tempdir())
    hostname = SandboxedBuildkiteAgent.get_short_hostname()
    brg = BuildkiteRunnerGroup("default", Dict{String,Any}(
        "queues" => "test",
        "max_slots" => 2,
        "tempdir" => joinpath(root, "tmp-root"),
        "cachedir" => joinpath(root, "cache-root"),
        "tags" => Dict{String,String}("os" => "macos", "arch" => "x86_64"),
    ); host=:macos, total_cpus=12)

    temp_slots_root = joinpath(root, "tmp-root", "agent-tempdirs")
    cache_root = joinpath(root, "cache-root")
    current_names = ["default-$(hostname).1", "default-$(hostname).2"]
    retired_names = [
        "default-$(hostname).0",
        "default-$(hostname).3",
        "legacy-$(hostname).1",
    ]
    for name in current_names
        mkpath(joinpath(temp_slots_root, name))
        mkpath(joinpath(cache_root, name))
    end
    mkpath(joinpath(temp_slots_root, retired_names[1]))
    mkpath(joinpath(temp_slots_root, retired_names[2], "tmp"))
    mkpath(joinpath(cache_root, retired_names[2], "pipeline", "trusted", "build"))
    mkpath(joinpath(cache_root, retired_names[3]))

    foreign_name = "default-$(hostname)-foreign.3"
    malformed_name = "default-$(hostname).old"
    mkpath(joinpath(cache_root, foreign_name))
    mkpath(joinpath(cache_root, malformed_name))

    backend = MacSeatbeltBackend(joinpath(root, "logs"), [brg]; remove_semaphores=nothing)
    @test backend.cleanup_identities == [
        macos_slot_reaper_identity(Slot(brg, 1)),
        macos_slot_reaper_identity(Slot(brg, 2)),
    ]
    expected_retired = [
        MacOSProcessIdentity(name, joinpath(temp_slots_root, name),
            joinpath(cache_root, name))
        for name in retired_names
    ]
    @test macos_retired_reaper_identities(backend.cleanup_identities) ==
          expected_retired
    @test macos_agent_temp_path(Slot(brg, 1)) ==
          joinpath(root, "tmp-root", "agent-tempdirs",
              "default-$(SandboxedBuildkiteAgent.get_short_hostname()).1")
    @test macos_slot_cache_root(Slot(brg, 1)) ==
          joinpath(root, "cache-root",
              "default-$(SandboxedBuildkiteAgent.get_short_hostname()).1")

    # A reap that fails keeps the job counted as active; the retried reap that
    # succeeds uncounts it, once.
    reap_job = Job("reap-job", "pipeline", ["queue=test"])
    reap_handle = prepare(backend, Slot(brg, 1), reap_job, cache_plan(Slot(brg, 1), reap_job, :trusted),
        Allocation(1))
    @test backend.active_jobs == 1
    @test_throws ErrorException reap(reap_handle; reap_processes=_ -> error("ps failed"))
    @test backend.active_jobs == 1
    @test reap(reap_handle; reap_processes=_ -> Int[]) === true
    @test backend.active_jobs == 0
    @test reap(reap_handle; reap_processes=_ -> Int[]) === true
    @test backend.active_jobs == 0

    # A process-table read that fails after the agent was signalled leaves the
    # stop unconfirmed, not failed.
    stop_handle = prepare(backend, Slot(brg, 2), reap_job, cache_plan(Slot(brg, 2), reap_job, :trusted),
        Allocation(1))
    SandboxedBuildkiteAgent.commit_launch!(stop_handle.launch)
    victim = run(`sleep 60`; wait=false)
    stop_handle.agent_proc[] = victim
    with_logger(NullLogger()) do
        @test SandboxedBuildkiteAgent.stop_job(stop_handle; kill_delay=0.1, process_table=() -> error("ps failed")) == :unconfirmed
    end
    wait(victim)
    @test victim.termsignal == Base.SIGQUIT
    reap(stop_handle; reap_processes=_ -> Int[])

    empty_backend = MacSeatbeltBackend(joinpath(root, "logs"); remove_semaphores=nothing)
    @test isempty(empty_backend.cleanup_identities)
    setup_backend!(empty_backend, [Slot(brg, 1), Slot(brg, 2)])
    @test empty_backend.cleanup_identities == backend.cleanup_identities

    cleanup(backend)
    for name in retired_names
        @test !ispath(joinpath(temp_slots_root, name))
        @test !ispath(joinpath(cache_root, name))
    end
    for name in vcat(current_names, [foreign_name, malformed_name])
        @test isdir(joinpath(cache_root, name))
    end
end

@testset "macOS seatbelt concurrent slots" begin
    if Sys.isapple() && Sys.which("sandbox-exec") !== nothing
        mktempdir("/private/tmp") do root
            secrets = joinpath(root, "secrets")
            mkpath(secrets)
            token_path = joinpath(secrets, "buildkite-agent-token")
            write(token_path, "secret-token\n")

            brg = BuildkiteRunnerGroup("default", Dict{String,Any}(
                "queues" => "test",
                "max_slots" => 2,
                "priority" => 10,
                "tempdir" => joinpath(root, "tmp-root"),
                "cachedir" => joinpath(root, "cache-root"),
                "secrets_dir" => secrets,
                "tags" => Dict{String,String}("os" => "macos", "arch" => "x86_64"),
            ); host=:macos, total_cpus=12)
            backend = MacSeatbeltBackend(joinpath(root, "logs"); remove_semaphores=nothing)
            probe_job = Job("job", "pipeline", ["queue=test", "os=macos", "arch=x86_64"])

            function run_probe(slot_index)
                slot = Slot(brg, slot_index)
                plan = cache_plan(slot, probe_job, :trusted)
                handle = prepare(backend, slot, probe_job, plan, Allocation(6))
                observed = Dict{String,String}()
                seatbelt_setup(brg;
                    backend,
                    agent_name=handle.agent_name,
                    cache_path=handle.plan.cache_pool,
                    temp_path=handle.temp_path,
                    alloc=handle.alloc,
                    agent_token_path=token_path,
                ) do sb_path, seatbelt_env, build_path
                    script = raw"""
set -eu
printf '%s\n' "$HOME" > "$TMPDIR/home.txt"
printf '%s\n' "$TMPDIR" > "$HOME/tmpdir.txt"
printf '%s\n' "$SBA_CPUS_LIMIT" > "$BUILDKITE_PLUGIN_JULIA_CACHE_DIR/build/threads.txt"
printf '%s\n' "$BUILDKITE_PLUGIN_JULIA_CACHE_DIR" > "$BUILDKITE_PLUGIN_JULIA_CACHE_DIR/build/cache.txt"
pwd -P > "$BUILDKITE_PLUGIN_JULIA_CACHE_DIR/build/pwd.txt"
mkdir -p "$BUILDKITE_PLUGIN_JULIA_CACHE_DIR/depots/pipeline"
printf '%s\n' "$HOME" > "$BUILDKITE_PLUGIN_JULIA_CACHE_DIR/depots/pipeline/home.txt"
sleep 1
"""
                    run(setenv(Cmd(`sandbox-exec -f $sb_path /bin/sh -c $script`; dir=build_path), seatbelt_env))
                    observed["slot"] = slot.name
                    observed["cache"] = handle.plan.cache_pool
                    observed["temp"] = handle.temp_path
                    observed["build_path"] = realpath(build_path)
                    observed["home"] = strip(read(joinpath(handle.temp_path, "tmp", "home.txt"), String))
                    observed["tmpdir"] = strip(read(joinpath(handle.temp_path, "home", "tmpdir.txt"), String))
                    observed["threads"] = strip(read(joinpath(handle.plan.cache_pool, "build", "threads.txt"), String))
                    observed["cache_env"] = strip(read(joinpath(handle.plan.cache_pool, "build", "cache.txt"), String))
                    observed["pwd"] = strip(read(joinpath(handle.plan.cache_pool, "build", "pwd.txt"), String))
                    observed["depot_home"] = strip(read(joinpath(handle.plan.cache_pool, "depots", "pipeline", "home.txt"), String))
                end
                return observed
            end

            results = Vector{Dict{String,String}}(undef, 2)
            @sync for slot_index in 1:2
                @async results[slot_index] = run_probe(slot_index)
            end

            @test length(unique(result["cache"] for result in results)) == 2
            @test length(unique(result["temp"] for result in results)) == 2
            @test length(unique(result["home"] for result in results)) == 2
            @test length(unique(result["tmpdir"] for result in results)) == 2
            @test length(unique(result["pwd"] for result in results)) == 2
            for result in results
                @test result["threads"] == "6"
                @test result["cache_env"] == result["cache"]
                @test result["pwd"] == result["build_path"]
                @test result["depot_home"] == result["home"]
            end
        end
    else
        @test_skip "sandbox-exec unavailable"
    end
end

@testset "macOS job resources" begin
    M = SandboxedBuildkiteAgent
    # CPU is host-wide, so the busy histogram covers the host, whatever the job
    # was charged, and the summary says so.
    source = M.MacOSResourceSource(MacOSProcessIdentity("x", "/x/t", "/x/c"); host_cpus=8)
    @test M.MacOSResourceSource(MacOSProcessIdentity("x", "/x/t", "/x/c")).host_cpus == length(Sys.cpu_info())
    sampler = M.ResourceSampler(source; context=Dict{String,Any}("cpus" => 4, "cpus_limit" => 4, "mem_gib" => 0, "mem_limit_gib" => 0,
                                                                  "slot" => "s"))
    @test length(sampler.busy) == 9
    sampler.cpu_first = sampler.cpu_last = 0.0
    sampler.cpu_last_ns = UInt64(10^9)
    record = @lock sampler.lock M.resource_record_locked(sampler)
    @test record["host_cpus"] == 8
    @test startswith(M.resource_summary(record), "Resources: CPU 0.0 avg, 0 peak (whole host, 8 CPUs; 4 requested)")
    # The record must be out of the job's reach.
    @test M.check_macos_live_path("/logs/live/s.1"; temp_path="/tmp-root/s.1", cache_path="/cache/s.1") === nothing
    @test_throws ErrorException M.check_macos_live_path("/cache/s.1/logs/live/s.1";
        temp_path="/tmp-root/s.1", cache_path="/cache/s.1")
    @test_throws ErrorException M.check_macos_live_path("/private/var/folders/xy/T/logs/live/s.1";
        temp_path="/tmp-root/s.1", cache_path="/cache/s.1")
    @test_throws ErrorException M.check_macos_live_path("/Volumes/JuliaCI/logs/live/s.1";
        temp_path="/tmp-root/s.1", cache_path="/cache/s.1")

    if Sys.isapple() && Sys.which("sandbox-exec") !== nothing
        # The real source, on processes running in a slot's temp dir (as the
        # reaper finds them): host-wide CPU, the processes' summed footprint.
        root = realpath(mktempdir("/private/tmp"))
        identity = MacOSProcessIdentity("macos-test.1", joinpath(root, "temp"), joinpath(root, "cache"))
        mkpath(identity.temp_path)
        live = joinpath(root, "logs", "live", "macos-test.1")
        mkpath(live)
        source = M.MacOSResourceSource(identity; live_dir=live, active_jobs=() -> 2)
        hold = `perl -e '$x = "x" x (64 << 20); sleep 30'`
        procs = [run(Cmd(hold; dir=identity.temp_path); wait=false) for _ in 1:2]
        try
            sleep(1)
            s = M.sample_resources(source)
            @test s.cpu_seconds > 0
            @test s.wait_seconds === s.total_bytes === s.swap_bytes === nothing
            @test s.needed_bytes > 2 * 64 * 1024^2
            details = M.resource_details(source)
            @test details["peak_processes"] == 2
            @test details["peak_process_footprint_bytes"] > 64 * 1024^2
            @test details["peak_host_used_bytes"] > 0 && details["peak_swap_used_bytes"] >= 0
            @test details["peak_memory_pressure"] in ("normal", "warn", "critical")
            @test details["peak_jobs"] == 2
            @test details["efficiency_cpus"] == M.macos_efficiency_cpus()
        finally
            foreach(kill, procs)
            foreach(wait, procs)
        end
        @test M.sample_resources(source).needed_bytes == 0

        # The job reads the record through SBA_RESOURCES_FILE and cannot change it.
        sampler = M.ResourceSampler(source; context=M.job_resource_context(;
            job=Job("job-1", "pipeline-1", ["queue=test"]), slot="macos-test.1", group="macos",
            queue="test", alloc=M.Allocation(4), host="host"))
        M.sample_resources!(sampler)
        file = joinpath(live, M.LIVE_RECORD_NAME)
        @test startswith(readline(file), "Resources: ")
        env = build_seatbelt_env(identity.temp_path, identity.cache_path;
            agent_token_path=let path = joinpath(root, "token"); write(path, "token\n"); path end,
            resources_file=file)
        @test env["SBA_RESOURCES_FILE"] == file
        mkpath.([joinpath(identity.temp_path, "tmp"), joinpath(identity.temp_path, "home"), identity.cache_path])
        M.with_seatbelt(M.generate_buildkite_seatbelt_config, [identity.cache_path],
                        identity.temp_path; readable=[live]) do sb_path
            script = raw"""
            head -n 1 "$SBA_RESOURCES_FILE"
            touch "$SBA_RESOURCES_FILE" 2>/dev/null && echo "touched"
            echo x > "$(dirname "$SBA_RESOURCES_FILE")/other" 2>/dev/null && echo "created"
            true
            """
            out = read(setenv(`sandbox-exec -f $sb_path /bin/sh -c $script`, env), String)
            @test startswith(out, "Resources: ") && countlines(IOBuffer(out)) == 1 && !occursin(r"touched|created", out)
        end
        M.with_seatbelt(M.generate_buildkite_seatbelt_config, [identity.cache_path],
                        identity.temp_path) do sb_path
            @test !success(setenv(`sandbox-exec -f $sb_path /bin/cat $file`, env))
        end
        rm(root; recursive=true)
    end
end
