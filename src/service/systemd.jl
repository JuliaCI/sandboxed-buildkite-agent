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
    Base.write(io, hook_name, "=")
    if :IgnoreExitCode in t.flags
        Base.write(io, "-")
    end
    if :Sudo in t.flags
        Base.write(io, "+")
    end
    Base.write(io, t.command, "\n")
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

    # Controllers delegated to this service's cgroup subtree.
    delegate::Union{String,Nothing}


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
                        delegate = nothing,
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
        nstr(delegate),

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
    if cfg.delegate !== nothing
        println(io, "Delegate=$(cfg.delegate)")
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
const systemd_unit_name_stem = "buildkite-sandbox-"

# Helper to write out a root-owned file, using `sudo`
function sudo_write(path::String, contents::AbstractString; mode::String = "644")
    open(`/bin/bash -c "sudo tee $(path) > /dev/null"`, write=true) do io
        Base.write(io, contents)
    end
    run(`sudo chmod $(mode) $(path)`)
end

function scheduler_systemd_unit_name()
    return "sandboxed-buildkite-agent"
end

function generate_scheduler_systemd_script(io::IO, config_file::String=abspath("config.toml");
                                           dry_run::Bool=false,
                                           host::Symbol=host_os())
    brgs = read_configs(config_file; host)
    backend_names = Set(brg.backend for brg in brgs)
    has_linux_sandbox = BACKEND_LINUX_SANDBOX in backend_names
    has_kvm = BACKEND_KVM in backend_names

    args = String[
        repo_path("bin", "bk"),
        "scheduler",
        "--config=$(abspath(config_file))",
    ]
    dry_run && push!(args, "--dry-run")

    # Instantiate the project in whatever depot this service's `julia` resolves
    # to.  A system service does not inherit the operator's shell environment, so
    # it may use a different depot than the one set up at install time; this makes
    # the service self-contained, working with any depot as long as `julia` is on
    # PATH and the repo's Manifest is present.  Resolves to a fast no-op once the
    # depot is instantiated; a cold run precompiles the whole dependency tree,
    # hence the generous start timeout below.
    start_pre_hooks = SystemdTarget[
        SystemdBashTarget("julia --project=$(REPO_ROOT) -e 'using Pkg; Pkg.instantiate()'"),
    ]
    if has_kvm
        push!(start_pre_hooks,
            SystemdBashTarget("virsh -c qemu:///system list --name >/dev/null"))
    end

    systemd_config = SystemdConfig(;
        description=has_kvm ? "Sandboxed Buildkite scheduler (requires libvirt qemu:///system)" :
                              "Sandboxed Buildkite scheduler",
        user=ENV["USER"],
        working_dir=REPO_ROOT,
        restart=SystemdRestartConfig(),
        # Generous, because a cold first-start instantiate precompiles all deps.
        start_timeout="30min",
        stop_timeout="5min",
        kill_mode="mixed",
        delegate=has_linux_sandbox ? "cpuset" : nothing,
        start_pre_hooks,
        exec_start=SystemdTarget(join(args, " ")),
    )
    Base.write(io, systemd_config)
end

function generate_scheduler_systemd_script(config_file::String=abspath("config.toml"); kwargs...)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, config_file; kwargs...)
    unit_path = joinpath(systemd_system_dir, "$(scheduler_systemd_unit_name()).service")
    sudo_write(unit_path, String(take!(io)))
    run(`sudo systemctl daemon-reload`)
end

function launch_scheduler_systemd_service()
    unit_name = scheduler_systemd_unit_name()
    @info("Launching $(unit_name)")
    run(`sudo systemctl enable $(unit_name)`)
    run(`sudo systemctl start $(unit_name)`)
end

function uninstall_scheduler_systemd_service()
    unit_name = scheduler_systemd_unit_name()
    unit_path = joinpath(systemd_system_dir, "$(unit_name).service")
    run(ignorestatus(`sudo systemctl stop $(unit_name)`))
    run(ignorestatus(`sudo systemctl disable $(unit_name)`))
    run(ignorestatus(`sudo rm -f $(unit_path)`))
    run(`sudo systemctl daemon-reload`)
    return nothing
end

function systemd_unit_name(brg::BuildkiteRunnerGroup, agent_idx::Int)
    return string(systemd_unit_name_stem, brg.name, "@", get_short_hostname(), ".", agent_idx)
end
