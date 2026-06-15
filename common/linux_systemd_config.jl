#!/usr/bin/env julia

struct SystemdRestartConfig
    # How quickly to try restarting
    RestartSec::Int

    # Whether to stop trying to restart if we exceed this many tries in so many seconds
    StartLimitBurst::Int
    StartLimitIntervalSec::Int

    # Give some reasonable defaults, such as trying to restart every second,
    # but giving up if we try to restart 10 times within 2 minutes.
    function SystemdRestartConfig(RestartSec::Int = 1,
                                  StartLimitBurst::Int = 10,
                                  StartLimitIntervalSec::Int = StartLimitBurst * (RestartSec + 10) + 10)
        return new(RestartSec, StartLimitBurst, StartLimitIntervalSec)
    end
end

struct SystemdTarget
    command::String
    flags::Set{Symbol}

    function SystemdTarget(command, flags = Symbol[])
        for f in flags
            # We only support a subset of command flags
            if f ∉ (:IgnoreExitCode, :Sudo)
                throw(ArgumentError("Invalid SystemdTarget hook '$(f)'"))
            end
        end
        return new(string(command), Set(flags))
    end
end
SystemdBashTarget(command::String, flags = Symbol[]) = SystemdTarget("/bin/bash -c \"$(command)\"", flags)

function Base.println(io::IO, hook_name::String, t::SystemdTarget)
    write(io, hook_name, "=")
    if :IgnoreExitCode in t.flags
        write(io, "-")
    end
    if :Sudo in t.flags
        write(io, "+")
    end
    write(io, t.command, "\n")
end

struct SystemdConfig
    # Usually something like "multi-user.target"
    wanted_by::String

    # Description (or nothing)
    description::Union{String,Nothing}

    # User (and optionally group) to run the service as.  We run our agents as
    # system services with `User=` set, rather than as user services, since user
    # services only start at boot if lingering is properly enabled, which can be
    # broken by e.g. PAM configurations (see issue #118).
    user::Union{String,Nothing}
    group::Union{String,Nothing}


    #######################################################
    # Target specification
    #######################################################

    # Invocation target, e.g. "/bin/sh -c foo"
    exec_start::SystemdTarget
    exec_stop::Vector{SystemdTarget}

    # Working directroy of the target process
    working_dir::Union{String,Nothing}

    # Environment variables to set
    env::Dict{String,String}

    # Whether to restart, and if so, how often
    restart::Union{SystemdRestartConfig,Nothing}
    remain_after_exit::Union{Bool,Nothing}

    # How long to wait while the service is starting up or shutting down
    start_timeout::Union{String,Nothing}
    stop_timeout::Union{String,Nothing}

    # Maximum number of open file descriptors. Either an `Int` (sets soft and hard
    # alike) or a `"soft:hard"` string, matching systemd's `LimitNOFILE=` syntax.
    limit_nofile::Union{Int,String,Nothing}

    # What the "type" of this systemd config is (e.g. :simple, :forking, etc...)
    type::Symbol

    # Whether this target has a PIDFile to track for liveness
    pid_file::Union{String, Nothing}

    # Whether we're overriding the kill signal
    kill_signal::Union{String, Nothing}

    # How we want the kill signal to be delivered (usually either `control-group` or `mixed`)
    kill_mode::Union{String,Nothing}


    #######################################################
    # Execution Hooks
    #######################################################
    start_pre_hooks::Vector{SystemdTarget}
    start_post_hooks::Vector{SystemdTarget}
    stop_post_hooks::Vector{SystemdTarget}
end

