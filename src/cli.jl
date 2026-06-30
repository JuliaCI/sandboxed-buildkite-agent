function usage(io::IO=stdout)
    println(io, "usage: bk [--config PATH] <command> [options]")
    println(io)
    println(io, "Commands:")
    for command in COMMANDS
        println(io, "  ", rpad(command.name, 14), command.summary)
    end
    println(io)
    println(io, "Global options:")
    println(io, "  --config PATH   path to the config file (default: ./config.toml)")
    println(io, "  -h, --help      show this help message")
end

const COMMANDS = (
    (name="scheduler", synopsis="[--dry-run] [--once]",
     summary="run the scheduler in the foreground",
     options=["--dry-run   check config and log selected jobs without running anything",
              "--once      poll once and exit instead of looping forever"]),
    (name="install", synopsis="[--dry-run]",
     summary="install and start the host scheduler service",
     options=["--dry-run   print the generated service file instead of installing it"]),
    (name="start", synopsis="",
     summary="resume an installed service after a graceful stop",
     options=String[]),
    (name="stop", synopsis="",
     summary="ask the running scheduler to drain and stop",
     options=String[]),
    (name="status", synopsis="",
     summary="show the status of the set-up",
     options=String[]),
    (name="uninstall", synopsis="",
     summary="stop, disable, and remove the scheduler service",
     options=String[]),
)

is_known_command(name::String) = any(command -> command.name == name, COMMANDS)

function command_usage(name::String, io::IO=stdout)
    command = only(filter(command -> command.name == name, COMMANDS))
    synopsis = isempty(command.synopsis) ? "" : " $(command.synopsis)"
    println(io, "usage: bk [--config PATH] $(command.name)$(synopsis)")
    println(io)
    println(io, command.summary)
    println(io)
    println(io, "Options:")
    if isempty(command.options)
        println(io, "  This command takes no options.")
    else
        for option in command.options
            println(io, "  ", option)
        end
    end
end

function parse_global_options(args::Vector{String}; default::String="config.toml")
    config_file = default
    want_help = false
    idx = 1
    while idx <= length(args)
        arg = args[idx]
        if arg == "--config"
            idx += 1
            idx <= length(args) || error("--config requires a path")
            config_file = args[idx]
        elseif startswith(arg, "--config=")
            config_file = string(split(arg, "="; limit=2)[2])
        elseif arg == "--help" || arg == "-h"
            want_help = true
        elseif startswith(arg, "-")
            error("unknown global option: $(arg)")
        else
            break
        end
        idx += 1
    end
    return abspath(config_file), want_help, args[idx:end]
end

function parse_scheduler_args(args::Vector{String})
    dry_run = false
    once = false
    for arg in args
        if arg == "--dry-run"
            dry_run = true
        elseif arg == "--once"
            once = true
        else
            error("unknown scheduler argument: $(arg)")
        end
    end
    return dry_run, once
end

function parse_install_args(args::Vector{String})
    dry_run = false
    for arg in args
        if arg == "--dry-run"
            dry_run = true
        else
            error("unknown install argument: $(arg)")
        end
    end
    return dry_run
end

function parse_no_args(args::Vector{String}, command::String)
    isempty(args) || error("$(command) does not accept arguments")
    return nothing
end

function parse_stop_args(args::Vector{String})
    return parse_no_args(args, "stop")
end

function parse_status_args(args::Vector{String})
    return parse_no_args(args, "status")
end

function scheduler_from_config(config_file::String;
                               source=nothing,
                               dry_run::Bool=false,
                               host::Symbol=host_os())
    scheduler_config = read_scheduler_config(config_file)
    brgs = read_configs(config_file; host)
    backends = make_backends(scheduler_config, brgs)
    dry_run || check_backend_configs(backends, brgs)
    job_source = source === nothing ? default_job_sources(scheduler_config, brgs) : source
    return Scheduler(scheduler_config, brgs, job_source, backends; dry_run), brgs, backends
