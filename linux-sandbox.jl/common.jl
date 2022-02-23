using TOML, Base.BinaryPlatforms, Sandbox, Scratch, LazyArtifacts

include("../common/buildkite_config.jl")

function Sandbox.SandboxConfig(brg::BuildkiteRunnerGroup;
                       rootfs_dir::String = artifact"buildkite-agent-rootfs",
                       agent_token_path::String = joinpath(dirname(@__DIR__), "secrets", "buildkite-agent-token"),
                       agent_name::String = brg.name,
                       cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                       temp_path::String = joinpath(tempdir(), "agent-tempdirs", agent_name),
                       )
    repo_root = dirname(@__DIR__)

    if get(brg.tags, "sandbox.jl", "false") != "true"
        error("Refusing to start up a `sandbox.jl` runner that does not self-identify through tags!")
    end

    # Set read-only mountings for rootfs, hooks and secrets
    ro_maps = Dict(
        # Mount in rootfs
        "/" => rootfs_dir,

        # Mount in hooks and secrets (secrets will be un-mounted)
        "/hooks" => joinpath(repo_root, "hooks"),
        "/secrets" => joinpath(repo_root, "secrets"),
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
        write(io, """
        [Unit]
        Description=Sandboxed Buildkite agent $(agent_name)

        [Service]
        # Always try to restart, up to 3 times in 60 seconds
        StartLimitIntervalSec=60
        StartLimitBurst=3
        Restart=always
        RestartSec=1s

        # If we don't start up within 15 seconds, fail out
        TimeoutStartSec=15

        Type=simple
        WorkingDirectory=~
        TimeoutStartSec=1min

        # Embed all environment variables that were part of the sandbox execution command
        Environment=$(join(["$k=\"$v\"" for (k, v) in split.(c.env, Ref("="))], " "))

        # Clear out any ephemeral storage that existed from last time (we'll do this again after running)
        ExecStartPre=-/bin/bash -c "chmod u+w -R $(join(cleanup_paths, " ")) ; rm -rf $(join(cleanup_paths, " "))"

        # Create mountpoints
        ExecStartPre=/bin/bash -c "mkdir -p $(join(create_paths, " "))"

        # Run the actual command
        ExecStart=$(join(c.exec, " "))

        # Clean things up after (we clean them up in startup as well, just to be safe)
        ExecStopPost=-/bin/bash -c "chmod u+w -R $(join(cleanup_paths, " ")) ; rm -rf $(join(cleanup_paths, " "))"
        """)

        if brg.start_rootless_docker
            # Docker needs `HOME` and `XDG_RUNTIME_DIR` set to an agent-specific location, so as to not interfere
            # with other `dockerd` instances.  We clear these locations out every time.
            # We furthermore ensure they are at a stable mountpoint, if we have such a thing:
            docker_home = config.env["TMPDIR"]
            docker_extras_dir = artifact"docker-rootless-extras/docker-rootless-extras"
            docker_env = join([
                "HOME=$(docker_home)/home",
                "XDG_DATA_HOME=$(docker_home)/home",
                "XDG_RUNTIME_DIR=$(docker_home)",
                "PATH=$(artifact"docker/docker"):$(docker_extras_dir):$(ENV["PATH"])",
            ], " ")

            write(io, """
            # Since we're using a wrapped rootless dockerd, start it up and kill it when we're done
            ExecStartPre=/bin/bash -c "mkdir -p $(docker_home); $(docker_env) $(docker_extras_dir)/dockerd-rootless.sh &"
            ExecStartPre=/bin/bash -c "while [ ! -S $(docker_home)/docker.sock ]; do sleep 1; done"
            ExecStartPre=-/bin/bash -c "docker system prune --all --filter \"until=48h\" --force"
            ExecStopPost=-/bin/bash -c "kill -TERM \$(cat $(docker_home)/docker.pid)"
            ExecStopPost=-/bin/bash -c "docker system prune --all --filter \"until=48h\" --force"
            """)
        end

        # Add `install` target
        write(io, """
        [Install]
        WantedBy=multi-user.target
        """)
    end
end

function generate_systemd_script(brg::BuildkiteRunnerGroup; kwargs...)
    systemd_dir = expanduser("~/.config/systemd/user")
    mkpath(systemd_dir)
    open(joinpath(systemd_dir, "buildkite-sandbox-$(brg.name)@.service"), write=true) do io
        generate_systemd_script(io, brg; kwargs...)
    end
    # Inform systemctl that some files on disk may have changed
    run(`systemctl --user daemon-reload`)
end

function systemd_unit_name(brg::BuildkiteRunnerGroup, agent_idx::Int; hostname::AbstractString = readchomp(`hostname`))
    return string("buildkite-sandbox-", brg.name, "@", hostname, ".", agent_idx)
end

function clear_systemd_configs()
    run(ignorestatus(`systemctl --user stop buildkite-sandbox-\*`))

    for f in readdir(expanduser("~/.config/systemd/user"); join=true)
        if startswith(basename(f), "buildkite-sandbox-")
            rm(f)
        end
    end
end

function launch_systemd_services(brgs::Vector{BuildkiteRunnerGroup}; hostname::AbstractString = readchomp(`hostname`))
    agent_idx = 0
    # Sort `brgs` by name, for consistent ordering
    brgs = sort(brgs, by=brg -> brg.name)
    for brg in brgs
        for _ in 1:brg.num_agents
            unit_name = systemd_unit_name(brg, agent_idx; hostname)
            run(`systemctl --user enable $(unit_name)`)
            run(`systemctl --user start $(unit_name)`)
            agent_idx += 1
        end
    end
end

function stop_systemd_services(brgs::Vector{BuildkiteRunnerGroup}; hostname::AbstractString = readchomp(`hostname`))
    agent_idx = 0
    brgs = sort(brgs, by=brg -> brg.name)
    for brg in brgs
        for _ in 1:brg.num_agents
            unit_name = systemd_unit_name(brg, agent_idx; hostname)
            run(`systemctl --user stop $(unit_name)`)
            run(`systemctl --user disable $(unit_name)`)
            agent_idx += 1
        end
    end
end

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
