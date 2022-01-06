#!/usr/bin/env julia
using LazyArtifacts

include("../common/buildkite_config.jl")
include("MacOSSandboxConfig.jl")

function generate_buildkite_sandbox(io::IO, workspaces::Vector{String}, temp_dir::String)
    # We'll generate here a MacOSSandboxConfig that allows us to run builds within a build prefix,
    # but not write to the rest of the system, nor read sensitive files
    config = MacOSSandboxConfig(;
        rules = vcat(
            # First, global rules that are not scoped in any way
            SandboxRule.([
                # These are foundational capabilities, and should potentially
                # be enabled for _all_ sandboxed processes?
                "process-fork", "process-info*", "process-codesigning-status*",
                "signal", "mach-lookup", "sysctl-read",

                # Running Julia's test suite requires IPC/shared memory mechanisms as well
                "ipc-posix-sem", "ipc-sysv-shm", "ipc-posix-shm",

                # Calling `getcwd()` on a non-existant file path returns `EACCES` instead of `ENOENT`
                # unless we give unrestricted `fcntl()` permissions.
                "system-fsctl",

                # For some reason, `access()` requires `process-exec` globally.
                # I don't know why this is, and Apple's own scripts have a giant shrug
                # in `/usr/share/sandbox/com.apple.smbd.sb` about this
                "process-exec",

                # We require network access
                "network-bind", "network-outbound", "network-inbound", "system-socket",
            ]),

            SandboxRule("file-read*", [
                # Provide read-only access to the majority of the system, but NOT `/Users`
                SandboxSubpath("/Applications"),
                SandboxSubpath("/Library"),
                SandboxSubpath("/System"),
                SandboxSubpath("/bin"),
                SandboxSubpath("/opt"),
                SandboxSubpath("/private/etc"),
                SandboxSubpath("/private/var"),
                SandboxSubpath("/sbin"),
                SandboxSubpath("/usr"),
                SandboxSubpath("/var"),

                # Specifically, allow read-only access to the entire parental chain of the workspace,
                # and the temporary directory.  Note that these are not recursive includes, but rather
                # precisely these directories
                vcat(dirname_chain.(workspaces)...)...,
                dirname_chain(temp_dir)...,

                # Allow reading of the buildkite agent, and our hooks directory
                SandboxSubpath(artifact"buildkite-agent"),
                SandboxSubpath(joinpath(dirname(@__DIR__), "hooks")),

                # Allow reading of user preferences and keychains
                SandboxSubpath(joinpath(homedir(), "Library", "Preferences")),

                # Also a few symlinks:
                "/tmp",
                "/etc",
            ]),

            # Provide read-write access to a more restricted set of files
            SandboxRule("file*", [
                # Allow control over TTY devices
                r"/dev/tty.*",
                "/dev/ptmx",
                "/private/var/run/utmpx",

                # Allow full control over the workspaces
                SandboxSubpath.(workspaces)...,

                # Allow reading/writing to the temporary directory
                SandboxSubpath(temp_dir),

                # Keychain access requires R/W access to a path in /private/var/folders whose path name is difficult to know beforehand
                SandboxSubpath("/private/var/folders"),
            ]),
        )
    )

    # Write the config out to the provided IO object
    generate_sandbox_config(io, config)
    return nothing
end

function build_sandbox_env(temp_path::String, cache_path::String;
                           agent_token_path::String = joinpath(dirname(@__DIR__), "secrets", "buildkite-agent-token"),)
    paths = [
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/bin",
        "/sbin",
    ]
    if Sys.ARCH == :aarch64
        if isdir("/opt/homebrew/Cellar")
            pushfirst!(paths, "/opt/homebrew/sbin")
            pushfirst!(paths, "/opt/homebrew/bin")
        end
    end
    return Dict(
        "TMPDIR" => joinpath(temp_path, "tmp"),
        "HOME" => joinpath(temp_path, "home"),
        "BUILDKITE_BIN_PATH" => artifact"buildkite-agent",
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => cache_path,
        "BUILDKITE_AGENT_TOKEN" => String(chomp(String(read(agent_token_path)))),
        "PATH" => join(paths, ":"),
        "TERM" => "screen",
    )
end

function host_paths_to_create(temp_path, cache_path)
    return String[
        joinpath(temp_path, "tmp"),
        joinpath(temp_path, "home"),
        joinpath(cache_path, "build"),
    ]
end

function host_paths_to_cleanup(temp_path, cache_path)
    return String[
        temp_path,
        joinpath(cache_path, "build"),
    ]
end

function force_delete(path)
    Base.Filesystem.prepare_for_deletion(path)
    rm(path; force=true, recursive=true)
