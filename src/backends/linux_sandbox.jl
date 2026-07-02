# This only exists so that we can avoid compile-time-checking of lazy artifact loading
artifact_lookup(name) = @artifact_str(name)

mutable struct LinuxSandboxBackend <: PlatformBackend
    logdir::String
    root::String
    slot_cpus::Dict{String,String}
    cleanup_paths::Vector{String}

    LinuxSandboxBackend(logdir::String) = new(logdir, "", Dict{String,String}(), String[])
end

function check_linux_sandbox_runner_configs(brgs::Vector{BuildkiteRunnerGroup})
    for brg in brgs
        tagtrue(brg, name) = get(brg.tags, name, "false") == "true"

        # Check that we self-identify as `sandbox.jl`
        if !tagtrue(brg, "sandbox_capable")
            error("Refusing to start up `sandbox.jl` runner '$(brg.name)' that does not self-identify through tags!")
        end

        if rootless_docker_enabled(brg)
            # Check that we self-identify as docker-able, if that is true of us.
            if !tagtrue(brg, "docker_capable")
                error("Refusing to start up `sandbox.jl` runner '$(brg.name)' with docker enabled that does not self-identify through tags!")
            end

            # Check that the subuid stuff for rootless docker is setup properly
            check_rootless_subuid()
        end
    end

    # Check that we aren't trying to pin too many cores
    pinned_cores = sum(brg.num_agents * brg.num_cpus for brg in brgs)
    if pinned_cores > Sys.CPU_THREADS
        error("Refusing to attempt to pin agents to more cores than exist!")
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

function cpu_topology_permutation()
    # We want to schedule a worker on CPUs that share thread siblings.
    # Not only is this a good idea for security (haha, CI is RCE as a service)
    # it improves performance, as cache coherency should improve.  Most
    # importantly, it reduces the chance that job A and B interfere with each other.

    # If we don't have this information available, just return the identity permutation
    cpu_dir = "/sys/devices/system/cpu"
    if !isdir(cpu_dir)
        return collect(1:Sys.CPU_THREADS)
    end

    cores = filter(d -> match(r"^cpu\d+", d) !== nothing, readdir(cpu_dir))
    cores = sort([parse(Int, c[4:end]) for c in cores])

    cpus = Int[]
    for core_idx in cores
        if core_idx ∈ cpus
            continue
        end

        siblings = split(String(read(joinpath(cpu_dir, "cpu$(core_idx)", "topology", "thread_siblings_list"))), ",")
        append!(cpus, parse.(Int, siblings))
    end
    return cpus
end


# Turns `[1,2,3,6,7,10,15]` into "1-3,6-7,10,15"
function condense_cpu_selection(cpus::Vector{Int})
    cpus = sort(cpus)
    ret = String[]
    idx = 1
    while idx <= length(cpus)
        start_idx = idx
        while idx < length(cpus) && cpus[idx+1] - cpus[idx] == 1
            idx += 1
        end
        if idx > start_idx
            push!(ret, "$(cpus[start_idx])-$(cpus[idx])")
            idx += 1
        else
            push!(ret, "$(cpus[start_idx])")
            idx += 1
        end
    end
    return join(ret, ",")
end

function slot_cpu_assignments(slots)
    pinned_cores = sum(slot.brg.num_cpus for slot in slots)
    if pinned_cores > Sys.CPU_THREADS
        error("Refusing to attempt to pin agents to more cores than exist!")
    end

    assignments = Dict{String,String}()
    cpu_permutation = cpu_topology_permutation()
    cpu_offset = 0
    for slot in slots
        if slot.brg.num_cpus > 0
            assignments[slot.name] = condense_cpu_selection(
                cpu_permutation[cpu_offset+1:cpu_offset+slot.brg.num_cpus],
            )
            cpu_offset += slot.brg.num_cpus
        end
    end
    return assignments
end

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

function require_cpuset_controller(root::String)
    if "cpuset" ∉ cgroup_controllers(root)
        error("Linux scheduler unit needs Delegate=cpuset; host needs cgroup-v2 cpuset (kernel >= 5.0, systemd >= 244)")
    end
    return nothing
end

