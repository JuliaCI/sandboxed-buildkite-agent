#!/usr/bin/env julia
using LazyArtifacts

include("../common/common.jl")

# Given a BuildkiteRunnerGroup, generate the launchctl script to start it up
function generate_launchctl_script(io::IO, brg::BuildkiteRunnerGroup;
                                   agent_name::String = default_agent_name(brg),
                                   cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                                   temp_path::String = joinpath(tempdir(brg), "agent-tempdirs", agent_name),
                                   kwargs...)
    # Output wrapper scripts, sandbox definitions, etc... into this directory
    wrapper_dir = joinpath(cache_path, "wrappers")
    force_delete(wrapper_dir)
    mkpath(wrapper_dir)
    mkpath.(host_paths_to_create(temp_path, cache_path))

    # First, create sandbox definition
    sb_path = joinpath(wrapper_dir, "sandbox.sb")
    open(sb_path, write=true) do sb_io
        generate_buildkite_seatbelt_config(sb_io, [cache_path], temp_path)
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
        env = build_seatbelt_env(temp_path, cache_path),
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
    launchctl_dir = dirname(default_plist_path(""))
    services = filter(readdir(launchctl_dir)) do f
        return startswith(f, "org.julialang.buildkite") && endswith(f, ".plist")
    end
    for service in services
        plist_path = joinpath(launchctl_dir, service)
        run(ignorestatus(`launchctl unload -w $(plist_path)`))
        rm(plist_path; force=true)
    end
end


function build_seatbelt_env(temp_path::String, cache_path::String;
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
        "BUILDKITE_PLUIGIN_CRYPYTIC_SECRETS_MOUNT_POINT" => joinpath(cache_path, "secrets"),
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
        joinpath(cache_path, "build", "*"),
    ]
end

function force_delete(path)
    Base.Filesystem.prepare_for_deletion(path)
    rm(path; force=true, recursive=true)
end

default_agent_name(brg) = string(brg.name, "-", gethostname(), ".0")

function seatbelt_setup(f::Function, brg::BuildkiteRunnerGroup;
                       agent_name::String = default_agent_name(brg),
                       cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                       temp_path::String = joinpath(tempdir(brg), "agent-tempdirs", agent_name))
    # Initial cleanup and creation
    force_delete.(host_paths_to_cleanup(temp_path, cache_path))
    mkpath.(host_paths_to_create(temp_path, cache_path))
    seatbelt_env = build_seatbelt_env(temp_path, cache_path)

    try
        # Prepare secrets by copying them in
        secrets_src_path = joinpath(dirname(@__DIR__), "secrets")
        secrets_dst_path = joinpath(cache_path, "secrets")
        cp(secrets_src_path, secrets_dst_path; force=true)

        cd(joinpath(cache_path, "build")) do
            with_seatbelt(generate_buildkite_seatbelt_config, [cache_path], temp_path) do sb_path
                if brg.verbose
                    run(`cat $(sb_path)`)
                    println()
                    println()
                end
                f(sb_path, seatbelt_env)
            end
        end
    finally
        force_delete.(host_paths_to_cleanup(temp_path, cache_path))
    end       
end

function debug_shell(brg::BuildkiteRunnerGroup; kwargs...)
    mktempdir() do workspace
        seatbelt_setup(brg; kwargs...) do sb_path, seatbelt_env
            run(setenv(`sandbox-exec -f $(sb_path) /bin/bash`, seatbelt_env))
        end
    end
end

function run_buildkite_agent(brg::BuildkiteRunnerGroup;
                             agent_name::String = default_agent_name(brg),
                             cache_path::String = joinpath(@get_scratch!("agent-cache"), agent_name),
                             kwargs...)
    seatbelt_setup(brg; agent_name, cache_path, kwargs...) do sb_path, seatbelt_env
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
            --git-fetch-flags="-v --prune --tags"
            --tags=$(join(tags_with_queues, ","))
            --name=$(agent_name)
        ```
        run(setenv(`sandbox-exec -f $(sb_path) $(agent_cmd)`, seatbelt_env))
    end
end