end

function run_scheduler(config_file::String; dry_run::Bool=false, once::Bool=false,
                       source=nothing,
                       host::Symbol=host_os())
    scheduler, _, _ = scheduler_from_config(config_file; source, dry_run, host)
    if once
        start_scheduler!(scheduler)
        try
            return run_once!(scheduler)
        finally
            cleanup_scheduler!(scheduler)
        end
    else
        run_forever!(scheduler)
    end
end

run_scheduler(config_file::String, dry_run::Bool, once::Bool) =
    run_scheduler(config_file; dry_run, once)

function install_scheduler(config_file::String; dry_run::Bool=false, host::Symbol=host_os())
    scheduler, brgs, backends = scheduler_from_config(config_file; dry_run=true, host)
    check_scheduler_config(scheduler.config)
    dry_run || check_backend_configs(backends, brgs)

    if host == :linux
        if dry_run
            generate_scheduler_systemd_script(stdout, config_file; dry_run=false, host)
        else
            scheduler_systemd_service_installed() &&
                error("scheduler service is already installed; run `bk uninstall` first")
            generate_scheduler_systemd_script(config_file; host)
            launch_scheduler_systemd_service()
        end
    elseif host == :macos
        if dry_run
            generate_scheduler_launchctl_script(stdout, config_file; dry_run=false, host)
        else
            scheduler_launchctl_service_installed() &&
                error("scheduler service is already installed; run `bk uninstall` first")
            generate_scheduler_launchctl_script(config_file; host)
            launch_scheduler_launchctl_service()
        end
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function cleanup_installed_scheduler_backends(config_file::String; host::Symbol=host_os())
    try
        _scheduler, _brgs, backends = scheduler_from_config(config_file; dry_run=true, host)
        for backend in values(backends)
            cleanup(backend)
        end
    catch err
        @warn("Unable to clean scheduler backend resources during uninstall",
            exception=(err, catch_backtrace()))
    end
    return nothing
end

function uninstall_scheduler(config_file::String; host::Symbol=host_os())
    if host == :linux
        uninstall_scheduler_systemd_service()
        cleanup_installed_scheduler_backends(config_file; host)
    elseif host == :macos
        uninstall_scheduler_launchctl_service()
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function start_scheduler_service(; host::Symbol=host_os())
    scheduler_service_installed(; host) ||
        error("scheduler service is not installed; run `bk install` first")
    if scheduler_service_running(; host)
        @info("Scheduler service is already running")
        return nothing
    end
    if host == :linux
        start_scheduler_systemd_service()
    elseif host == :macos
        start_scheduler_launchctl_service()
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function scheduler_service_installed(; host::Symbol=host_os())
    if host == :linux
        return scheduler_systemd_service_installed()
    elseif host == :macos
        return scheduler_launchctl_service_installed()
    else
        error("Unsupported host OS $(host)")
    end
end

function scheduler_service_running(; host::Symbol=host_os())
    if host == :linux
        return scheduler_systemd_service_running()
    elseif host == :macos
        return scheduler_launchctl_service_running()
    else
        error("Unsupported host OS $(host)")
    end
end

function log_stop_status(status::AbstractDict)
    running_jobs = get(status, "running_jobs", 0)
    pending_jobs = get(status, "pending_jobs", 0)
    total_slots = get(status, "total_slots", 0)
    running_slots = get(status, "running_slots", String[])
    if get(status, "status", "") == "stopped"
        @info("Scheduler stopped", running_jobs, pending_jobs, total_slots)
    elseif get(status, "already_draining", false)
        @info("Scheduler is already draining", running_jobs, pending_jobs, total_slots, running_slots)
    else
        @info("Scheduler is draining", running_jobs, pending_jobs, total_slots, running_slots)
    end
    return nothing
end

