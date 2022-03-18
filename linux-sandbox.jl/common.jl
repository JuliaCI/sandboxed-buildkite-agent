using TOML, Base.BinaryPlatforms, Sandbox, Scratch, LazyArtifacts

include("../common/common.jl")

function Sandbox.SandboxConfig(brg::BuildkiteRunnerGroup;
                       rootfs_dir::String = artifact"buildkite-agent-rootfs",
                       agent_token_path::String = joinpath(dirname(@__DIR__), "secrets", "buildkite-agent-token"),
                       agent_name::String = brg.name,
                       cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                       temp_path::String = joinpath(tempdir(), "agent-tempdirs", agent_name),
                       )
    repo_root = dirname(@__DIR__)
    tagtrue(brg, name) = get(brg.tags, name, "false") == "true"

    # Check that we self-identify as `sandbox.jl`
    if !tagtrue(brg, "sandbox.jl") || !tagtrue(brg, "sandbox_capable")
        error("Refusing to start up `sandbox.jl` runner '$(brg.name)' that does not self-identify through tags!")
    end

    if brg.start_rootless_docker && (!tagtrue(brg, "docker_present") || !tagtrue(brg, "docker_capable"))
        error("Refusing to start up `sandbox.jl` runner '$(brg.name)' with docker enabled that does not self-identify through tags!")
    end

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

    # Environment mappings
    env_maps = Dict(
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => "/cache/julia-buildkite-plugin",
        "BUILDKITE_AGENT_TOKEN" => String(chomp(String(read(agent_token_path)))),
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
            env_maps["TMPDIR"] = temp_path
        end

        # We mount in the docker client (served from our artifact!)
        ro_maps["/usr/bin/docker"] = artifact"docker/docker/docker"

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
        verbose=brg.verbose,
    )
end

function host_paths_to_create(brg, config)
    paths = String[
        joinpath(config.read_write_maps["/cache"], "build"),
        config.read_write_maps["/tmp"],
    ]

    if brg.start_rootless_docker
        push!(paths, joinpath(config.read_write_maps["/tmp"], "home"))
    end

    return paths
end

function host_paths_to_cleanup(brg, config)
    return String[
        # We clean out our `/cache/build` directory every time
        joinpath(config.read_write_maps["/cache"], "build"),

        # We clean out our `/tmp` directory every time
        config.read_write_maps["/tmp"],
    ]
end