function SystemdConfig(;exec_start::SystemdTarget,
                        exec_stop::Vector{SystemdTarget} = SystemdTarget[],
                        wanted_by = "multi-user.target",
                        description = nothing,
                        user = nothing,
                        group = nothing,
                        working_dir = nothing,
                        env::Dict{<:AbstractString,<:AbstractString} = Dict{String,String}(),
                        restart = nothing,
                        remain_after_exit = nothing,
                        start_timeout = nothing,
                        stop_timeout = nothing,
                        limit_nofile = nothing,
                        type = :simple,
                        pid_file = nothing,
                        kill_signal = nothing,
                        kill_mode = nothing,
                        start_pre_hooks::Vector{SystemdTarget} = SystemdTarget[],
                        start_post_hooks::Vector{SystemdTarget} = SystemdTarget[],
                        stop_post_hooks::Vector{SystemdTarget} = SystemdTarget[])
    nstr(x) = x === nothing ? nothing : string(x)

    return SystemdConfig(
        string(wanted_by),
        description,
        nstr(user),
        nstr(group),

        # Target specification
        exec_start,
        exec_stop,
        nstr(working_dir),
        Dict(string(k) => string(v) for (k, v) in env),
        restart,
        remain_after_exit,
        nstr(start_timeout),
        nstr(stop_timeout),
        limit_nofile,
        type,
        nstr(pid_file),
        nstr(kill_signal),
        nstr(kill_mode),

        # Execution hooks
        start_pre_hooks,
        start_post_hooks,
        stop_post_hooks,
    )
end


function Base.write(io::IO, cfg::SystemdConfig)
    # First, `Unit` keys
    println(io, "[Unit]")
    if cfg.description !== nothing
        println(io, "Description=$(cfg.description)")
    end
    if cfg.restart !== nothing
        println(io, """
        # Restart specification
        StartLimitIntervalSec=$(cfg.restart.StartLimitIntervalSec)
        StartLimitBurst=$(cfg.restart.StartLimitBurst)
        """)
    end

    # Next, `Service` keys
    println(io, "[Service]")
    println(io, "Type=$(cfg.type)")
    if cfg.user !== nothing
        println(io, "User=$(cfg.user)")
    end
    if cfg.group !== nothing
        println(io, "Group=$(cfg.group)")
    end
    println(io)

    # What hooks do we need to run before the target?
    println(io, "# Execution hooks and target")
    for hook in cfg.start_pre_hooks
        println(io, "ExecStartPre", hook)
    end
    for hook in cfg.start_post_hooks
        println(io, "ExecStartPost", hook)
    end

    # The actual target
    println(io)
    println(io, "ExecStart", cfg.exec_start)
    for cmd in cfg.exec_stop
        println(io, "ExecStop", cmd)
    end
    println(io)

    # What hooks do we need to run after the target?
    for hook in cfg.stop_post_hooks
        println(io, "ExecStopPost", hook)
    end
    println(io)

    if cfg.kill_signal !== nothing
        println(io, "KillSignal=$(cfg.kill_signal)")
    end
    if cfg.kill_mode !== nothing
        println(io, "KillMode=$(cfg.kill_mode)")
    end

    # What environment variables do we need to set?
    println(io, "# Environment variables")
    if !isempty(cfg.env)
        print(io, "Environment=")
        for (k, v) in cfg.env
            print(io, k, "=", v, " ")
        end
        println(io)
        println(io)
    end

    # Restart-related keys
    if cfg.restart !== nothing
        println(io, """
        # Restart specification
        Restart=always
        RestartSec=$(cfg.restart.RestartSec)
        """)
    end

    if cfg.start_timeout !== nothing
        println(io, "TimeoutStartSec=$(cfg.start_timeout)")
    end
    if cfg.stop_timeout !== nothing
        println(io, "TimeoutStopSec=$(cfg.stop_timeout)")
    end
    if cfg.limit_nofile !== nothing
        println(io, "LimitNOFILE=$(cfg.limit_nofile)")
    end

    if cfg.working_dir !== nothing
        println(io, "WorkingDirectory=$(cfg.working_dir)")
    end

    if cfg.pid_file !== nothing
        println(io, "PIDFile=$(cfg.pid_file)")
    end
    if cfg.remain_after_exit !== nothing
        println(io, "RemainAfterExit=$(cfg.remain_after_exit ? "yes" : "no")")
    end

    # Finally, `Install` keys
    println(io, """

    [Install]
    WantedBy=$(cfg.wanted_by)
    """)
