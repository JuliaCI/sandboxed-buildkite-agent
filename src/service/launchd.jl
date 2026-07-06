## launchd integration: render plists and drive launchctl.

# Render a launchd plist.  `keepalive` is raw plist XML for the KeepAlive
# value (e.g. "<true />"), or `nothing` to omit the key.
function launchd_plist(io::IO; label::String, program_args::Vector{String},
                       env::Dict{String,String}=Dict{String,String}(),
                       cwd::Union{String,Nothing}=nothing,
                       logpath::Union{String,Nothing}=nothing,
                       keepalive::Union{String,Nothing}=nothing)
    println(io, """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>Label</key>
            <string>$(label)</string>
            <key>RunAtLoad</key>
            <true />
            <key>ProgramArguments</key>
            <array>""")
    for word in program_args
        println(io, "        <string>$(word)</string>")
    end
    println(io, "    </array>")
    if keepalive !== nothing
        println(io, "    <key>KeepAlive</key>")
        println(io, "    $(keepalive)")
    end
    if cwd !== nothing
        println(io, "    <key>WorkingDirectory</key>")
        println(io, "    <string>$(cwd)</string>")
    end
    if logpath !== nothing
        println(io, "    <key>StandardOutPath</key>")
        println(io, "    <string>$(logpath)</string>")
        println(io, "    <key>StandardErrorPath</key>")
        println(io, "    <string>$(logpath)</string>")
    end
    if !isempty(env)
        println(io, "    <key>EnvironmentVariables</key>")
        println(io, "    <dict>")
        for (k, v) in env
            println(io, "        <key>$(k)</key>")
            println(io, "        <string>$(v)</string>")
        end
        println(io, "    </dict>")
    end
    println(io, "</dict></plist>")
    return nothing
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
        read(pipeline(`launchctl print $(scheduler_launchctl_target())`; stderr=devnull), String)
    catch err
        err isa InterruptException && rethrow()
        return false
    end
    return occursin(r"state = running|pid = [1-9]", output)
end

function launchctl_status_from_output(output::AbstractString)
    running = occursin(r"state = running|pid = [1-9]", output)
    detail = ""
    if !running
        m = match(r"last exit code = (-?\d+)", output)
        m === nothing || m.captures[1] == "0" || (detail = "last exit code=$(m.captures[1])")
    end
    return Dict{String,Any}(
        "installed" => true, "running" => running, "state" => running ? "running" : "stopped",
        "detail" => detail)
end

# launchd is the source of truth for liveness and the last exit; `bk status`
# reports this rather than inferring it from the status snapshot.
function scheduler_launchctl_service_status()
    scheduler_launchctl_service_installed() || return Dict{String,Any}(
        "installed" => false, "running" => false, "state" => "not installed", "detail" => "")
    output = try
        read(pipeline(`launchctl print $(scheduler_launchctl_target())`; stderr=devnull), String)
    catch err
        err isa InterruptException && rethrow()
        # Plist on disk but not loaded into launchd.
        return Dict{String,Any}(
            "installed" => true, "running" => false, "state" => "not loaded", "detail" => "")
    end
    return launchctl_status_from_output(output)
end

function generate_scheduler_launchctl_script(io::IO, config_file::String=abspath("config.toml");
                                             host::Symbol=host_os())
    scheduler_config, _ = read_config(config_file; host)
    args = String[
        String.(Base.julia_cmd().exec)...,
        "--project=$(REPO_ROOT)",
        repo_path("bin", "bk"),
        "--config=$(abspath(config_file))",
        "scheduler",
    ]

    mkpath(scheduler_config.logdir)
    launchd_plist(io;
        label=scheduler_launchctl_label(),
        program_args=args,
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
        # No KeepAlive: `RunAtLoad` starts the scheduler at load/boot, and a
        # fatal exit stays stopped (parallel to systemd `Restart=no`) so it is
        # diagnosable rather than respawning into the same fault.
    )
end

function generate_scheduler_launchctl_script(config_file::String=abspath("config.toml");
                                             plist_path::String=scheduler_plist_path(),
                                             kwargs...)
    scheduler_launchctl_service_installed(; plist_path) &&
        error("scheduler launchd service is already enabled; run `bk disable` first")
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

function stop_scheduler_launchctl_service()
    # `bootout` stops and unloads without writing a persistent disable (unlike
    # `unload -w`), so a reboot or `bk start` can bring the service back.
    run(ignorestatus(`launchctl bootout $(scheduler_launchctl_target())`))
    return nothing
end

function uninstall_scheduler_launchctl_service(; plist_path::String=scheduler_plist_path())
    if !scheduler_launchctl_service_installed(; plist_path)
        @info("Scheduler launchd service is not installed", label=scheduler_launchctl_label())
        return nothing
    end
    stop_scheduler_launchctl_service()
    rm(plist_path; force=true)
    return nothing
end