function setup_job_cgroups!(root::String)
    require_cpuset_controller(root)
    supervisor = joinpath(root, "supervisor")
    mkpath(supervisor)
    write(joinpath(supervisor, "cgroup.procs"), string(getpid(), "\n"))
    write(joinpath(root, "cgroup.subtree_control"), "+cpuset\n")
    return nothing
end

function create_job_cgroup(root::String, name::String; cpus::Union{String,Nothing}=nothing)
    job_root = joinpath(root, name)
    mkpath(job_root)
    if cpus !== nothing
        mems = strip(read(joinpath(root, "cpuset.mems.effective"), String))
        write(joinpath(job_root, "cpuset.mems"), string(mems, "\n"))
        write(joinpath(job_root, "cpuset.cpus"), string(cpus, "\n"))
    end
    return job_root
end

const LINUX_CGROUP_REMOVE_TIMEOUT = 5.0

function kill_cgroup(path::String)
    kill_path = joinpath(path, "cgroup.kill")
    isfile(kill_path) || return false
    write(kill_path, "1\n")
    return true
end

function remove_cgroup_tree(path::String)
    isdir(path) || return nothing
    for child in readdir(path; join=true)
        isdir(child) && remove_cgroup_tree(child)
    end
    rm(path)
    return nothing
end

function remove_job_cgroup(path::String; timeout::Real=LINUX_CGROUP_REMOVE_TIMEOUT)
    isdir(path) || return nothing
    try
        kill_cgroup(path)
    catch err
        @warn("Unable to kill job cgroup", path, exception=(err, catch_backtrace()))
    end

    deadline = time() + Float64(timeout)
    last_error = nothing
    while isdir(path)
        try
            remove_cgroup_tree(path)
            return nothing
        catch err
            last_error = (err, catch_backtrace())
            time() >= deadline && break
            sleep(0.1)
        end
    end
    isdir(path) && @warn("Unable to remove job cgroup", path, exception=last_error)
    return nothing
end

function cleanup_job_cgroups(root::String)
    isempty(root) && return nothing
    isdir(root) || return nothing
    for name in sort(readdir(root))
        startswith(name, "job-") || continue
        path = joinpath(root, name)
        isdir(path) || continue
        @warn("Removing stale Linux job cgroup", path)
        remove_job_cgroup(path)
    end
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

function uidmap_size(map_path::String, username::String = ENV["USER"])
    for line in readlines(map_path)
        try
            name, start, size = split(line, ":")
            if name == username
                return parse(Int, size)
            end
        catch
        end
    end
    return 0
end

function check_rootless_subuid()
    # First, ensure `newuidmap` is installed:
    if Sys.which("newuidmap") === nothing
        error("Rootless docker support requires installing `newuidmap`")
    end

    # Next, we ensure we have a subuid mapping
    for map_path in ("/etc/subuid", "/etc/subgid")
        if uidmap_size(map_path) < 65536
            error("Rootless docker support requires a subspace of at least 64K in $(map_path) for the current user")
        end
    end
end

function Sandbox.SandboxConfig(brg::BuildkiteRunnerGroup;
                       rootfs_dir::String = @artifact_str("buildkite-agent-rootfs", brg.platform),
                       agent_token_path::String = joinpath(secrets_dir(brg), "buildkite-agent-token"),
                       agent_name::String = brg.name,
                       cache_path::String = joinpath(cachedir(brg), agent_name),
                       shared_cache_path::Union{String,Nothing} = has_shared_cache(brg) ? sharedcachedir(brg) : nothing,
                       temp_path::String = joinpath(tempdir(brg), "agent-tempdirs", agent_name),
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
        "SANDBOX_PERSISTENCE_DIR" => "/cache/sandbox_persistence",
        "FORCE_SANDBOX_MODE" => "unprivileged",

        # Give the job a sane, `/usr/local/bin`-first PATH. Without this the
        # agent starts with no PATH and hands jobs a minimal `:/usr/bin`; the
        # JuliaCI sandbox plugin then *appends* `/usr/local/bin` which conflicts
        # with our rootfs images putting a toolchain in `/usr/local`.
        "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    )

    if rootless_docker_enabled(brg)
        # We also want to provide a host-stable mountpoint, so if our `temp_path`
        # is a subdir of `/tmp`, let's mount in a stable mountpoint and use that
        # as the default TMPDIR for everything.
        docker_home = temp_path
        if temp_path == "/tmp" || startswith(temp_path, "/tmp/")
            # Yes, by doing this, we mount the same host directory `$temp_path`
            # at TWO locations within the sandbox: at `/tmp` and `/tmp/$(agent_specific)/`.
            # This means that `/tmp/foo` and `/tmp/$(agent_specific)/foo` will be the same file.
            rw_maps[temp_path] = temp_path
        end
        env_maps["TMPDIR"] = temp_path

        # We mount in the docker client (served from our artifact!)
        ro_maps["/usr/bin/docker"] = artifact_lookup("docker/docker/docker")

        # We also mount in a socket to talk with our docker rootless daemon
        # This doesn't actually start docker rootless; that is pending
        docker_socket_path = joinpath(docker_home, "docker.sock")
        rw_maps["/var/run/docker.sock"] = docker_socket_path
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

    if rootless_docker_enabled(brg)
        push!(paths, joinpath(config.mounts["/tmp"].host_path, "home"))
    end

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
        persistence_dir(brg, agent_name),

        # We clean out our `/tmp` directory every time
        config.mounts["/tmp"].host_path,
    ]
