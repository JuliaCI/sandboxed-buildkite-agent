## General utilities for dealing with `launchd` on macOS
## Note; this file needs the `buildkite_config.jl` and `mac_seatbelt_config.jl` files both to be defined!

struct LaunchctlConfig
    # The label of the launchctl job, usually "org.julialang.buildkite.$(agent_name)"
    label::String
    # The execution target, usually something like ["/bin/sh", "-c", "foo"]
    target::Vector{String}

    # Environment variables to set
    env::Dict{String,String}

    # Working directory
    cwd::Union{String,Nothing}

    # File that would contain `stdout` and `stderr`
    logpath::Union{String,Nothing}

    # Whether the job should be restarted after it dies
    keepalive::Union{NamedTuple,Bool,Nothing}

    function LaunchctlConfig(label, target; env = Dict{String,String}(), cwd = nothing, logpath = nothing, keepalive = nothing)
        return new(label, target, env, cwd, logpath, keepalive)
    end
end

# Generate the XML representation of the `LaunchctlConfig` object
function Base.write(io::IO, config::LaunchctlConfig)
    println(io, """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    """)

    # Job label, e.g. "org.julialang.buildkite.solstice-default.1"
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
        println(io, "        <string>$(word)</string>")
    end
    println(io, """
        </array>
    """)

    # We always want these things to be run at load
    println(io, """
        <key>RunAtLoad</key>
        <true />
    """)

    # If we've been asked to print a keepalive
    if config.keepalive isa NamedTuple || config.keepalive isa Dict
        print(io, """
            <key>KeepAlive</key>
            <dict>
        """)
        for k in keys(config.keepalive)
            v = config.keepalive[k]
            print(io, """
                    <key>$k</key>
                    <$v />
            """)
        end
        println(io, """
            </dict>
        """)
    elseif config.keepalive !== nothing
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

function scheduler_launchctl_label()
    return "org.julialang.buildkite.scheduler.$(get_short_hostname())"
end

function scheduler_plist_path()
    return joinpath(expanduser("~"), "Library", "LaunchAgents", "$(scheduler_launchctl_label()).plist")
end

function scheduler_launchctl_service_installed(; plist_path::String=scheduler_plist_path())
    return isfile(plist_path)
end

function scheduler_launchctl_service_running()
    output = try
        read(`launchctl print $(scheduler_launchctl_target())`, String)
    catch err
        err isa InterruptException && rethrow()
        return false
    end
    return occursin(r"state = running|pid = [1-9]", output)
end

function generate_scheduler_launchctl_script(io::IO, config_file::String=abspath("config.toml");
                                             dry_run::Bool=false,
                                             host::Symbol=host_os())
    read_configs(config_file; host)
    scheduler_config = read_scheduler_config(config_file)
    args = String[
        String.(Base.julia_cmd().exec)...,
        "--project=$(REPO_ROOT)",
        repo_path("bin", "bk"),
        "--config=$(abspath(config_file))",
        "scheduler",
    ]
    dry_run && push!(args, "--dry-run")

    mkpath(scheduler_config.logdir)
    lctl_config = LaunchctlConfig(
        scheduler_launchctl_label(),
        args;
        env=Dict("PATH" => join([
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/usr/sbin",
            "/bin",
            "/sbin",
        ], ":")),
        cwd=REPO_ROOT,
        logpath=joinpath(scheduler_config.logdir, "scheduler.log"),
        keepalive=(; SuccessfulExit=false),
    )
    write(io, lctl_config)
end

function generate_scheduler_launchctl_script(config_file::String=abspath("config.toml");
                                             plist_path::String=scheduler_plist_path(),
                                             kwargs...)
    scheduler_launchctl_service_installed(; plist_path) &&
        error("scheduler launchd service is already installed; run `bk uninstall` first")
    @info("Installing scheduler launchd service", label=scheduler_launchctl_label())
    mkpath(dirname(plist_path))
    open(plist_path, write=true) do io
        generate_scheduler_launchctl_script(io, config_file; kwargs...)
    end
    return plist_path
end

function launch_scheduler_launchctl_service(; plist_path::String=scheduler_plist_path())
    @info("Launching $(basename(plist_path))")
    run(ignorestatus(`launchctl unload -w $(plist_path)`))
    run(`launchctl load -w $(plist_path)`)
end

function scheduler_launchctl_target()
    uid = ccall(:getuid, UInt32, ())
    return "gui/$(uid)/$(scheduler_launchctl_label())"
end

function start_scheduler_launchctl_service(; plist_path::String=scheduler_plist_path())
    target = scheduler_launchctl_target()
    @info("Starting $(scheduler_launchctl_label())")
    proc = run(ignorestatus(`launchctl kickstart -k $(target)`))
    success(proc) && return nothing
    launch_scheduler_launchctl_service(; plist_path)
    return nothing
end

function stop_scheduler_launchctl_service(; plist_path::String=scheduler_plist_path())
    run(ignorestatus(`launchctl unload -w $(plist_path)`))
end

function uninstall_scheduler_launchctl_service(; plist_path::String=scheduler_plist_path())
    if !scheduler_launchctl_service_installed(; plist_path)
        @info("Scheduler launchd service is not installed", label=scheduler_launchctl_label())
        return nothing
    end
    stop_scheduler_launchctl_service(; plist_path)
    rm(plist_path; force=true)
    return nothing
end
