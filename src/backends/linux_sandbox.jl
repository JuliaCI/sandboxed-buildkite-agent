# This only exists so that we can avoid compile-time-checking of lazy artifact loading
artifact_lookup(name) = @artifact_str(name)

mutable struct LinuxSandboxBackend <: PlatformBackend
    logdir::String
    root::String
    cleanup_paths::Vector{String}
    # The CPUs jobs may be placed on: the scheduler cgroup's `cpuset.cpus.effective`.
    cpus::Vector{Int}
    # The cpuset of each running job, by job cgroup path.
    pinned::Dict{String,Vector{Int}}
    pinned_lock::ReentrantLock

    LinuxSandboxBackend(logdir::String) =
        new(logdir, "", String[], Int[], Dict{String,Vector{Int}}(), ReentrantLock())
end

# The `n` least-used CPUs of `allowed`, counting the CPUs of the running jobs,
# lowest first, so concurrent jobs get disjoint CPUs while there are enough.
function choose_job_cpus(pinned, n::Integer, allowed::AbstractVector{<:Integer})
    use = Dict{Int,Int}(cpu => 0 for cpu in allowed)
    for cpus in pinned, cpu in cpus
        haskey(use, cpu) && (use[cpu] += 1)
    end
    chosen = sort(collect(keys(use)); by=cpu -> (use[cpu], cpu))
    return sort!(chosen[1:min(Int(n), length(chosen))])
end

# Every job runs on a cpuset of `cpus_limit` CPUs. Julia's `--threads auto`,
# libuv's available parallelism and `nproc` follow the CPU affinity, which the
# cpuset bounds, not `JULIA_CPU_THREADS`: an unconstrained job sees every host
# CPU (an i686 test process then starts a thread per CPU and runs out of
# address space). The cpuset bounds a job's width, not its share: overlapping
# sets are fine, and `cpu.weight` still divides the CPUs under contention.
# Unlike an affinity mask set by a wrapper, the kernel enforces it for every
# process of the job, and pinning a thread outside it fails instead of escaping.
function pin_job_cpus!(backend::LinuxSandboxBackend, key::String, n::Integer;
                       allowed::AbstractVector{<:Integer}=backend.cpus)
    lock(backend.pinned_lock) do
        cpus = choose_job_cpus(values(backend.pinned), n, allowed)
        backend.pinned[key] = cpus
        return cpus
    end
end

unpin_job_cpus!(backend::LinuxSandboxBackend, key::String) =
    lock(() -> (delete!(backend.pinned, key); nothing), backend.pinned_lock)

# A cgroup CPU list such as "0-3,8,10-11".
function parse_cpu_list(text::AbstractString)
    cpus = Int[]
    for part in split(strip(text), ','; keepempty=false)
        bounds = split(part, '-')
        length(bounds) <= 2 || throw(ArgumentError("invalid CPU list '$(text)'"))
        append!(cpus, parse(Int, bounds[1]):parse(Int, bounds[end]))
    end
    return sort!(unique!(cpus))
end

format_cpu_list(cpus) = join(sort(collect(cpus)), ",")

function check_linux_sandbox_runner_configs(brgs::Vector{BuildkiteRunnerGroup})
    for brg in brgs
        tagtrue(brg, name) = get(brg.tags, name, "false") == "true"

        # Check that we self-identify as `sandbox.jl`
        if !tagtrue(brg, "sandbox_capable")
            error("Refusing to start up `sandbox.jl` runner '$(brg.name)' that does not self-identify through tags!")
        end
    end
    return nothing
end

function check_linux_host_config()
    check_coredumps()
    check_zen_workaround()
    check_sysctl_params()
    return nothing
end

function setup_linux_host_config!()
    setup_coredumps()
    setup_zen_workaround()
    setup_sysctl_params()
    check_linux_host_config()
    return nothing
end

function check_linux_sandbox_configs(brgs::Vector{BuildkiteRunnerGroup})
    check_linux_sandbox_runner_configs(brgs)
    check_linux_host_config()
    return nothing
end

function setup_linux_sandbox_configs!(brgs::Vector{BuildkiteRunnerGroup})
    check_linux_sandbox_runner_configs(brgs)
    setup_linux_host_config!()
    return nothing
end