end

# We install our services as system services (running as a particular user via
# `User=`), so unit files live in `/etc/systemd/system` and are owned by root.
const systemd_system_dir = "/etc/systemd/system"

# Helper to write out a root-owned file, using `sudo`
function sudo_write(path::String, contents::AbstractString; mode::String = "644")
    open(`/bin/bash -c "sudo tee $(path) > /dev/null"`, write=true) do io
        write(io, contents)
    end
    run(`sudo chmod $(mode) $(path)`)
end

function clear_systemd_configs()
    run(ignorestatus(`sudo systemctl stop $(systemd_unit_name_stem)\*`))

    # Remove unit files, enablement symlinks and per-instance drop-in directories
    for dir in (systemd_system_dir,
                joinpath(systemd_system_dir, "multi-user.target.wants"),
                joinpath(systemd_system_dir, "default.target.wants"))
        isdir(dir) || continue
        for f in readdir(dir; join=true)
            if startswith(basename(f), systemd_unit_name_stem)
                run(`sudo rm -rf $(f)`)
            end
        end
    end
    run(`sudo systemctl daemon-reload`)

    # Also clean up legacy user services, from back when we launched our agents
    # via `systemctl --user` (see issue #118)
    run(ignorestatus(`systemctl --user stop $(systemd_unit_name_stem)\*`))
    systemd_user_dir = expanduser("~/.config/systemd/user")
    for dir in (systemd_user_dir, joinpath(systemd_user_dir, "default.target.wants"))
        isdir(dir) || continue
        for f in readdir(dir; join=true)
            if startswith(basename(f), systemd_unit_name_stem)
                rm(f)
            end
        end
    end
    run(ignorestatus(`systemctl --user daemon-reload`))
end

function launch_systemd_services(brgs::Vector{BuildkiteRunnerGroup})
    agent_idx = 0
    # Sort `brgs` by name, for consistent ordering
    brgs = sort(brgs, by=brg -> brg.name)
    for brg in brgs
        for _ in 1:brg.num_agents
            unit_name = systemd_unit_name(brg, agent_idx)
            @info("Launching $(unit_name)")
            run(`sudo systemctl enable $(unit_name)`)
            run(`sudo systemctl start $(unit_name)`)
            agent_idx += 1
        end
    end
end

function stop_systemd_services(brgs::Vector{BuildkiteRunnerGroup})
    agent_idx = 0
    brgs = sort(brgs, by=brg -> brg.name)
    for brg in brgs
        for _ in 1:brg.num_agents
            unit_name = systemd_unit_name(brg, agent_idx)
            run(`sudo systemctl stop $(unit_name)`)
            run(`sudo systemctl disable $(unit_name)`)
            agent_idx += 1
        end
    end
end

function systemd_unit_name(brg::BuildkiteRunnerGroup, agent_idx::Int)
    return string(systemd_unit_name_stem, brg.name, "@", get_short_hostname(), ".", agent_idx)
end

# This will call out to a `gnerate_systemd_script(io::IO, brg; kwargs...)` method,
# so make sure you define that elsewhere
function generate_systemd_script(brg::BuildkiteRunnerGroup; kwargs...)
    io = IOBuffer()
    generate_systemd_script(io, brg; kwargs...)

    # The unit file may contain secrets (e.g. the buildkite agent token in an
    # `Environment=` line), so make it readable by root only.
    unit_path = joinpath(systemd_system_dir, "$(systemd_unit_name_stem)$(brg.name)@.service")
    sudo_write(unit_path, String(take!(io)); mode="600")

    # Inform systemctl that some files on disk may have changed
    run(`sudo systemctl daemon-reload`)
end