function log_scheduler_status(status::AbstractDict)
    scheduler_status = get(status, "status", "unknown")
    draining = get(status, "draining", false)
    running_jobs = get(status, "running_jobs", 0)
    pending_jobs = get(status, "pending_jobs", 0)
    total_slots = get(status, "total_slots", 0)
    running_slots = get(status, "running_slots", String[])
    @info("Scheduler status", status=scheduler_status, draining, running_jobs,
        pending_jobs, total_slots, running_slots)
    return nothing
end

# Connect to the scheduler's control socket and run `f(conn, path)` against the
# first candidate that accepts a connection.  `on_no_socket` is invoked when no
# candidate socket file exists (scheduler not running); a socket that exists but
# refuses every connection is an error.
function with_control_connection(f::Function; on_no_socket::Function)
    failed = String[]
    saw_socket = false
    for path in control_socket_candidates()
        ispath(path) || continue
        saw_socket = true
        conn = try
            Sockets.connect(path)
        catch err
            push!(failed, "$(path): $(err)")
            continue
        end
        try
            return f(conn, path)
        finally
            close(conn)
        end
    end
    saw_socket || return on_no_socket()
    detail = isempty(failed) ? "" : " Connection failures: $(join(failed, "; "))"
    error("scheduler control socket exists, but no connection succeeded.$(detail)")
end

function scheduler_status()
    return with_control_connection(;
        on_no_socket = function ()
            installed = scheduler_service_installed()
            running = installed ? scheduler_service_running() : false
            @info("Scheduler status", installed, running, control_socket=false)
            return nothing
        end,
    ) do conn, _path
        println(conn, "status")
        flush(conn)
        status = JSON.parse(readline(conn))
        get(status, "status", "") == "error" &&
            error("scheduler returned control error: $(get(status, "message", status))")
        log_scheduler_status(status)
        return nothing
    end
end

function graceful_stop_scheduler()
    return with_control_connection(;
        on_no_socket = function ()
            if !scheduler_service_installed()
                @info("Scheduler service is not installed and no scheduler is running")
            elseif scheduler_service_running()
                error("scheduler service appears to be running, but no control socket was found")
            else
                @info("Scheduler service is installed but not running")
            end
            return nothing
        end,
    ) do conn, path
        println(conn, "stop")
        flush(conn)
        saw_status = false
        for line in eachline(conn)
            status = JSON.parse(line)
            get(status, "status", "") == "error" &&
                error("scheduler returned control error: $(get(status, "message", line))")
            log_stop_status(status)
            saw_status = true
        end
        saw_status || error("scheduler closed the stop connection without a status response")
        @info("Scheduler stop sequence complete", control_socket=path)
        return nothing
    end
end

function main(args::Vector{String}=ARGS)
    try
        config_file, want_help, rest = parse_global_options(args)
        if isempty(rest)
            usage()
            return 0
        end

        command = first(rest)
        command_args = rest[2:end]
        if want_help || "--help" in command_args || "-h" in command_args
            if is_known_command(command)
                command_usage(command)
            else
                usage()
            end
            return 0
        end

        if command == "scheduler"
            dry_run, once = parse_scheduler_args(command_args)
            run_scheduler(config_file; dry_run, once)
        elseif command == "install"
            install_scheduler(config_file; dry_run=parse_install_args(command_args))
        elseif command == "start"
            parse_no_args(command_args, "start")
            start_scheduler_service()
        elseif command == "stop"
            parse_stop_args(command_args)
            graceful_stop_scheduler()
        elseif command == "status"
            parse_status_args(command_args)
            scheduler_status()
        elseif command == "uninstall"
            parse_no_args(command_args, "uninstall")
            uninstall_scheduler(config_file)
        else
            error("unknown command: $(command)")
        end
        return 0
    catch err
        err isa InterruptException && rethrow()
        println(stderr, "bk: error: ", sprint(showerror, err))
        if !(err isa ErrorException) || haskey(ENV, "BK_DEBUG")
            Base.display_error(stderr, err, catch_backtrace())
        end
        return 1
    end
end
