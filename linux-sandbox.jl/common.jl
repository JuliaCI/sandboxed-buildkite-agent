using TOML, Base.BinaryPlatforms, Sandbox, Scratch, LazyArtifacts, Downloads

include("../common/common.jl")

# This only exists so that we can avoid compile-time-checking of lazy artifact loading
artifact_lookup(name) = @artifact_str(name)

function check_configs(brgs::Vector{BuildkiteRunnerGroup})
    for brg in brgs
        tagtrue(brg, name) = get(brg.tags, name, "false") == "true"

        # Check that we self-identify as `sandbox.jl`
        if !tagtrue(brg, "sandbox_capable")
            error("Refusing to start up `sandbox.jl` runner '$(brg.name)' that does not self-identify through tags!")
        end

        if brg.start_rootless_docker
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

    # If we are pinning cores, we need to create cgroups for each.  We want this to
    # happen automatically on restart as well, so we create a script that generates
    # the cgroups and add the script as a step in our systemd setup as well.
    if pinned_cores > 0
        names_to_cpus = Dict{Vector{String},String}()
        cpu_permutation = cpu_topology_permutation()
        cpu_offset = 0
        agent_idx = 0
        for brg in brgs
            for _ in 1:brg.num_agents
                unit_name = systemd_unit_name(brg, agent_idx)
                if brg.num_cpus > 0
                    names = [string(brg.name, "-", get_short_hostname(), ".", agent_idx), unit_name]
                    names_to_cpus[names] = condense_cpu_selection(cpu_permutation[cpu_offset+1:cpu_offset+brg.num_cpus])
                    cpu_offset += brg.num_cpus
                end
                agent_idx += 1
            end
        end

        # Create a setuid wrapper so that this path gets executed with root permissions
        mk_cgroup_path = joinpath(get_scratch!("agent-cache"), "mk_cgroup")
        mk_cgroup_src = joinpath(@__DIR__, "mk_cgroup.c")
        if !isfile(mk_cgroup_path) || stat(mk_cgroup_src).mtime > stat(mk_cgroup_path).mtime
            @info("Generating mk_cgroup helper, may ask for sudo password...")
            run(`cc -o $(mk_cgroup_path) -Wall -O2 -static $(mk_cgroup_src)`)
            run(`sudo chown root:$(Sandbox.getgid()) $(mk_cgroup_path)`)
            run(`sudo chmod 6770 $(mk_cgroup_path)`)
        end

        cg_path = joinpath(get_scratch!("agent-cache"), "cgroup_generator.sh")
        open(cg_path, write=true) do io
            println(io, """
            #!/bin/bash

            set -euo pipefail
            case "\${1}" in
            """)

            for (names, cpus) in names_to_cpus
                cpuset_path = "/sys/fs/cgroup/cpuset/$(first(names))"
                println(io, """
                    $(join(names, "|")))
                        $(mk_cgroup_path) $(first(names)) $(cpus)
                        ;;
                """)
            end

            println(io, """
                *)
                    echo "ERROR: Unknown agent name '\${1}'" >&2
                    exit 1
                    ;;
            esac
            """)
        end
        chmod(cg_path, 0o755)
    end

    # Check that we have coredumps configured to write out with the appropriate pattern
    setup_coredumps()

    # Check that we can run `rr` on AMD chips happily
    check_zen_workaround()

    # Check that we have our sysctl stuff setup properly for `rr`
    check_sysctl_params()
end

function find_python3()
    for name in ("python3", "python")
        if Sys.which(name) !== nothing
            version = readchomp(`$(name) --version`)
            m = match(r"Python (?<version_number>\d+\.\d+\.\d+)", version)
            if m !== nothing
                if parse(VersionNumber, m[:version_number]) >= v"3"
                    return Sys.which(name)
                end
            end
        end
    end
    return nothing
end

