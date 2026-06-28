function usage(io::IO=stdout)
    println(io, """
    usage: bk <command> [options]

    Commands:
      scheduler [--config PATH] [--dry-run] [--once]
      install [--config PATH] [--dry-run]
      uninstall
      debug-shell [--config PATH] <group>
    """)
end

function parse_config_flag(args::Vector{String}; default::String="config.toml")
    config_file = default
    rest = String[]
    idx = 1
    while idx <= length(args)
        arg = args[idx]
        if arg == "--config"
            idx += 1
            idx <= length(args) || error("--config requires a path")
            config_file = args[idx]
        elseif startswith(arg, "--config=")
            config_file = string(split(arg, "="; limit=2)[2])
        else
            push!(rest, arg)
        end
        idx += 1
    end
    return abspath(config_file), rest
end

function parse_scheduler_args(args::Vector{String})
    config_file, rest = parse_config_flag(args)
    dry_run = false
    once = false
    for arg in rest
        if arg == "--dry-run"
            dry_run = true
        elseif arg == "--once"
            once = true
        elseif arg == "--help" || arg == "-h"
            usage()
            exit(0)
        else
            error("unknown scheduler argument: $(arg)")
        end
    end
    return config_file, dry_run, once
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
            generate_scheduler_systemd_script(config_file; host)
            launch_scheduler_systemd_service()
        end
    elseif host == :macos
        if dry_run
            generate_scheduler_launchctl_script(stdout, config_file; dry_run=false, host)
        else
            generate_scheduler_launchctl_script(config_file; host)
            launch_scheduler_launchctl_service()
        end
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function uninstall_scheduler(; host::Symbol=host_os())
    if host == :linux
        uninstall_scheduler_systemd_service()
    elseif host == :macos
        uninstall_scheduler_launchctl_service()
    else
        error("Unsupported host OS $(host)")
    end
    return nothing
end

function run_debug_shell(config_file::String, group_name::String; host::Symbol=host_os())
    scheduler_config = read_scheduler_config(config_file)
    brgs = read_configs(config_file; host)
    brg = only(filter(brg -> brg.name == group_name, brgs))
    backend = make_backend(brg.backend, scheduler_config, brgs)
    check_config(backend, [candidate for candidate in brgs if candidate.backend == brg.backend])
    if backend isa LinuxSandboxBackend
        return debug_shell(backend, brg;
            cgroup_configs=[candidate for candidate in brgs if candidate.backend == brg.backend])
    else
        return debug_shell(backend, brg)
    end
end

function main(args::Vector{String}=ARGS)
    if isempty(args) || args[1] in ("--help", "-h")
        usage()
        return 0
    end

    command = first(args)
    command_args = args[2:end]
    if command == "scheduler"
        config_file, dry_run, once = parse_scheduler_args(command_args)
        run_scheduler(config_file; dry_run, once)
    elseif command == "install"
        config_file, rest = parse_config_flag(command_args)
        dry_run = false
        for arg in rest
            if arg == "--dry-run"
                dry_run = true
            else
                error("unknown install argument: $(arg)")
            end
        end
        install_scheduler(config_file; dry_run)
    elseif command == "uninstall"
        isempty(command_args) || error("uninstall does not accept arguments")
        uninstall_scheduler()
    elseif command == "debug-shell"
        config_file, rest = parse_config_flag(command_args)
        length(rest) == 1 || error("debug-shell requires exactly one runner group name")
        run_debug_shell(config_file, only(rest))
    else
        error("unknown command: $(command)")
    end
    return 0
end