function generate_systemd_script(io::IO, brg::BuildkiteRunnerGroup; agent_name::String=string(brg.name, "-%i"), kwargs...)
    config = SandboxConfig(brg; agent_name, kwargs...)
    temp_path = config.read_write_maps["/tmp"]
    machine_id_path = joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id")

    with_executor(UnprivilegedUserNamespacesExecutor) do exe
        # Build full list of tags, with duplicate mappings for `queue`
        tags_with_queues = ["$tag=$value" for (tag, value) in brg.tags]
        append!(tags_with_queues, ["queue=$(queue)" for queue in brg.queues])

        c = Sandbox.build_executor_command(
            exe,
            config,
            ```/usr/bin/buildkite-agent start
                                --disconnect-after-job
                                --hooks-path=/hooks
                                --build-path=/cache/build
                                --experiment=git-mirrors,output-redactor
                                --git-mirrors-path=/cache/repos
                                --tags=$(join(tags_with_queues, ","))
                                --name=$(agent_name)
            ```
        )

        create_paths = host_paths_to_create(brg, config)
        cleanup_paths = host_paths_to_cleanup(brg, config)

        # Helper hook to create mountpoints on the host
        create_hook = SystemdBashTarget("mkdir -p $(join(create_paths, " "))")

        # Helper hook to cleanup paths on the host
        cleanup_hook = SystemdBashTarget(
            "chmod u+w -R $(join(cleanup_paths, " ")) 2>/dev/null ; rm -rf $(join(cleanup_paths, " ")) 2>/dev/null",
            [:IgnoreExitCode, :Sudo],
        )

        start_pre_hooks = SystemdTarget[
            # Clear out any ephemeral storage that existed from last time (we'll do this again after running)
            cleanup_hook,
            # Create mountpoints
            create_hook,
            # Create a machine-id file to get mounted in
            SystemdBashTarget("echo $(agent_name) | shasum | cut -c-32 > $(machine_id_path)"),
        ]

        stop_post_hooks = SystemdTarget[
            # Clean things up afterward too
            cleanup_hook,
        ]

        if brg.start_rootless_docker
            # Docker needs `HOME` and `XDG_RUNTIME_DIR` set to an agent-specific location, so as to not interfere
            # with other `dockerd` instances.  We clear these locations out every time.
            docker_home = config.env["TMPDIR"]
            docker_extras_dir = artifact"docker-rootless-extras/docker-rootless-extras"
            docker_env = join([
                "HOME=$(docker_home)/home",
                "XDG_DATA_HOME=$(docker_home)/home",
                "XDG_RUNTIME_DIR=$(docker_home)",
                "PATH=$(artifact"docker/docker"):$(docker_extras_dir):$(ENV["PATH"])",
            ], " ")

            # Add some startup hooks
            append!(start_pre_hooks, [
                # Start up a wrapped rootless `dockerd` instance.
                SystemdBashTarget("mkdir -p $(docker_home); $(docker_env) $(docker_extras_dir)/dockerd-rootless.sh >$(docker_home)/dockerd-rootless.log 2>&1 &"),
                # Wait until it's ready
                SystemdBashTarget("while [ ! -S $(docker_home)/docker.sock ]; do sleep 1; done"),
            ])

            # When we stop, kill the dockerd instance, and do so _before_ our cleanup
            insert!(stop_post_hooks, 1, SystemdBashTarget("kill -TERM \$(cat $(docker_home)/docker.pid)"))
        end

        systemd_config = SystemdConfig(;
            description="Sandboxed Buildkite agent $(agent_name)",
            working_dir="~",
            env=Dict(k => v for (k,v) in split.(c.env, Ref("="))),
            restart=SystemdRestartConfig(),
            start_timeout="1min",
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
                     cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                     temp_path::String = joinpath(tempdir(), "agent-tempdirs", agent_name))
    config = SandboxConfig(brg; agent_name, cache_path, temp_path)

    # Initial cleanup and creation
    function force_delete(path)
        try
            Base.Filesystem.prepare_for_deletion(path)
            rm(path; force=true, recursive=true)
        catch; end
    end
    force_delete.(host_paths_to_cleanup(brg, config))
    mkpath.(host_paths_to_create(brg, config))
    machine_id_path = joinpath(@get_scratch!("agent-cache"), "$(agent_name).machine-id")
    run(`/bin/bash -c "echo $(agent_name) | shasum | cut -c-32 > $(machine_id_path)"`)

    local docker_proc = nothing
    if brg.start_rootless_docker
        docker_home = config.env["TMPDIR"]
        docker_extras_dir = artifact"docker-rootless-extras/docker-rootless-extras"
        docker_proc = run(pipeline(setenv(
                `$(docker_extras_dir)/dockerd-rootless.sh`,
                Dict(
                    "HOME" => joinpath(docker_home, "home"),
                    "XDG_DATA_HOME" => joinpath(docker_home, "home"),
                    "XDG_RUNTIME_DIR" => docker_home,
                    "PATH" => "$(artifact"docker/docker"):$(docker_extras_dir):$(ENV["PATH"])",
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
        with_executor(UnprivilegedUserNamespacesExecutor) do exe
            run(exe, config, ignorestatus(`/bin/bash`))
        end
    finally
        if docker_proc !== nothing
            kill(docker_proc)
            wait(docker_proc)
        end
        force_delete.(host_paths_to_cleanup(brg, config))
    end
end