end

function persistence_dir(brg, agent_name)
    persistence_hints = String[]
    if persistence_dir(brg) !== nothing
        push!(persistence_hints, persistence_dir(brg))
    end
    push!(persistence_hints, cachedir(brg))
    rootfs_dir = @artifact_str("buildkite-agent-rootfs", brg.platform)

    # Once we've found a good persistence root, go into an agent-specific location.
    persist_root = Sandbox.find_persist_dir_root(rootfs_dir, persistence_hints)[1]
    if persist_root === nothing
        error("""
            No usable persistence directory: none of the candidate paths are on a
            filesystem that can host an overlayfs upperdir.
            Tried (in order): $(join(persistence_hints, ", ")).""")
    end
    return joinpath(persist_root, string("persist-", agent_name))
end

function buildkite_agent_start_command(brg::BuildkiteRunnerGroup;
                                       agent_name::String,
                                       acquire_job_id::String)
    return Cmd(String[
        "/usr/bin/buildkite-agent",
        "start",
        "--acquire-job=$(acquire_job_id)",
        "--hooks-path=/hooks",
        "--build-path=/cache/build",
        "--plugins-path=/cache/plugins",
        "--experiment=resolve-commit-after-checkout",
        "--git-mirrors-path=/cache/repos",
        "--git-fetch-flags=-v --prune --tags",
        "--cancel-grace-period=300",
        "--tags=$(buildkite_agent_tags(brg))",
        "--name=$(agent_name)",
    ])
end

function agent_start_command(::LinuxSandboxBackend, brg::BuildkiteRunnerGroup; kwargs...)
    return buildkite_agent_start_command(brg; kwargs...)
end

function cleanup(backend::LinuxSandboxBackend)
    cleanup_job_cgroups(backend.root)
    cleanup_linux_host_path.(backend.cleanup_paths)
    return nothing
end

function setup_backend!(backend::LinuxSandboxBackend, slots)
    backend.root = scheduler_cgroup_root()
    setup_job_cgroups!(backend.root)
    backend.slot_cpus = slot_cpu_assignments(slots)
    backend.cleanup_paths = linux_startup_cleanup_paths(slots)
    return nothing
end

mutable struct LinuxSandboxHandle
    backend::LinuxSandboxBackend
    slot::Slot
    job::Job
    plan::CachePlan
    config::SandboxConfig
    agent_name::String
    log_path::String
    cgroup_path::String
    docker_proc::Union{Base.Process,Nothing}
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
            push!(paths, persistence_dir(slot.brg, slot.name))
        catch err
            @warn("Unable to resolve Linux persistence dir for cleanup",
                slot=slot.name, exception=(err, catch_backtrace()))
        end
    end
    return sort(unique(paths))
end

function prepare(backend::LinuxSandboxBackend, slot::Slot, job::Job, plan::CachePlan)
    mkpath(plan.cache_pool)
    plan.ccache_pool === nothing || mkpath(plan.ccache_pool)
    isempty(backend.root) && error("LinuxSandboxBackend has not been set up")

    agent_name = slot.name
    temp_path = linux_agent_temp_path(slot)
    config = SandboxConfig(slot.brg;
        agent_name,
        cache_path=plan.cache_pool,
        shared_cache_path=plan.ccache_pool,
        temp_path,
    )
    log_path = joinpath(backend.logdir, agent_name, "$(safe_path_component(job.id, "unknown-job")).log")
    cgroup_path = create_job_cgroup(backend.root, job_cgroup_name(slot, job);
        cpus=get(backend.slot_cpus, slot.name, nothing))
    handle = LinuxSandboxHandle(backend, slot, job, plan, config, agent_name, log_path, cgroup_path, nothing)

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