function check_zen_workaround()
    # Nothing to do if we're not on AMD
    if isempty(filter(l -> match(r"vendor_id\s+:\s+AuthenticAMD", l) !== nothing, split(String(read("/proc/cpuinfo")), "\n")))
        return
    end

    # If we don't already have an `rr-workaround` service, generate it:
    rr_systemd_script_path = "/etc/systemd/system/zen_workaround.service"
    if !isfile(rr_systemd_script_path)
        @info("Writing out and starting up rr workaround service, may ask for sudo password...")
        workaround_script = joinpath(@get_scratch!("agent-cache"), "zen_workaround.py")
        if !isfile(workaround_script)
            Downloads.download("https://github.com/rr-debugger/rr/raw/master/scripts/zen_workaround.py", workaround_script)
        end

        # We need python3 to run this
        python3 = find_python3()
        if python3 === nothing
            error("Must install python 3 to run zen_workaround.py!")
        end

        systemd_config = SystemdConfig(;
            description="rr workaround script",
            working_dir=dirname(workaround_script),
            type=:oneshot,
            remain_after_exit=true,
            exec_start=SystemdTarget("$(python3) $(workaround_script)", [:Sudo]),
        )
        open(`/bin/bash -c "sudo tee $(rr_systemd_script_path) > /dev/null"`, write=true) do io
            write(io, systemd_config)
        end
        run(`sudo systemctl daemon-reload`)
    end

    if !success(`systemctl status zen_workaround`)
        run(`sudo systemctl enable zen_workaround`)
        run(`sudo systemctl start zen_workaround`)
    end
end

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
                       agent_token_path::String = joinpath(dirname(@__DIR__), "secrets", "buildkite-agent-token"),
                       agent_name::String = brg.name,
                       cache_path::String = joinpath(cachedir(brg), agent_name),
                       temp_path::String = joinpath(tempdir(brg), "agent-tempdirs", agent_name),
                       verbose::Bool = brg.verbose,
                       )
    repo_root = dirname(@__DIR__)

    # Set read-only mountings for rootfs, hooks and secrets
    ro_maps = Dict(
        # Mount in rootfs
        "/" => rootfs_dir,

        # Mount in hooks and secrets (secrets will be un-mounted)
        "/hooks" => joinpath(repo_root, "hooks"),
        "/secrets" => joinpath(repo_root, "secrets"),

        # Mount in a machine-id file that will be consistent across runs, but unique to each agent
        "/etc/machine-id" => joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id"),
    )
    # Set read-write mountings for our `/cache` directory
    rw_maps = Dict(
        "/cache" => cache_path,
        "/tmp" => temp_path,
    )

    if brg.shared_cache_path !== nothing
        rw_maps["/sharedcache"] = brg.shared_cache_path
    end

    # Environment mappings
    env_maps = Dict(
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => "/cache/julia-buildkite-plugin",
        "BUILDKITE_AGENT_TOKEN" => String(chomp(String(read(agent_token_path)))),
        "BUILDKITE_PLUGIN_JULIA_ARCH" => brg.tags["arch"],
        "HOME" => "/root",

        # For anyone who wants to do nested sandboxing, tell them to store
        # persistent data here instead of in `/tmp`, since that's an overlayfs
        "SANDBOX_PERSISTENCE_DIR" => "/cache/sandbox_persistence",
        "FORCE_SANDBOX_MODE" => "unprivileged",
    )

    if brg.start_rootless_docker
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

    entrypoint = nothing
    if brg.num_cpus > 0
        # Mount in the cgroup wrapper script, and the cgroup directory itself
        ro_maps["/usr/lib/entrypoint"] = joinpath(@__DIR__, "cgroup_wrapper.sh")
        rw_maps["/usr/lib/cpuset/self"] = "/sys/fs/cgroup/cpuset/$(agent_name)"
        entrypoint = "/usr/lib/entrypoint"
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
        # We provide an entrypoint if we need to do some cpuset wrapper setup
        entrypoint,
    )
end

function host_paths_to_create(brg, config)
    paths = String[
        joinpath(config.mounts["/cache"].host_path, "build"),
        config.mounts["/tmp"].host_path,
    ]

    if brg.start_rootless_docker
        push!(paths, joinpath(config.mounts["/tmp"].host_path, "home"))
    end

    if brg.shared_cache_path !== nothing
        push!(paths, brg.shared_cache_path)
    end

    return paths
end

function host_paths_to_cleanup(brg, config, agent_name)
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
    return joinpath(cachedir(brg), string("persist-", agent_name))
end

