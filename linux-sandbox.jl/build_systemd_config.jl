using Sandbox, Scratch, Random, LazyArtifacts

docker = false
if "--docker" in ARGS
    if Sys.which("docker") === nothing || !success(`docker ps`)
        error("Cannot enable docker on a system without docker already installed!")
    end
    docker = true
end

rootfs = artifact"buildkite-agent-rootfs"
repo_root = dirname(@__DIR__)
buildkite_agent_token = String(chomp(String(read(joinpath(repo_root, "secrets", "buildkite-agent-token")))))
debug = "--debug" in ARGS
verbose = "--verbose" in ARGS

if debug
    agent_name = string(readchomp(`hostname`), ".0")
else
    # In normal operation, our "agent name" is set by systemd
    agent_name = "%i"
end

cache_path = joinpath(@get_scratch!("buildkite-agent-cache"), agent_name)
temp_path = joinpath(tempdir(), "buildkite-agent-tempdirs", agent_name)

# Set read-only mountings for rootfs, hooks and secrets
ro_maps = Dict(
    # Mount in rootfs
    "/" => rootfs,

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
    "BUILDKITE_AGENT_TOKEN" => buildkite_agent_token,
    "HOME" => "/root",

    # For anyone who wants to do nested sandboxing, tell them to store
    # persistent data here instead of in `/tmp`, since that's an overlayfs
    "SANDBOX_PERSISTENCE_DIR" => "/cache/sandbox_persistence",
    "FORCE_SANDBOX_MODE" => "unprivileged",
);

# If the user is asking for a docker-capable installation, make it so
if docker
    docker_socket_path = get(ENV, "DOCKER_HOST", "unix:///var/run/docker.sock")
    if startswith(docker_socket_path, "unix:/")
        docker_socket_path = docker_socket_path[7:end]
    end
    ro_maps["/usr/bin/docker"] = Sys.which("docker")
    rw_maps["/var/run/docker.sock"] = docker_socket_path
end

config = SandboxConfig(
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
)
with_executor(UnprivilegedUserNamespacesExecutor) do exe
    queue = "julia"
    queue_args = [split(arg, "=") for arg in ARGS if startswith(arg, "--queue=")]
    if !isempty(queue_args)
        queue = first(queue_args)[2]
    end
    if debug
        mkpath(cache_path)
        mkpath(temp_path)
        run(exe, config, `/bin/bash`)
        rm(temp_path; force=true, recursive=true)
    else
        tags = Dict(
            "queue" => queue,
            "arch" => "x86_64",
            "os" => "linux",
            "sandbox.jl" => "true",
        )
        if docker
            tags["docker_present"] = "true"
        end

        c = Sandbox.build_executor_command(exe, config, ```/usr/bin/buildkite-agent start
                                --disconnect-after-job
                                --hooks-path=/hooks
                                --build-path=/cache/build
                                --experiment=git-mirrors,output-redactor
                                --git-mirrors-path=/cache/repos
                                --tags=$(join(["$tag=$value" for (tag, value) in tags], ","))
                                --name=%i
        ```)
        systemd_dir = expanduser("~/.config/systemd/user")
        mkpath(systemd_dir)
        open(joinpath(systemd_dir, "buildkite-sandbox@.service"), write=true) do io
            write(io, """
            [Unit]
            Description=Sandboxed Buildkite agent %i

            StartLimitIntervalSec=60
            StartLimitBurst=5

            [Service]
            Type=simple
            WorkingDirectory=~
            TimeoutStartSec=1min
            ExecStartPre=/bin/bash -c "mkdir -p $(cache_path); rm -rf $(cache_path)/build"
            ExecStartPre=/bin/bash -c "rm -rf $(temp_path); mkdir -p $(temp_path)"
            ExecStart=$(join(c.exec, " "))
            ExecStopPost=/bin/bash -c "rm -rf $(cache_path)/build"
            ExecStopPost=/bin/bash -c "rm -rf $(temp_path)"
            Environment=$(join(["$k=\"$v\"" for (k, v) in split.(c.env, Ref("="))], " "))

            Restart=always
            RestartSec=1s

            [Install]
            WantedBy=multi-user.target
            """)
        end
        # Inform systemctl that some files on disk may have changed
        run(`systemctl --user daemon-reload`)
    end
end