end

default_agent_name(brg) = string(brg.name, "-", gethostname(), ".0")

function sandbox_setup(f::Function, brg::BuildkiteRunnerGroup;
                       agent_name::String = default_agent_name(brg),
                       cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                       temp_path::String = joinpath(tempdir(), "agent-tempdirs", agent_name))
    # Initial cleanup and creation
    force_delete.(host_paths_to_cleanup(temp_path, cache_path))
    mkpath.(host_paths_to_create(temp_path, cache_path))
    sandbox_env = build_sandbox_env(temp_path, cache_path)

    try
        # Prepare secrets by copying them in
        secrets_src_path = joinpath(dirname(@__DIR__), "secrets")
        secrets_dst_path = joinpath(cache_path, "secrets")
        cp(secrets_src_path, secrets_dst_path; force=true)

        cd(joinpath(cache_path, "build")) do
            with_sandbox(generate_buildkite_sandbox, [cache_path], temp_path) do sb_path
                if brg.verbose
                    run(`cat $(sb_path)`)
                    println()
                    println()
                end
                f(sb_path, sandbox_env)
            end
        end
    finally
        force_delete.(host_paths_to_cleanup(temp_path, cache_path))
    end       
end

function debug_shell(brg::BuildkiteRunnerGroup; kwargs...)
    mktempdir() do workspace
        sandbox_setup(brg; kwargs...) do sb_path, sandbox_env
            run(setenv(`sandbox-exec -f $(sb_path) /bin/bash`, sandbox_env))
        end
    end
end

function run_buildkite_agent(brg::BuildkiteRunnerGroup;
                             agent_name::String = default_agent_name(brg),
                             cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                             kwargs...)
    sandbox_setup(brg; agent_name, cache_path, kwargs...) do sb_path, sandbox_env
        agent_path = artifact"buildkite-agent/buildkite-agent"
        hooks_path = joinpath(dirname(@__DIR__), "hooks")

        tags_with_queues = ["$tag=$value" for (tag, value) in brg.tags]
        append!(tags_with_queues, ["queue=$(queue)" for queue in brg.queues])

        agent_cmd = ```$(agent_path) start
            --disconnect-after-job
            --hooks-path=$(hooks_path)
            --build-path=$(cache_path)/build
            --experiment=git-mirrors,output-redactor
            --git-mirrors-path=$(cache_path)/repos
            --tags=$(join(tags_with_queues, ","))
            --name=$(agent_name)
        ```
        run(setenv(`sandbox-exec -f $(sb_path) $(agent_cmd)`, sandbox_env))
    end
end

struct LaunchctlConfig
    label::String
    target::Vector{String}

    env::Dict{String,String}
    cwd::Union{String,Nothing}
    logpath::Union{String,Nothing}
    keepalive::Union{Bool,Nothing}

    function LaunchctlConfig(label, target; env = Dict{String,String}(), cwd = nothing, logpath = nothing, keepalive = true)
        return new(label, target, env, cwd, logpath, keepalive)
    end
end

function write(io::IO, config::LaunchctlConfig)
    println(io, """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    """)

    # Job label, e.g. "org.julialang.buildkite.solstice-default.0"
    println(io, """
        <key>Label</key>
        <string>$(config.label)</string>
    """)

    # Target process to launch
    print(io, """
        <key>ProgramArguments</key>
            <array>
    """)
    for word in config.target
        println(io, "            <string>$(word)</string>")
    end
    println(io, """
            </array>
    """)

    # If we've been asked to print a keepalive
    if config.keepalive !== nothing
        println(io, """
            <key>KeepAlive</key>
            <$(config.keepalive) />
        """)
    end

    if config.cwd !== nothing
        println(io, """
            <key>WorkingDirectory</key>
            <string>$(config.cwd)</string>
        """)
    end

    if config.logpath !== nothing
        println(io, """
            <key>StandardOutPath</key>
            <string>$(config.logpath)</string>
            <key>StandardErrorPath</key>
            <string>$(config.logpath)</string>
        """)
    end

    # Write out environment variables path
    print(io, """
        <key>EnvironmentVariables</key>
        <dict>
    """)
    for (k, v) in config.env
        println(io, """
                <key>$(k)</key>
                <string>$(v)</string>
        """)
    end
    println(io, """
        </dict>
    </dict></plist>
    """)
end

