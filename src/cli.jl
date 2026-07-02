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
    (name="enable", synopsis="[--dry-run]",
     summary="generate and enable the host scheduler service (does not start it)",
     options=["--dry-run   print the generated service file instead of enabling it"]),
    (name="start", synopsis="",
     summary="start the enabled scheduler service",
     options=String[]),
    (name="stop", synopsis="",
     summary="stop the running scheduler service and clean up backend resources",
     options=String[]),
    (name="status", synopsis="",
     summary="show scheduler service state and the latest scheduler snapshot",
     options=["--json   emit machine-readable status JSON"]),
    (name="logs", synopsis="[--scheduler | --slot SLOT [--job JOB] [--serial] | --list] [--lines N] [--follow]",
     summary="show scheduler or per-slot backend logs",
     options=["--scheduler   show supervisor logs (default when no selector is given)",
              "--slot SLOT   show the latest backend log for a scheduler slot",
              "--job JOB     show a specific job log within --slot",
              "--serial      show the KVM serial companion log for --slot/--job",
              "--list        list recent scheduler and per-slot log files",
              "--lines N     number of lines to show (default: 200)",
              "--follow, -f  follow logs",
              "--since TIME  systemd journal time filter for scheduler logs"]),
    (name="disable", synopsis="",
     summary="stop the scheduler service, disable it, and remove it",
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

function parse_enable_args(args::Vector{String})
    dry_run = false
    for arg in args
        if arg == "--dry-run"
            dry_run = true
        else
            error("unknown enable argument: $(arg)")
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
    json = false
    for arg in args
        if arg == "--json"
            json = true
        else
            error("unknown status argument: $(arg)")
        end
    end
    return (; json)
end

struct LogsOptions
    scheduler::Bool
    list::Bool
    slot::Union{Nothing,String}
    job::Union{Nothing,String}
    serial::Bool
    lines::Int
    follow::Bool
    since::Union{Nothing,String}
end

function parse_positive_int(value::AbstractString, name::AbstractString)
    parsed = tryparse(Int, value)
    parsed !== nothing && parsed > 0 || error("$(name) must be a positive integer")
    return parsed
end

function parse_option_value(args::Vector{String}, idx::Int, option::String)
    idx < length(args) || error("$(option) requires a value")
    return args[idx + 1], idx + 1
end

function parse_logs_args(args::Vector{String})
    scheduler = false
    list = false
    slot = nothing
    job = nothing
    serial = false
    lines = 200
    follow = false
    since = nothing

    idx = 1
    while idx <= length(args)
        arg = args[idx]
        if arg == "--scheduler"
            scheduler = true
        elseif arg == "--list"
            list = true
        elseif arg == "--slot"
            slot, idx = parse_option_value(args, idx, "--slot")
        elseif startswith(arg, "--slot=")
            slot = string(split(arg, "="; limit=2)[2])
        elseif arg == "--job"
            job, idx = parse_option_value(args, idx, "--job")
        elseif startswith(arg, "--job=")
            job = string(split(arg, "="; limit=2)[2])
        elseif arg == "--serial"
            serial = true
        elseif arg == "--lines" || arg == "-n"
            value, idx = parse_option_value(args, idx, arg)
            lines = parse_positive_int(value, arg)
        elseif startswith(arg, "--lines=")
            lines = parse_positive_int(split(arg, "="; limit=2)[2], "--lines")
        elseif arg == "--follow" || arg == "-f"
            follow = true
        elseif arg == "--since"
            since, idx = parse_option_value(args, idx, "--since")
        elseif startswith(arg, "--since=")
            since = string(split(arg, "="; limit=2)[2])
        else
            error("unknown logs argument: $(arg)")
        end
        idx += 1
    end

    selectors = count(identity, (scheduler, list, slot !== nothing))
    selectors <= 1 || error("logs accepts only one of --scheduler, --slot, or --list")
    job === nothing || slot !== nothing || error("--job requires --slot")
    serial == false || slot !== nothing || error("--serial requires --slot")
    !list || (!follow && since === nothing && job === nothing && !serial) ||
        error("--list cannot be combined with --follow, --since, --job, or --serial")
    if selectors == 0
        scheduler = true
    end
    return LogsOptions(scheduler, list, slot, job, serial, lines, follow, since)
end

function scheduler_from_config(config_file::String;
                               source=nothing,
                               dry_run::Bool=false,
                               host::Symbol=host_os())
    scheduler_config, brgs = read_config(config_file; host)
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

function enable_scheduler(config_file::String; dry_run::Bool=false, host::Symbol=host_os())
    scheduler, brgs, backends = scheduler_from_config(config_file; dry_run=true, host)
    check_scheduler_config(scheduler.config)
    dry_run || setup_backend_configs!(backends, brgs)

    # `enable` only writes and enables the unit (and runs host setup); it does not
    # start the scheduler -- run `bk start` for that.  It refuses to clobber an
    # already-enabled service: `bk disable` first so the running scheduler and its
    # jobs are torn down before a new configuration is written.
    if host == :linux
        if dry_run
            generate_scheduler_systemd_script(stdout, config_file; host)
        else
            scheduler_systemd_service_installed() &&
                error("scheduler service is already enabled; run `bk disable` first")
            generate_scheduler_systemd_script(config_file; host)
            enable_scheduler_systemd_service()
        end
    elseif host == :macos
        if dry_run
            generate_scheduler_launchctl_script(stdout, config_file; host)
        else
            scheduler_launchctl_service_installed() &&
                error("scheduler service is already enabled; run `bk disable` first")
            generate_scheduler_launchctl_script(config_file; host)
        end
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function cleanup_installed_scheduler_resources(config_file::String; host::Symbol=host_os())
    try
        scheduler, _brgs, _backends = scheduler_from_config(config_file; dry_run=true, host)
        cleanup_scheduler_resources!(scheduler)
    catch err
        @warn("Unable to clean scheduler resources during teardown",
            exception=(err, catch_backtrace()))
    end
    return nothing
end

function disable_scheduler(config_file::String; host::Symbol=host_os())
    # `disable` is the full teardown: it implies stopping the running scheduler and
    # cleaning up backend resources, not just turning off boot start.
    if host == :linux
        uninstall_scheduler_systemd_service()
        cleanup_installed_scheduler_resources(config_file; host)
    elseif host == :macos
        uninstall_scheduler_launchctl_service()
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function stop_scheduler_service(config_file::String; host::Symbol=host_os())
    if host == :linux
        if !scheduler_systemd_service_installed() && !scheduler_systemd_service_running()
            @info("Scheduler service is not enabled and no scheduler is running")
            return nothing
        end
        stop_scheduler_systemd_service()
        cleanup_installed_scheduler_resources(config_file; host)
    elseif host == :macos
        if !scheduler_launchctl_service_installed() && !scheduler_launchctl_service_running()
            @info("Scheduler service is not enabled and no scheduler is running")
            return nothing
        end
        stop_scheduler_launchctl_service()
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function start_scheduler_service(; host::Symbol=host_os())
    scheduler_service_installed(; host) ||
        error("scheduler service is not enabled; run `bk enable` first")
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

function status_value(dict, key, default=nothing)
    dict isa AbstractDict || return default
    return get(dict, key, default)
end

function format_age(now::Real, timestamp)
    timestamp === nothing && return "never"
    seconds = try
        Float64(now) - Float64(timestamp)
    catch
        return "unknown"
    end
    seconds < 0 && return string("in ", round(-seconds; digits=1), "s")
    return string(round(seconds; digits=1), "s ago")
end

function format_remaining(now::Real, timestamp)
    timestamp === nothing && return "none"
    seconds = try
        Float64(timestamp) - Float64(now)
    catch
        return "unknown"
    end
    return string(round(seconds; digits=1), "s")
end

function format_bytes(bytes)
    bytes === nothing && return "unknown"
    return string(round(Float64(bytes) / 2.0^30; digits=1), " GiB")
end

function format_percent(value)
    value === nothing && return "unknown"
    return string(round(Float64(value); digits=1), "%")
end

function read_status_snapshot_for_config(config_file::String)
    config = read_scheduler_config(config_file)
    return config, scheduler_status_path(config), read_scheduler_status_snapshot(config)
end

function print_scheduler_status_human(io::IO, service_state, config_error, snapshot_path, snapshot)
    println(io, "Scheduler service: enabled=$(service_state["enabled"]) running=$(service_state["running"])")
    if config_error !== nothing
        println(io, "Status snapshot: unavailable; unable to read config: $(config_error)")
        return nothing
    end
    if snapshot === nothing
        println(io, "Status snapshot: missing at $(snapshot_path)")
        return nothing
    end

    now = time()
    generated_at = status_value(snapshot, "generated_at")
    println(io, "Status snapshot: path=$(snapshot_path) age=$(format_age(now, generated_at)) pid=$(status_value(snapshot, "pid", "unknown")) dry_run=$(status_value(snapshot, "dry_run", "unknown"))")
    println(io, "Log dir: $(status_value(snapshot, "logdir", "unknown"))")

    pollers = sort(status_value(snapshot, "pollers", Any[]);
        by=p -> string(status_value(p, "runner_group", "")))
    if !isempty(pollers)
        println(io)
        println(io, "Pollers:")
        for poller in pollers
            group = status_value(poller, "runner_group", "unknown")
            last_success = format_age(now, status_value(poller, "last_success_at"))
            pending = status_value(poller, "pending_jobs", 0)
            paused = status_value(poller, "paused", false)
            dispatch = status_value(poller, "dispatch", false)
            error = status_value(poller, "last_error")
            error_text = error === nothing ? "" : " error=$(status_value(error, "message", "unknown"))"
            println(io, "  $(group): pending=$(pending) dispatch=$(dispatch) paused=$(paused) last_success=$(last_success)$(error_text)")
        end
    end

    slots = sort(status_value(snapshot, "slots", Any[]);
        by=s -> string(status_value(s, "name", "")))
    if !isempty(slots)
        println(io)
        println(io, "Slots:")
        for slot in slots
            name = status_value(slot, "name", "unknown")
            state = status_value(slot, "state", "unknown")
            group = status_value(slot, "runner_group", "unknown")
            backend = status_value(slot, "backend", "unknown")
            updated = format_age(now, status_value(slot, "updated_at"))
            job = status_value(slot, "job")
            job_text = job === nothing ? "" : " job=$(status_value(job, "id", "unknown"))"
            deadline = haskey(slot, "deadline_at") ? " deadline=$(format_remaining(now, slot["deadline_at"]))" : ""
            log_path = haskey(slot, "log_path") ? " log=$(slot["log_path"])" : ""
            println(io, "  $(name): $(state) group=$(group) backend=$(backend) updated=$(updated)$(job_text)$(deadline)$(log_path)")
        end
    end

    disks = sort(status_value(snapshot, "disks", Any[]);
        by=d -> string(status_value(d, "path", "")))
    if !isempty(disks)
        println(io)
        println(io, "Disks:")
        for disk in disks
            path = status_value(disk, "path", "unknown")
            if haskey(disk, "error")
                println(io, "  $(path): error=$(disk["error"])")
            else
                available = format_bytes(status_value(disk, "available_bytes"))
                total = format_bytes(status_value(disk, "total_bytes"))
                used = format_percent(status_value(disk, "used_percent"))
                println(io, "  $(path): available=$(available) total=$(total) used=$(used)")
            end
        end
    end
    return nothing
end

function scheduler_status(config_file::String; json::Bool=false,
                          host::Symbol=host_os(), io::IO=stdout)
    service_state = Dict{String,Any}(
        "enabled" => scheduler_service_installed(; host),
        "running" => scheduler_service_running(; host),
    )
    config = nothing
    snapshot_path = nothing
    snapshot = nothing
    config_error = nothing
    try
        config, snapshot_path, snapshot = read_status_snapshot_for_config(config_file)
    catch err
        config_error = sprint(showerror, err)
    end

    if json
        payload = Dict{String,Any}(
            "service" => service_state,
            "status_path" => snapshot_path,
            "status" => snapshot,
            "config_error" => config_error,
        )
        write(io, JSON.json(payload, 2))
        write(io, "\n")
    else
        print_scheduler_status_human(io, service_state, config_error, snapshot_path, snapshot)
    end
    return nothing
end

function scheduler_log_path(config::SchedulerConfig)
    return joinpath(config.logdir, "scheduler.log")
end

function checked_log_component(value::AbstractString, kind::AbstractString)
    safe = safe_path_component(value, "")
    safe == value || error("unsafe $(kind): $(value)")
    return safe
end

function slot_log_dir(config::SchedulerConfig, slot::AbstractString)
    return joinpath(config.logdir, checked_log_component(slot, "slot"))
end

function slot_log_path(config::SchedulerConfig, slot::AbstractString, job::AbstractString;
                       serial::Bool=false)
    suffix = serial ? ".serial.log" : ".log"
    return joinpath(slot_log_dir(config, slot), string(checked_log_component(job, "job"), suffix))
end

function slot_log_files(config::SchedulerConfig, slot::AbstractString; serial::Bool=false)
    dir = slot_log_dir(config, slot)
    isdir(dir) || return String[]
    files = String[]
    for entry in readdir(dir; join=true)
        isfile(entry) || continue
        base = basename(entry)
        if serial
            endswith(base, ".serial.log") && push!(files, entry)
        elseif endswith(base, ".log") && !endswith(base, ".serial.log")
            push!(files, entry)
        end
    end
    return sort(files; by=path -> stat(path).mtime, rev=true)
end

function latest_slot_log_path(config::SchedulerConfig, slot::AbstractString; serial::Bool=false)
    files = slot_log_files(config, slot; serial)
    isempty(files) && error("no $(serial ? "serial " : "")logs found for slot $(slot)")
    return first(files)
end

function describe_log_file(path::AbstractString)
    if !isfile(path)
        return "$(path) (missing)"
    end
    st = stat(path)
    return "$(path) size=$(st.size) age=$(format_age(time(), st.mtime))"
end

function run_tail(path::AbstractString; lines::Integer, follow::Bool)
    isfile(path) || error("log file does not exist: $(path)")
    args = String["tail", "-n", string(lines)]
    follow && push!(args, "-f")
    push!(args, path)
    run(Cmd(args))
    return nothing
end

function run_scheduler_logs(config::SchedulerConfig, options::LogsOptions; host::Symbol=host_os())
    if host == :linux && Sys.which("journalctl") !== nothing
        args = String["journalctl", "-u", scheduler_systemd_unit_name(), "--no-pager", "-n", string(options.lines)]
        if options.since !== nothing
            push!(args, "--since", options.since)
        end
        options.follow && push!(args, "-f")
        run(Cmd(args))
    else
        options.since === nothing || error("--since is only supported for systemd scheduler logs")
        run_tail(scheduler_log_path(config); lines=options.lines, follow=options.follow)
    end
    return nothing
end

function run_slot_logs(config::SchedulerConfig, options::LogsOptions)
    path = if options.job === nothing
        latest_slot_log_path(config, options.slot; serial=options.serial)
    else
        slot_log_path(config, options.slot, options.job; serial=options.serial)
    end
    run_tail(path; lines=options.lines, follow=options.follow)
    return nothing
end

function list_logs(config::SchedulerConfig; io::IO=stdout)
    println(io, "Scheduler log: ", describe_log_file(scheduler_log_path(config)))
    status_path = scheduler_status_path(config)
    println(io, "Status snapshot: ", describe_log_file(status_path))
    if !isdir(config.logdir)
        println(io, "Backend logs: $(config.logdir) (missing)")
        return nothing
    end
    println(io)
    println(io, "Latest slot logs:")
    for dir in sort(filter(isdir, readdir(config.logdir; join=true)); by=basename)
        slot = basename(dir)
        normal = slot_log_files(config, slot; serial=false)
        serial = slot_log_files(config, slot; serial=true)
        !isempty(normal) && println(io, "  $(slot): ", describe_log_file(first(normal)))
        !isempty(serial) && println(io, "  $(slot) serial: ", describe_log_file(first(serial)))
    end
    return nothing
end

function scheduler_logs(config_file::String, options::LogsOptions;
                        host::Symbol=host_os(), io::IO=stdout)
    config = read_scheduler_config(config_file)
    if options.list
        list_logs(config; io)
    elseif options.scheduler
        run_scheduler_logs(config, options; host)
    else
        run_slot_logs(config, options)
    end
    return nothing
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
        elseif command == "enable"
            enable_scheduler(config_file; dry_run=parse_enable_args(command_args))
        elseif command == "start"
            parse_no_args(command_args, "start")
            start_scheduler_service()
        elseif command == "stop"
            parse_stop_args(command_args)
            stop_scheduler_service(config_file)
        elseif command == "status"
            options = parse_status_args(command_args)
            scheduler_status(config_file; json=options.json)
        elseif command == "logs"
            scheduler_logs(config_file, parse_logs_args(command_args))
        elseif command == "disable"
            parse_no_args(command_args, "disable")
            disable_scheduler(config_file)
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