function generate_systemd_script(io::IO, brg::BuildkiteRunnerGroup; agent_name::String=string(brg.name, "-%i"), kwargs...)
    config = SandboxConfig(brg; agent_name, kwargs...)
    temp_path = config.mounts["/tmp"].host_path
    machine_id_path = joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id")

    with_executor(UnprivilegedUserNamespacesExecutor) do exe
        # We need to assign a specific persistence dir, otherwise the different agents clobber eachother
        # by all writing to the same path created by `mktempdir()` automatically for us.
        exe.persistence_dir = persistence_dir(brg, agent_name)

        # Build full list of tags, with duplicate mappings for `queue`
        tags_with_queues = ["$tag=$value" for (tag, value) in brg.tags]
        append!(tags_with_queues, ["queue=$(queue)" for queue in brg.queues])

        # We add a few arguments to our buildkite agent, namely:
        #  - experiment: resolve-commit-after-checkout
        #    This resolves `BUILDKITE_COMMIT` to a commit hash, which allows us to trigger
        #    builds against e.g. `HEAD` or `release-1.8` and still get a hash here.
        #  - git-fetch-flags: we need to pull down git tags as well as content, so that
        #    our git versioning scripts can correctly determine when we're sitting on a tag.
        c = Sandbox.build_executor_command(
            exe,
            config,
            ```/usr/bin/buildkite-agent start
                                --disconnect-after-job
                                --hooks-path=/hooks
                                --build-path=/cache/build
                                --experiment=resolve-commit-after-checkout
                                --git-mirrors-path=/cache/repos
                                --git-fetch-flags=\"-v --prune --tags\"
                                --cancel-grace-period=300
                                --tags=$(join(tags_with_queues, ","))
                                --name=$(agent_name)
            ```
        )

        create_paths = host_paths_to_create(brg, config)
        cleanup_paths = host_paths_to_cleanup(brg, config, agent_name)

        # Helper hook to create mountpoints on the host
        create_hook = SystemdBashTarget("mkdir -p $(join(create_paths, " "))")

        # Helper hook to cleanup paths on the host
        cleanup_hook = SystemdBashTarget(
            "echo Cleaning up $(join(cleanup_paths, " ")) >&2 ; chmod u+w -R $(join(cleanup_paths, " ")) 2>/dev/null ; rm -rf $(join(cleanup_paths, " ")) 2>/dev/null",
            [:IgnoreExitCode, :Sudo],
        )

        start_pre_hooks = SystemdTarget[
            # Clear out any ephemeral storage that existed from last time (we'll do this again after running)
            cleanup_hook,
            # Create mountpoints
            create_hook,
            # Create a machine-id file to get mounted in
            SystemdBashTarget("echo $(agent_name) | shasum | cut -c-32 > $(machine_id_path)"),
            # Set max open files to 10240
            SystemdBashTarget("ulimit -n 10240"),
        ]

        stop_post_hooks = SystemdTarget[
            # Clean things up afterward too
            cleanup_hook,
        ]

        if brg.start_rootless_docker
            # Docker needs `HOME` and `XDG_RUNTIME_DIR` set to an agent-specific location, so as to not interfere
            # with other `dockerd` instances.  We clear these locations out every time.
            docker_home = config.env["TMPDIR"]
            docker_dir = artifact_lookup("docker/docker")
            docker_extras_dir = artifact_lookup("docker-rootless-extras/docker-rootless-extras")
            docker_env = join([
                "HOME=$(docker_home)/home",
                "XDG_DATA_HOME=$(docker_home)/home",
                "XDG_RUNTIME_DIR=$(docker_home)",
                "PATH=$(docker_dir):$(docker_extras_dir):$(ENV["PATH"])",
            ], " ")

            # Add some startup hooks
            append!(start_pre_hooks, [
                # Start up a wrapped rootless `dockerd` instance.
                SystemdBashTarget("mkdir -p $(docker_home); $(docker_env) $(docker_extras_dir)/dockerd-rootless.sh >$(docker_home)/dockerd-rootless.log 2>&1 &"),
                # Wait until it's ready
                SystemdBashTarget("while [ ! -S $(docker_home)/docker.sock ]; do sleep 1; done"),
            ])

            # When we stop, kill the dockerd instance, and do so _before_ our cleanup
            insert!(stop_post_hooks, 1, SystemdBashTarget("echo Cleaning up docker >&2 ; $(docker_extras_dir)/rootlesskit rm -rf $(docker_home)", [:IgnoreExitCode]))
            insert!(start_pre_hooks, 1, SystemdBashTarget("echo Cleaning up docker >&2 ; $(docker_extras_dir)/rootlesskit rm -rf $(docker_home)", [:IgnoreExitCode]))
            insert!(stop_post_hooks, 1, SystemdBashTarget("echo Killing docker >&2 ; kill -TERM \$(cat $(docker_home)/docker.pid)"))
        end

        # If we're locking to CPUs, we need to ensure that the cgroups are setup properly
        if brg.num_cpus > 0
            cg_path = joinpath(get_scratch!("agent-cache"), "cgroup_generator.sh")
            push!(start_pre_hooks, SystemdTarget("$(cg_path) $(agent_name)"))
        end

        systemd_config = SystemdConfig(;
            description="Sandboxed Buildkite agent $(agent_name)",
            working_dir="~",
            env=Dict(k => v for (k,v) in split.(c.env, Ref("="))),
            restart=SystemdRestartConfig(),
            start_timeout="1min",
            stop_timeout="120min",
            kill_mode="mixed",
            start_pre_hooks,
            exec_start=SystemdTarget(join(c.exec, " ")),
            stop_post_hooks,
        )
        write(io, systemd_config)
    end