function docker_env(config::SandboxConfig)
    docker_home = config.env["TMPDIR"]
    docker_dir = artifact_lookup("docker/docker")
    docker_extras_dir = artifact_lookup("docker-rootless-extras/docker-rootless-extras")
    return docker_home, docker_extras_dir, Dict(
        "HOME" => joinpath(docker_home, "home"),
        "XDG_DATA_HOME" => joinpath(docker_home, "home"),
        "XDG_RUNTIME_DIR" => docker_home,
        "PATH" => "$(docker_dir):$(docker_extras_dir):$(ENV["PATH"])",
    )
end

function start_rootless_docker(handle::LinuxSandboxHandle)
    rootless_docker_enabled(handle.slot.brg) || return nothing

    docker_home, docker_extras_dir, env = docker_env(handle.config)
    run(ignorestatus(setenv(`$(docker_extras_dir)/rootlesskit rm -rf $(docker_home)`, env)))
    mkpath(docker_home)

    cmd = wrap_command_in_cgroup_join_file(
        joinpath(handle.cgroup_path, "cgroup.procs"),
        setenv(`$(docker_extras_dir)/dockerd-rootless.sh`, env),
    )
    proc = run(pipeline(cmd;
        stdout=joinpath(docker_home, "dockerd.stdout"),
        stderr=joinpath(docker_home, "dockerd.stderr"),
    ); wait=false)

    docker_socket_path = joinpath(docker_home, "docker.sock")
    start_time = time()
    while !issocket(docker_socket_path)
        sleep(0.1)
        if !process_running(proc)
            wait(proc)
            error("Rootless docker exited before creating $(docker_socket_path)")
        end
        if time() - start_time > 30
            kill(proc)
            wait(proc)
            error("Timed out waiting for rootless docker at $(docker_socket_path)")
        end
    end

    handle.docker_proc = proc
    return proc
end

function stop_rootless_docker(handle::LinuxSandboxHandle)
    proc = handle.docker_proc
    handle.docker_proc = nothing
    proc === nothing && return nothing

    try
        process_running(proc) && kill(proc)
        wait(proc)
    catch err
        @warn("Unable to stop rootless docker", exception=(err, catch_backtrace()))
    end

    try
        docker_home, docker_extras_dir, env = docker_env(handle.config)
        run(ignorestatus(setenv(`$(docker_extras_dir)/rootlesskit rm -rf $(docker_home)`, env)))
    catch err
        @warn("Unable to clean rootless docker state", exception=(err, catch_backtrace()))
    end
    return nothing
end

function sandbox_command(handle::LinuxSandboxHandle)
    brg = handle.slot.brg
    with_executor(UnprivilegedUserNamespacesExecutor) do exe
        exe.persistence_dir = persistence_dir(brg, handle.agent_name)
        cmd = agent_start_command(handle.backend, brg;
            agent_name=handle.agent_name,
            acquire_job_id=handle.job.id,
        )
        sandbox_cmd = Sandbox.build_executor_command(exe, handle.config, cmd)
        return wrap_command_in_cgroup_join_file(
            joinpath(handle.cgroup_path, "cgroup.procs"),
            sandbox_cmd,
        )
    end
end

function run_job(handle::LinuxSandboxHandle)
    start_rootless_docker(handle)
    try
        cmd = sandbox_command(handle)
        open(handle.log_path, "a") do log
            println(log, "Starting Buildkite job $(handle.job.id) in $(handle.plan.pipeline)/$(handle.plan.trust)")
            proc = run(pipeline(cmd; stdout=log, stderr=log); wait=false)
            wait(proc)
            return proc.exitcode
        end
    finally
        stop_rootless_docker(handle)
    end
end

function reap(handle::LinuxSandboxHandle)
    cleanup_host_paths(handle)
    remove_job_cgroup(handle.cgroup_path)
    return nothing
end
