using Sandbox, Scratch, Random

function ensure_agent_image_exists(; force::Bool=false)
    rootfs = @get_scratch!("buildkite-agent-rootfs")
    if !force && (isdir(rootfs) && isfile(joinpath(rootfs, "usr", "bin", "buildkite-agent")))
        return rootfs
    end

    @info("Rebuilding agent rootfs")
    run(`sudo rm -rf "$(rootfs)"`)
    mkdir(rootfs)

    if Sys.which("debootstrap") === nothing
        error("Must install `debootstrap`!")
    end
    
    # Utility functions
    getuid() = ccall(:getuid, Cint, ())
    getgid() = ccall(:getgid, Cint, ())
    
    release = "buster"
    @info("Running debootstrap")
    # Packages we need:
    deb_packages = [
        # For UTF-8 support
        "locales",
        # General package getting/installing packages
        "gnupg2",
        "curl",
        "wget",
        "apt-transport-https",
        "openssh-client",
        # We use these in our buildkite plugins a lot
        "openssl",
        "python3",
        "jq",
        # Everybody needs a little git in their lives
        "git",
        # Debugging
        "vim",
    ]
    run(`sudo debootstrap --variant=minbase --include=$(join(deb_packages, ",")) $(release) "$(rootfs)"`)

    # Download and install buildkite-agent
    @info("Installing buildkite-agent...")
    buildkite_install_cmd = """
    echo 'deb https://apt.buildkite.com/buildkite-agent stable main' >> /etc/apt/sources.list && \\
    curl -sL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x32A37959C2FA5C3C99EFBC32A79206696452D198" | apt-key add - && \\
    apt-get update && \\
    DEBIAN_FRONTEND=noninteractive apt-get install -y buildkite-agent
    """
    run(`sudo chroot $(rootfs) bash -c "$(buildkite_install_cmd)"`)

    # Remove special `dev` files
    @info("Cleaning up `/dev`")
    for f in readdir(joinpath(rootfs, "dev"); join=true)
        # Keep the symlinks around (such as `/dev/fd`), as they're useful
        if !islink(f)
            run(`sudo rm -rf "$(f)"`)
        end
    end
    
    # take ownership of the entire rootfs
    @info("Chown'ing rootfs")
    run(`sudo chown $(getuid()):$(getgid()) -R "$(rootfs)"`)
    
    # Write out a reasonable default resolv.conf
    open(joinpath(rootfs, "etc", "resolv.conf"), write=true) do io
        write(io, """
        nameserver 1.1.1.1
        nameserver 8.8.8.8
        nameserver 8.8.4.4
        nameserver 4.4.4.4
        """)
    end

    # Remove `_apt` user so that `apt` doesn't try to `setgroups()`
    @info("Removing `_apt` user")
    open(joinpath(rootfs, "etc", "passwd"), write=true, read=true) do io
        filtered_lines = filter(l -> !startswith(l, "_apt:"), readlines(io))
        truncate(io, 0)
        seek(io, 0)
        for l in filtered_lines
            println(io, l)
        end
    end

    # Set up the one true locale, UTF-8
    @info("Setting up UTF-8 locale")
    open(joinpath(rootfs, "etc", "locale.gen"), "a") do io
        println(io, "en_US.UTF-8 UTF-8")
    end
    @info("Regenerating locale")
    run(`sudo chroot --userspec=$(getuid()):$(getgid()) $(rootfs) locale-gen`)
    @info("Done!")

    return rootfs
end

rootfs = ensure_agent_image_exists(;force=false)
repo_root = dirname(@__DIR__)
buildkite_agent_token = String(chomp(String(read(joinpath(repo_root, "secrets", "buildkite-agent-token")))))

cache_path = joinpath(@get_scratch!("buildkite-agent-cache"), "%i")
config = SandboxConfig(
    # Set read-only mountings for rootfs, hooks and secrets
    Dict(
        # Mount in rootfs
        "/" => rootfs,

        # Mount in hooks and secrets (secrets will be un-mounted)
        "/hooks" => joinpath(repo_root, "hooks"),
        "/secrets" => joinpath(repo_root, "secrets"),
    ),
    # Set read-write mountings for our `/cache` directory
    Dict(
         "/cache" => cache_path,
    ),
    # Environment mappings
    Dict(
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => "/cache/julia-buildkite-plugin",
        "BUILDKITE_AGENT_TOKEN" => buildkite_agent_token,
        "HOME" => "/root",

        # For anyone who wants to do nested sandboxing, tell them to store
        # persistent data here instead of in `/tmp`, since that's an overlayfs
        "SANDBOX_PERSISTENCE_DIR" => "/cache/sandbox_persistence",
        "FORCE_SANDBOX_MODE" => "unprivileged",
    );
    stdin=stdin,
    stdout=stdout,
    stderr=stderr,
    # We keep ourselves as `root` so that we can unmount within the sandbox
    # uid=Sandbox.getuid(),
    # gid=Sandbox.getgid(),
)
with_executor(UnprivilegedUserNamespacesExecutor) do exe
    if "--debug" in ARGS
        run(exe, config, `/bin/bash`)
    else
        c = Sandbox.build_executor_command(exe, config, ```/usr/bin/buildkite-agent start
                                --disconnect-after-job
                                --hooks-path=/hooks
                                --build-path=/cache/build
                                --tags=queue=julia,arch=x86_64,os=linux,sandbox.jl=true
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
            ExecStart=$(join(c.exec, " "))
            ExecStartPost=/bin/bash -c "rm -rf $(cache_path)/build"
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
