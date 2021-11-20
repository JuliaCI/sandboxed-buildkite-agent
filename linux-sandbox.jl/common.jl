using TOML, Base.BinaryPlatforms, Sandbox, Scratch, LazyArtifacts

struct BuildkiteRunnerGroup
    # Group name, such as "surrogatization"
    name::String

    # Number of agents to spawn
    num_agents::Int

    # All the queues this runner will subscribe to
    queues::Set{String}

    # Any extra tags to be applied
    tags::Dict{String,String}

    # Whether this runner should spin up a rootless docker instance
    start_rootless_docker::Bool

    # Whether this runner should be run in verbose mode
    verbose::Bool
end

function BuildkiteRunnerGroup(name::String, config::Dict)
    queues = Set(split(get(config, "queues", "default"), ","))
    num_agents = get(config, "num_agents", 1)
    tags = get(config, "tags", Dict{String,String}())
    start_rootless_docker = get(config, "start_rootless_docker", false)
    verbose = get(config, "verbose", false)

    # If we're going to start up a rootless docker instance, advertise it!
    if start_rootless_docker
        tags["docker_present"] = "true"
    end

    # Encode some information about this runner
    tags["os"] = os(HostPlatform())
    tags["arch"] = arch(HostPlatform())
    tags["sandbox.jl"] = "true"

    return BuildkiteRunnerGroup(
        string(name),
        num_agents,
        queues,
        tags,
        start_rootless_docker,
        verbose,
    )
end

function read_configs(config_file::String=joinpath(@__DIR__, "config.toml"))
    config = TOML.parsefile(config_file)

    # Parse out each of the groups
    return map(sort(collect(keys(config)))) do group_name
        return BuildkiteRunnerGroup(group_name, config[group_name])
    end
end

function Sandbox.SandboxConfig(brg::BuildkiteRunnerGroup;
                       rootfs_dir::String = artifact"buildkite-agent-rootfs",
                       agent_token_path::String = joinpath(dirname(@__DIR__), "secrets", "buildkite-agent-token"),
                       agent_name::String = brg.name,
                       cache_path::String = joinpath(@get_scratch!("buildkite-agent-cache"), agent_name),
                       temp_path::String = joinpath(tempdir(), "buildkite-agent-tempdirs", agent_name),
                       )
    repo_root = dirname(@__DIR__)

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
        # We mount in the docker client (served from our artifact!)
        ro_maps["/usr/bin/docker"] = artifact"docker/docker/docker"

        # We also mount in a socket to talk with our docker rootless daemon
        # This doesn't actually start docker rootless; that is pending
        docker_socket_path = joinpath(temp_path, "docker", "docker.sock")
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

function generate_systemd_script(io::IO, brg::BuildkiteRunnerGroup; agent_name::String=string(brg.name, "-%i"), kwargs...)
    config = SandboxConfig(brg; agent_name, kwargs...)
    cache_path = config.read_write_maps["/cache"]
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

        # Create cache and temp path, clear out some ephemeral storage
        ExecStartPre=/bin/bash -c "mkdir -p $(cache_path) $(temp_path)"
        ExecStartPre=-/bin/bash -c "chmod u+w -R $(cache_path)/build $(temp_path); rm -rf $(cache_path)/build $(temp_path)/*"

        # Run the actual command
        ExecStart=$(join(c.exec, " "))

        # Clean things up after (we clean them up in startup as well, just to be safe)
        ExecStopPost=-/bin/bash -c "chmod u+w -R $(cache_path)/build $(temp_path); rm -rf $(cache_path)/build $(temp_path)/*"
        """)

        if brg.start_rootless_docker
            # Docker needs `HOME` and `XDG_RUNTIME_DIR` set to an agent-specific location, so as to not interfere
            # with other `dockerd` instances.  We clear these locations out every time.
            docker_extras_dir = artifact"docker-rootless-extras/docker-rootless-extras"
            docker_env = join([
                "HOME=$(temp_path)/docker",
                "XDG_RUNTIME_DIR=$(temp_path)/docker",
                "PATH=$(artifact"docker/docker"):$(docker_extras_dir):$(ENV["PATH"])",
            ], " ")

            write(io, """
            # Since we're using a wrapped rootless dockerd, start it up and kill it when we're done
            ExecStartPre=/bin/bash -c "mkdir -p $(temp_path)/docker; $(docker_env) $(docker_extras_dir)/dockerd-rootless.sh &"
            ExecStartPre=/bin/bash -c "while [ ! -S $(temp_path)/docker/docker.sock ]; do sleep 1; done"
            ExecStopPost=-/bin/bash -c "kill -TERM \$(cat $(temp_path)/docker/docker.pid)"
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
                     cache_path::String = joinpath(@get_scratch!("buildkite-agent-cache"), agent_name),
                     temp_path::String = joinpath(tempdir(), "buildkite-agent-tempdirs", agent_name))
    config = SandboxConfig(brg; agent_name, cache_path, temp_path)

    # Initial cleanup
    function force_delete(path)
        Base.Filesystem.prepare_for_deletion(path)
        rm(path; force=true, recursive=true)
    end
    force_delete(joinpath(cache_path, "build"))
    force_delete(temp_path)
    mkpath(cache_path)
    mkpath(temp_path)

    local docker_proc = nothing
    if brg.start_rootless_docker
        docker_temp = joinpath(temp_path, "docker")
        mkpath(docker_temp)
        docker_extras_dir = artifact"docker-rootless-extras/docker-rootless-extras"
        docker_proc = run(pipeline(setenv(
                `$(docker_extras_dir)/dockerd-rootless.sh`,
                Dict(
                    "HOME" => docker_temp,
                    "XDG_RUNTIME_DIR" => docker_temp,
                    "PATH" => "$(artifact"docker/docker"):$(docker_extras_dir):$(ENV["PATH"])",
                ),
            );
            stdout=joinpath(docker_temp, "dockerd.stdout"),
            stderr=joinpath(docker_temp, "dockerd.stderr"),
        ); wait=false)

        docker_socket_path = joinpath(docker_temp, "docker.sock")
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
        force_delete(temp_path)
    end
end