end

const systemd_unit_name_stem = "buildkite-sandbox-"

function debug_shell(brg::BuildkiteRunnerGroup;
                     agent_name::String = brg.name,
                     cache_path::String = joinpath(cachedir(brg), agent_name),
                     persist_path::String = persistence_dir(brg, agent_name),
                     temp_path::String = joinpath(tempdir(brg), "agent-tempdirs", agent_name))
    config = SandboxConfig(brg; agent_name, cache_path, temp_path, verbose=true)

    # Initial cleanup and creation
    function force_delete(path)
        try
            Base.Filesystem.prepare_for_deletion(path)
            rm(path; force=true, recursive=true)
        catch; end
    end
    force_delete.(host_paths_to_cleanup(brg, config, agent_name))
    mkpath.(host_paths_to_create(brg, config))
    machine_id_path = joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id")
    run(`/bin/bash -c "echo $(agent_name) | shasum | cut -c-32 > $(machine_id_path)"`)

    local docker_proc = nothing
    if brg.start_rootless_docker
        docker_home = config.env["TMPDIR"]
        docker_dir = artifact_lookup("docker/docker")
        docker_extras_dir = artifact_lookup("docker-rootless-extras/docker-rootless-extras")
        docker_proc = run(pipeline(setenv(
                `$(docker_extras_dir)/dockerd-rootless.sh`,
                Dict(
                    "HOME" => joinpath(docker_home, "home"),
                    "XDG_DATA_HOME" => joinpath(docker_home, "home"),
                    "XDG_RUNTIME_DIR" => docker_home,
                    "PATH" => "$(docker_dir):$(docker_extras_dir):$(ENV["PATH"])",
                ),
            );
            stdout=joinpath(docker_home, "dockerd.stdout"),
            stderr=joinpath(docker_home, "dockerd.stderr"),
        ); wait=false)

        docker_socket_path = joinpath(docker_home, "docker.sock")
        t_start = time()
        while !issocket(docker_socket_path)
            sleep(0.1)
            if time() - t_start > 10.0
                @error("Unable to start rootless docker!", docker_proc)
                error("Unable to start rootless docker!")
            end
        end
    end
    try
        exe_kwargs = Dict()
        if brg.num_cpus > 0
            # Setup cpuset, including making it modifiable by the current user
            @info("Attempting to create cpuset...")
            cg_path = joinpath(get_scratch!("agent-cache"), "cgroup_generator.sh")
            run(`$(cg_path) $(agent_name)`)
        end

        with_executor(UnprivilegedUserNamespacesExecutor; exe_kwargs...) do exe
            exe.persistence_dir = persistence_dir(brg, agent_name)
            run(exe, config, `/bin/bash -l`)
        end
    finally
        if docker_proc !== nothing
            kill(docker_proc)
            wait(docker_proc)
        end
        force_delete.(host_paths_to_cleanup(brg, config, agent_name))
    end
end