check_config(::LinuxSandboxBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    check_linux_sandbox_configs(brgs)

setup_config!(::LinuxSandboxBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    setup_linux_sandbox_configs!(brgs)

function scheduler_cgroup_root(;
                               cgroup_file::String="/proc/self/cgroup",
                               cgroup_mount::String="/sys/fs/cgroup")
    for line in eachline(cgroup_file)
        if startswith(line, "0::")
            rel = chomp(line[4:end])
            return rel == "/" ? cgroup_mount : string(cgroup_mount, rel)
        end
    end
    error("Unable to resolve scheduler cgroup root from $(cgroup_file)")
end

function cgroup_controllers(root::String)
    controllers_path = joinpath(root, "cgroup.controllers")
    isfile(controllers_path) || error("$(root) is not a cgroup-v2 directory")
    return Set(split(strip(read(controllers_path, String))))
end

function require_cgroup_controllers(root::String, controllers)
    missing_controllers = setdiff(controllers, cgroup_controllers(root))
    if !isempty(missing_controllers)
        error("Linux scheduler unit needs Delegate=$(join(controllers, ' ')) (missing: $(join(sort(collect(missing_controllers)), ' '))); run `bk reinstall`")
    end
    return nothing
end

# The scheduler and its backend tasks get the weight of ten CPUs, so job load
# cannot starve polling, process supervision and cgroup teardown.
const SUPERVISOR_CPU_WEIGHT = 1000

# cgroup v2's default weight is 100; a job gets that much per requested CPU, so
# under contention CPU time is shared in proportion to requests while idle CPUs
# remain available to any job. Jobs of groups that charge no CPUs weigh as one.
job_cpu_weight(cpus::Integer) = clamp(100 * max(Int(cpus), 1), 1, 10_000)

const JOB_CGROUP_CONTROLLERS = ["cpu", "cpuset", "memory"]

# Enables the job cgroups' controllers below `root` and returns the CPUs jobs
# may be placed on. Without the cpuset controller jobs would run unconstrained
# (see `pin_job_cpus!`), so its absence stops the scheduler.
function setup_job_cgroups!(root::String)
    require_cgroup_controllers(root, JOB_CGROUP_CONTROLLERS)
    supervisor = joinpath(root, "supervisor")
    mkpath(supervisor)
    write(joinpath(supervisor, "cgroup.procs"), string(getpid(), "\n"))
    write(joinpath(root, "cgroup.subtree_control"),
        join(string.("+", JOB_CGROUP_CONTROLLERS), " ") * "\n")
    enabled = split(read(joinpath(root, "cgroup.subtree_control"), String))
    missing_controllers = setdiff(JOB_CGROUP_CONTROLLERS, enabled)
    isempty(missing_controllers) ||
        error("Unable to enable the $(join(missing_controllers, ", ")) controller(s) for job cgroups in $(root)")
    write(joinpath(supervisor, "cpu.weight"), string(SUPERVISOR_CPU_WEIGHT, "\n"))
    cpus = parse_cpu_list(read(joinpath(root, "cpuset.cpus.effective"), String))
    isempty(cpus) && error("The scheduler's cgroup $(root) has no CPUs in cpuset.cpus.effective")
    return cpus
end

has_swap_accounting(cgroup::String) = isfile(joinpath(cgroup, "memory.swap.max"))

function create_job_cgroup(root::String, name::String; cpus::Integer=0, mem_bytes::Integer=0,
                           cpuset::AbstractVector{<:Integer}=Int[])
    job_root = joinpath(root, name)
    mkpath(job_root)
    try
        write(joinpath(job_root, "cpu.weight"), string(job_cpu_weight(cpus), "\n"))
        isempty(cpuset) || write(joinpath(job_root, "cpuset.cpus"), format_cpu_list(cpuset) * "\n")
        if mem_bytes > 0
            write(joinpath(job_root, "memory.max"), string(mem_bytes, "\n"))
            # Without this, a job over its limit swaps instead of being OOM-killed,
            # and its paging slows down every other job on the host.  Kernels booted
            # without swap accounting (5.4 on the POWER9 hosts) have no
            # `memory.swap.*` files; there the job may still swap past its limit.
            if has_swap_accounting(root)
                write(joinpath(job_root, "memory.swap.max"), "0\n")
            end
            # No `memory.oom.group`: the job's agent shares this cgroup, and killing
            # it along with the job loses the job's log and exit status. The kernel
            # picks the largest process instead, and the agent reports the failure.
        end
    catch
        # Nothing runs in it yet, so it can be removed right away.
        remove_job_cgroup(job_root)
        rethrow()
    end
    return job_root
end

# Counters from a cgroup's `memory.events`, empty without the memory controller.
function cgroup_memory_events(path::AbstractString)
    events = Dict{String,Int}()
    file = joinpath(path, "memory.events")
    isfile(file) || return events
    for line in eachline(file)
        fields = split(line)
        length(fields) == 2 || continue
        value = tryparse(Int, fields[2])
        value === nothing || (events[fields[1]] = value)
    end
    return events
end

# Record OOM kills before the cgroup and its counters disappear.
function log_job_oom_events(path::AbstractString; log_path::Union{Nothing,String}=nothing)
    events = cgroup_memory_events(path)
    get(events, "oom_kill", 0) > 0 || get(events, "oom", 0) > 0 || return nothing
    limit = try
        strip(read(joinpath(path, "memory.max"), String))
    catch
        "unknown"
    end
    @warn("Job hit its memory limit", cgroup=path, memory_max=limit,
        oom=get(events, "oom", 0), oom_kill=get(events, "oom_kill", 0))
    if log_path !== nothing
        try
            open(log_path, "a") do log
                println(log, "sandboxed-buildkite-agent: the job hit its memory limit ",
                    "(memory.max=$(limit)); the kernel OOM-killed $(get(events, "oom_kill", 0)) process(es).")
            end
        catch
        end
    end
    return nothing
end

const LINUX_CGROUP_REMOVE_TIMEOUT = 5.0
# How long killing a job's processes may take before its teardown counts as failed.
const LINUX_CGROUP_KILL_TIMEOUT = 10.0

"""
    kill_cgroup(path; timeout, use_cgroup_kill=true)

SIGKILL every process in the cgroup `path` and below, and wait until none is
left. Returns whether the cgroup was confirmed empty within `timeout` seconds.
Kernels before 5.14 (5.4 on the POWER9 hosts) have no `cgroup.kill`; there the
processes listed in `cgroup.procs` are killed one by one, repeatedly, since a
process can fork between the listing and the kill.
"""
function kill_cgroup(path::String; timeout::Real=LINUX_CGROUP_KILL_TIMEOUT,
                     use_cgroup_kill::Bool=true)
    isdir(path) || return true
    kill_path = joinpath(path, "cgroup.kill")
    if use_cgroup_kill && isfile(kill_path)
        try
            write(kill_path, "1\n")
        catch err
            @warn("Unable to write cgroup.kill; killing the cgroup's processes one by one",
                path, exception=(err, catch_backtrace()))
        end
    end
    deadline = time() + Float64(timeout)
    while true
        pids = cgroup_pids(path)
        isempty(pids) && return true
        foreach(pid -> ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGKILL), pids)
        time() >= deadline && return false
        sleep(0.05)
    end
end

function remove_cgroup_tree(path::String)
    isdir(path) || return nothing
    for child in readdir(path; join=true)
        isdir(child) && remove_cgroup_tree(child)
    end
    rm(path)
    return nothing
end

"""
    remove_job_cgroup(path; timeout, kill_timeout)

Kill the processes of a job cgroup and remove it. Returns whether the cgroup is
gone; when it is not, processes of the job may still run, and the caller must
not hand its CPUs or slot to another job.
"""
function remove_job_cgroup(path::String; timeout::Real=LINUX_CGROUP_REMOVE_TIMEOUT,
                           kill_timeout::Real=LINUX_CGROUP_KILL_TIMEOUT)
    isdir(path) || return true
    emptied = try
        kill_cgroup(path; timeout=kill_timeout)
    catch err
        @error("Unable to kill job cgroup", path, exception=(err, catch_backtrace()))
        false
    end
    if !emptied
        @error("Processes of a job survived being killed", path, pids=cgroup_pids(path))
        return false
    end

    deadline = time() + Float64(timeout)
    last_error = nothing
    while isdir(path)
        try
            remove_cgroup_tree(path)
            return true
        catch err
            last_error = (err, catch_backtrace())
            time() >= deadline && break
            sleep(0.1)
        end
    end
    isdir(path) || return true
    @error("Unable to remove job cgroup", path, exception=last_error)
    return false
end

# Jobs of a previous scheduler; one that survives would run unaccounted, so
# the scheduler does not start.
function cleanup_job_cgroups(root::String; kill_timeout::Real=LINUX_CGROUP_KILL_TIMEOUT)
    isempty(root) && return nothing
    isdir(root) || return nothing
    survivors = String[]
    for name in sort(readdir(root))
        startswith(name, "job-") || continue
        path = joinpath(root, name)
        isdir(path) || continue
        @warn("Removing stale Linux job cgroup", path)
        remove_job_cgroup(path; kill_timeout) || push!(survivors, path)
    end
    isempty(survivors) ||
        error("Refusing to launch Linux jobs; stale job cgroups survived cleanup: $(join(survivors, ", "))")
    return nothing
end

function cleanup_linux_host_path(path::AbstractString)
    try
        Base.Filesystem.prepare_for_deletion(path)
        rm(path; force=true, recursive=true)
    catch err
        @warn("Unable to clean host path", path, exception=(err, catch_backtrace()))
    end
    return nothing
end

function wrap_command_in_cgroup_join_file(join_file::String, cmd::Cmd)
    wrapper_path = joinpath(@__DIR__, "assets", "host_cgroup_wrapper.sh")
    wrapped_cmd = Cmd(
        Cmd(vcat([wrapper_path, join_file], cmd.exec));
        dir=cmd.dir,
        ignorestatus=cmd.ignorestatus,
    )
    if cmd.env === nothing
        return wrapped_cmd
    end
    return setenv(wrapped_cmd, cmd.env)
end

function Sandbox.SandboxConfig(brg::BuildkiteRunnerGroup;
                       agent_name::String,
                       cache_path::String,
                       shared_cache_path::Union{String,Nothing},
                       temp_path::String,
                       alloc::Allocation = Allocation(Sys.CPU_THREADS),
                       rootfs_dir::String = @artifact_str("buildkite-agent-rootfs", brg.platform),
                       agent_token_path::String = joinpath(secrets_dir(brg), "buildkite-agent-token"),
                       verbose::Bool = brg.verbose,
                       )
    repo_root = REPO_ROOT

    # Set read-only mountings for rootfs and hooks
    ro_maps = Dict(
        # Mount in rootfs
        "/" => rootfs_dir,

        # Mount in hooks
        "/hooks" => joinpath(repo_root, "agent", "hooks"),

        # Mount in an up-to-date agent binary (served from our artifact!), rather
        # than relying on the ancient apt-installed copy baked into the rootfs.
        # The agent is a statically-linked Go binary, so the bare binary suffices.
        "/usr/bin/buildkite-agent" => artifact_lookup("buildkite-agent/buildkite-agent"),

        # Mount in a machine-id file that will be consistent across runs, but unique to each agent
        "/etc/machine-id" => joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id"),
    )
    # Set read-write mountings for our `/cache` directory
    rw_maps = Dict(
        "/cache" => cache_path,
		"/persist" => agent_persist_dir(brg, agent_name),
        "/tmp" => temp_path,
    )

    if shared_cache_path !== nothing
        rw_maps["/sharedcache"] = shared_cache_path
    end

    # Environment mappings
    env_maps = Dict(
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => "/cache/julia-buildkite-plugin",
        "BUILDKITE_AGENT_TOKEN" => String(chomp(String(read(agent_token_path)))),
        "BUILDKITE_PLUGIN_JULIA_ARCH" => brg.tags["arch"],
        "HOME" => "/root",
		"SHELL" => "/bin/bash",

        # For anyone who wants to do nested sandboxing, tell them to store
        # persistent data here instead of in `/tmp`, since that's an overlayfs
        "SANDBOX_PERSISTENCE_DIR" => "/persist",
        "FORCE_SANDBOX_MODE" => "unprivileged",

        # Give the job a sane, `/usr/local/bin`-first PATH. Without this the
        # agent starts with no PATH and hands jobs a minimal `:/usr/bin`; the
        # JuliaCI sandbox plugin then *appends* `/usr/local/bin` which conflicts
        # with our rootfs images putting a toolchain in `/usr/local`.
        "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    )

    # Unpinned groups without `cpus_limit` leave this unset so the nproc hook
    # derives it; setting it to 0 just makes Julia warn and fall back to the
    # host count. `OMP_THREAD_LIMIT` makes coreutils `nproc` report the same
    # number, so build scripts that size `make -j` from it agree with Julia.
    if alloc.cpus_limit > 0
        env_maps["JULIA_CPU_THREADS"] = string(alloc.cpus_limit)
        env_maps["OMP_THREAD_LIMIT"] = string(alloc.cpus_limit)
    end

    return SandboxConfig(
        ro_maps,
        rw_maps,
        env_maps;
        stdin,
        stdout,
        stderr,
        # We keep ourselves as `root` so that we can unmount within the sandbox
        # uid=Sandbox.getuid(),
        # gid=Sandbox.getgid(),
        verbose=verbose,
        multiarch=[brg.platform],
    )
end

function host_paths_to_create(::LinuxSandboxBackend, brg, config)
    paths = String[
        joinpath(config.mounts["/cache"].host_path, "build"),
        joinpath(config.mounts["/cache"].host_path, "sandbox_persistence"),
        config.mounts["/tmp"].host_path,
    ]

    if haskey(config.mounts, "/sharedcache")
        push!(paths, config.mounts["/sharedcache"].host_path)
    end

    return paths
end

function host_paths_to_cleanup(::LinuxSandboxBackend, brg, config, agent_name)
    return String[
        # We clean out our `/cache/build` directory every time
        joinpath(config.mounts["/cache"].host_path, "build"),

        # We clean out our persistent state dir, because we don't actually want persistence,
        # but we can't handle having some things live on a `tmp` mount and others not.
        agent_persist_dir(brg, agent_name),

        # We clean out our `/tmp` directory every time
        config.mounts["/tmp"].host_path,
    ]
end

const linux_persist_root_lock = ReentrantLock()
const linux_persist_root_cache = Dict{Tuple{String,Tuple{Vararg{String}}},Tuple{String,Bool}}()

function linux_persistence_hints(brg)
    persistence_hints = String[]
    if persistence_dir(brg) !== nothing
        push!(persistence_hints, persistence_dir(brg))
    end
    push!(persistence_hints, cachedir(brg))
    return persistence_hints
end

function linux_persist_root_info(rootfs_dir::String, persistence_hints::Vector{String};
                                 finder=Sandbox.find_persist_dir_root)
    key = (rootfs_dir, Tuple(persistence_hints))
    return lock(linux_persist_root_lock) do
        get!(linux_persist_root_cache, key) do
            persist_root, userxattr = finder(rootfs_dir, persistence_hints)
            if persist_root === nothing
                error("""
                    No usable persistence directory: none of the candidate paths are on a
                    filesystem that can host an overlayfs upperdir.
                    Tried (in order): $(join(persistence_hints, ", ")).""")
            end
            return (persist_root, userxattr)
        end
    end
end

function linux_persist_root_info(brg)
    persistence_hints = linux_persistence_hints(brg)
    rootfs_dir = @artifact_str("buildkite-agent-rootfs", brg.platform)
    return linux_persist_root_info(rootfs_dir, persistence_hints)
end

function agent_persist_info(brg, agent_name)
    # Once we've found a good persistence root, go into an agent-specific location.
    persist_root, userxattr = linux_persist_root_info(brg)
    return joinpath(persist_root, string("persist-", agent_name)), userxattr
end

function agent_persist_dir(brg, agent_name)
    return first(agent_persist_info(brg, agent_name))
end

function cleanup(backend::LinuxSandboxBackend)
    cleanup_job_cgroups(backend.root)
    cleanup_linux_host_path.(backend.cleanup_paths)
    return nothing
end

function setup_backend!(backend::LinuxSandboxBackend, slots)
    backend.root = scheduler_cgroup_root()
    backend.cpus = setup_job_cgroups!(backend.root)
    backend.cleanup_paths = linux_startup_cleanup_paths(slots)
    return nothing
end

mutable struct LinuxSandboxHandle
    backend::LinuxSandboxBackend
    slot::Slot
    job::Job
    plan::CachePlan
    alloc::Allocation
    config::SandboxConfig
    agent_name::String
    log_path::String
    cgroup_path::String
    # The job cgroup's `cpuset.cpus`; empty for jobs without a CPU limit.
    cpuset::Vector{Int}
    launch::LaunchGate
end

function job_cgroup_name(slot::Slot, job::Job)
    slot_name = safe_path_component(slot.name, "unknown-slot")
    job_id = safe_path_component(job.id, "unknown-job")
    return string("job-", slot_name, "-", job_id)
end

function linux_agent_temp_path(slot::Slot)
    return joinpath(tempdir(slot.brg), "agent-tempdirs", slot.name)
end

function linux_startup_cleanup_paths(slots)
    paths = String[]
    for slot in slots
        push!(paths, linux_agent_temp_path(slot))
        try
            push!(paths, agent_persist_dir(slot.brg, slot.name))
        catch err
            @warn("Unable to resolve Linux persistence dir for cleanup",
                slot=slot.name, exception=(err, catch_backtrace()))
        end
    end
    return sort(unique(paths))
end

function prepare(backend::LinuxSandboxBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    mkpath(plan.cache_pool)
    plan.ccache_pool === nothing || mkpath(plan.ccache_pool)
    isempty(backend.root) && error("LinuxSandboxBackend has not been set up")

    agent_name = slot.name
    temp_path = linux_agent_temp_path(slot)
    log_path = job_log_path(backend.logdir, agent_name, job)
    cgroup_path = joinpath(backend.root, job_cgroup_name(slot, job))
    cpuset = alloc.cpus_limit > 0 ? pin_job_cpus!(backend, cgroup_path, alloc.cpus_limit) : Int[]
    local config
    try
        # The job is told the width it got: fewer CPUs than its limit only when
        # the scheduler's cgroup has fewer CPUs than `total_cpus`.
        if !isempty(cpuset) && length(cpuset) != alloc.cpus_limit
            @warn("Job gets fewer CPUs than its limit", slot=slot.name, job=job.id,
                cpus_limit=alloc.cpus_limit, cpuset=format_cpu_list(cpuset))
            alloc = Allocation(alloc.cpus, length(cpuset), alloc.mem_gib, alloc.mem_limit_gib,
                alloc.reserved_mem_gib)
        end
        config = SandboxConfig(slot.brg;
            agent_name,
            cache_path=plan.cache_pool,
            shared_cache_path=plan.ccache_pool,
            temp_path,
            alloc,
        )
        create_job_cgroup(backend.root, job_cgroup_name(slot, job);
            cpus=alloc.cpus,
            mem_bytes=gib_bytes(alloc.mem_limit_gib),
            cpuset)
    catch
        unpin_job_cpus!(backend, cgroup_path)
        rethrow()
    end
    handle = LinuxSandboxHandle(backend, slot, job, plan, alloc, config, agent_name, log_path, cgroup_path, cpuset,
        LaunchGate())

    try
        cleanup_host_paths(handle)
        mkpath.(host_paths_to_create(backend, slot.brg, config))
        write_machine_id(agent_name)
        mkpath(dirname(log_path))
        return handle
    catch
        reap(handle)
        rethrow()
    end
end

function write_machine_id(agent_name::String)
    machine_id_path = joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id")
    mkpath(dirname(machine_id_path))
    write(machine_id_path, bytes2hex(sha1(agent_name))[1:32])
end

function cleanup_host_paths(handle::LinuxSandboxHandle)
    for path in host_paths_to_cleanup(handle.backend, handle.slot.brg, handle.config, handle.agent_name)
        cleanup_linux_host_path(path)
    end
end

# The job's agent (or, for tests, `cmd`) in the sandbox, joining the job cgroup.
function sandbox_command(handle::LinuxSandboxHandle; cmd::Union{Nothing,Cmd}=nothing)
    brg = handle.slot.brg
    with_executor(UnprivilegedUserNamespacesExecutor) do exe
        exe.persistence_dir, exe.userxattr = agent_persist_info(brg, handle.agent_name)
        cmd = something(cmd, buildkite_agent_start_command(brg;
            agent_binary="/usr/bin/buildkite-agent",
            hooks_path="/hooks",
            cache_path="/cache",
            agent_name=handle.agent_name,
            job=handle.job,
        ))
        sandbox_cmd = Sandbox.build_executor_command(exe, handle.config, cmd)
        return wrap_command_in_cgroup_join_file(
            joinpath(handle.cgroup_path, "cgroup.procs"),
            sandbox_cmd,
        )
    end
end

function run_job(handle::LinuxSandboxHandle, deadline::Union{Nothing,Float64}=nothing)
    cmd = sandbox_command(handle)
    open(handle.log_path, "a") do log
        println(log, job_start_banner(handle.job, handle.plan))
        commit_launch!(handle.launch)
        proc = run(pipeline(cmd; stdout=log, stderr=log); wait=false)
        return wait_process_exit(proc, deadline,
            "running Linux sandbox job $(handle.job.id)")
    end
end

# PIDs of the `buildkite-agent start` processes in a job cgroup (and below it,
# should the sandbox create children), as seen from the host.
function cgroup_agent_pids(cgroup_path::AbstractString; proc_root::AbstractString="/proc")
    return filter(cgroup_pids(cgroup_path)) do pid
        argv = try
            split(read(joinpath(proc_root, string(pid), "cmdline"), String), '\0')
        catch
            return false
        end
        return length(argv) >= 2 && basename(argv[1]) == "buildkite-agent" && argv[2] == "start"
    end
end

function cgroup_pids(cgroup_path::AbstractString)
    pids = Int[]
    isdir(cgroup_path) || return pids
    for (dir, _, files) in walkdir(cgroup_path)
        "cgroup.procs" in files || continue
        for line in eachline(joinpath(dir, "cgroup.procs"))
            pid = tryparse(Int, strip(line))
            pid === nothing || push!(pids, pid)
        end
    end
    return pids
end

function parent_pid(pid::Integer; proc_root::AbstractString="/proc")
    stat = try
        read(joinpath(proc_root, string(pid), "stat"), String)
    catch
        return nothing
    end
    # the fields after the parenthesised command name: state, ppid, ...
    fields = split(stat[something(findlast(')', stat), 0)+1:end])
    return length(fields) >= 2 ? tryparse(Int, fields[2]) : nothing
end

"""
    cgroup_job_pids(cgroup_path)

The processes of the job in `cgroup_path`: everything in the cgroup except its
Buildkite agents and the processes above them (the sandbox that runs the agent).
"""
function cgroup_job_pids(cgroup_path::AbstractString; proc_root::AbstractString="/proc")
    pids = cgroup_pids(cgroup_path)
    keep = Set{Int}()
    for pid in cgroup_agent_pids(cgroup_path; proc_root)
        while pid !== nothing && pid in pids && !(pid in keep)
            push!(keep, pid)
            pid = parent_pid(pid; proc_root)
        end
    end
    return filter(!in(keep), pids)
end

function stop_job(handle::LinuxSandboxHandle; force::Bool=false, kill_delay::Real=STOP_KILL_DELAY,
                  agent_pids::Function=cgroup_agent_pids, job_pids::Function=cgroup_job_pids,
                  kill_timeout::Real=LINUX_CGROUP_KILL_TIMEOUT)
    committed = close_launch_gate!(handle.launch)
    if force
        isempty(cgroup_pids(handle.cgroup_path)) && return :ended
        # Not confirmed empty is not the same as nothing killed.
        return kill_cgroup(handle.cgroup_path; timeout=kill_timeout) ? :stopped : :unconfirmed
    end
    committed || return :not_acquired
    agents = agent_pids(handle.cgroup_path)
    isempty(agents) && return :no_agent
    try
        for pid in agents
            ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGQUIT)
        end
        # The agent would now wait up to its cancel grace period for the job to exit (on a
        # cancel signal, Julia's test runner dumps the core of every worker first). A stopped
        # job is retried by the operator, so kill it instead: the agent then reports it and exits.
        sleep(kill_delay)
        for _ in 1:5
            pids = job_pids(handle.cgroup_path)
            isempty(pids) && break
            foreach(pid -> ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGKILL), pids)
            sleep(0.2)
        end
    catch err
        # The agent was signalled, so the job may be stopped all the same.
        @warn("Unable to finish stopping the Buildkite job", cgroup=handle.cgroup_path,
            exception=(err, catch_backtrace()))
        return :unconfirmed
    end
    return :stopped
end

# Returns `false` while processes of the job may survive; the job keeps its
# CPUs and paths until a later call confirms they are gone.
function reap(handle::LinuxSandboxHandle)
    log_job_oom_events(handle.cgroup_path; log_path=handle.log_path)
    remove_job_cgroup(handle.cgroup_path) || return false
    unpin_job_cpus!(handle.backend, handle.cgroup_path)
    cleanup_host_paths(handle)
    return true
end