function generate_launchctl_script(io::IO, brg::BuildkiteRunnerGroup;
                                   agent_name::String = default_agent_name(brg),
                                   cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                                   temp_path::String = joinpath(tempdir(), "agent-tempdirs", agent_name),
                                   kwargs...)
    # Output wrapper scripts, sandbox definitions, etc... into this directory
    wrapper_dir = joinpath(cache_path, "wrappers")
    force_delete(wrapper_dir)
    mkpath(wrapper_dir)
    mkpath.(host_paths_to_create(temp_path, cache_path))

    # First, create sandbox definition
    sb_path = joinpath(wrapper_dir, "sandbox.sb")
    open(sb_path, write=true) do sb_io
        generate_buildkite_sandbox(sb_io, [cache_path], temp_path)
    end

    # Collect relevant information for wrapper script
    agent_path = artifact"buildkite-agent/buildkite-agent"
    hooks_path = joinpath(dirname(@__DIR__), "hooks")
    tags_with_queues = ["$tag=$value" for (tag, value) in brg.tags]
    append!(tags_with_queues, ["queue=$(queue)" for queue in brg.queues])

    # Create setup/teardown wrapper script
    wrapper_path = joinpath(wrapper_dir, "wrapper.sh")
    secrets_src_path = joinpath(dirname(@__DIR__), "secrets")
    secrets_dst_path = joinpath(cache_path, "secrets")
    open(wrapper_path, write=true) do w_io
        print(w_io, """
        #!/bin/bash

        # Cleanup host paths to protect against stale state leaking
        """)

        for path in host_paths_to_cleanup(temp_path, cache_path)
            println(w_io, "rm -rf $(path)")
        end

        print(w_io, """
        # Create host paths that must exist
        """)
        for path in host_paths_to_create(temp_path, cache_path)
            println(w_io, "mkdir -p $(path)")
        end

        println(w_io, """
        # Copy secrets into cache directory, which will be deleted by agent environment hook
        rm -rf $(secrets_dst_path)
        cp -Ra $(secrets_src_path) $(secrets_dst_path)

        # Invoke agent inside of sandbox
        sandbox-exec -f $(sb_path) $(agent_path) start \\
            --disconnect-after-job \\
            --hooks-path=$(hooks_path) \\
            --build-path=$(cache_path)/build \\
            --experiment=git-mirrors,output-redactor \\
            --git-mirrors-path=$(cache_path)/repos \\
            --tags=$(join(tags_with_queues, ",")) \\
            --name=$(agent_name)
        """)

        print(w_io, """
        # Cleanup host paths
        """)
        for path in host_paths_to_cleanup(temp_path, cache_path)
            println(w_io, "rm -rf $(path)")
        end
    end

    # Create launchctl script
    lctl_config = LaunchctlConfig(
        "org.julialang.buildkite.$(agent_name)",
        ["/bin/sh", wrapper_path];
        env = build_sandbox_env(temp_path, cache_path),
        cwd = joinpath(cache_path, "build"),
        logpath = joinpath(cache_path, "agent.log"),
        keepalive = true,
    )
    write(io, lctl_config)
end

function default_plist_path(agent_name::String)
    return joinpath(expanduser("~"), "Library", "LaunchAgents", "org.julialang.buildkite.$(agent_name).plist")
end
function generate_launchctl_script(brg::BuildkiteRunnerGroup;
                                   agent_name::String = default_agent_name(brg),
                                   plist_path::String = default_plist_path(agent_name),
                                   kwargs...)
    mkpath(dirname(plist_path))
    open(plist_path, write=true) do io
        generate_launchctl_script(io, brg; kwargs...)
    end
    return plist_path
end

function launch_launchctl_services(brgs::Vector{BuildkiteRunnerGroup})
    for brg in brgs
        plist_path = default_plist_path(default_agent_name(brg))
        # Force unload, so that if we already have one started, it can be replaced
        run(ignorestatus(`launchctl unload -w $(plist_path)`))
        run(`launchctl load -w $(plist_path)`)
    end
end

function stop_launchctl_services(brgs::Vector{BuildkiteRunnerGroup})
    for brg in brgs
        plist_path = default_plist_path(default_agent_name(brg))
        run(ignorestatus(`launchctl unload -w $(plist_path)`))
    end
end

function clear_launchctl_services()
    services = filter(readdir("/Library/LaunchDaemons")) do f
        return startswith(f, "org.julialang.buildkite") && endswith(f, ".plist")
    end
    for service in services
        plist_path = joinpath("/Library", "LaunchDaemons", service)
        run(ignorestatus(`launchctl unload -w $(plist_path)`))
        rm(plist_path; force=true)
    end

    for f in readdir(expanduser("~/.config/systemd/user"); join=true)
        if startswith(basename(f), "buildkite-sandbox-")
            rm(f)
        end
    end
end
