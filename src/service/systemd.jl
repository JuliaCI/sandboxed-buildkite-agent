# systemd integration: render the scheduler unit and drive systemctl.

# We install our services as system services (running as a particular user via
# `User=`, rather than as user services, since user services only start at boot
# if lingering is properly enabled, which can be broken by e.g. PAM
# configurations; see issue #118).  Unit files live in `/etc/systemd/system`
# and are owned by root.
const systemd_system_dir = "/etc/systemd/system"

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

function scheduler_systemd_unit_path()
    return joinpath(systemd_system_dir, "$(scheduler_systemd_unit_name()).service")
end

function scheduler_systemd_service_installed(; unit_path::String=scheduler_systemd_unit_path())
    return isfile(unit_path)
end

function scheduler_systemd_service_running()
    return success(run(ignorestatus(`systemctl is-active --quiet $(scheduler_systemd_unit_name())`)))
end

function scheduler_systemd_active_state(unit_name::AbstractString=scheduler_systemd_unit_name())
    output = read(ignorestatus(`systemctl show $(unit_name) -P ActiveState`), String)
    return strip(output)
end

function wait_for_scheduler_systemd_stop(unit_name::AbstractString=scheduler_systemd_unit_name();
                                        timeout::Real=10.0)
    deadline = time() + timeout
    while time() < deadline
        state = scheduler_systemd_active_state(unit_name)
        state in ("inactive", "failed", "") && return true
        sleep(0.25)
    end
    return false
end

function generate_scheduler_systemd_script(io::IO, config_file::String=abspath("config.toml");
                                           host::Symbol=host_os())
    _, brgs = read_config(config_file; host)
    backend_names = Set(brg.backend for brg in brgs)
    has_linux_sandbox = BACKEND_LINUX_SANDBOX in backend_names
    has_kvm = BACKEND_KVM in backend_names

    # Use the absolute path of the `julia` that ran the installer; the `+lts`
    # shebang on `bin/bk` ensures that is the LTS binary.  Baking in the binary
    # (rather than invoking `bin/bk` and relying on its shebang) mirrors the
    # launchd backend and frees the service from depending on juliaup or a
    # particular PATH at runtime, neither of which a system service inherits.
    julia = join(String.(Base.julia_cmd().exec), " ")
    description = has_kvm ? "Sandboxed Buildkite scheduler (requires libvirt qemu:///system)" :
                            "Sandboxed Buildkite scheduler"

    print(io, """
        [Unit]
        Description=$(description)
        After=network-online.target
        Wants=network-online.target
        # Stop restarting if we fail 10 times within two minutes.
        StartLimitIntervalSec=120
        StartLimitBurst=10

        [Service]
        Type=simple
        User=$(ENV["USER"])
        WorkingDirectory=$(REPO_ROOT)
        # Instantiate the project in this `julia`'s depot before launching.  A
        # system service does not inherit the operator's shell environment, so it
        # may use a different depot than the one set up at install time; this
        # makes the service self-contained, working with any depot as long as the
        # repo's Manifest is present.  Resolves to a fast no-op once the depot is
        # instantiated; a cold run precompiles the whole dependency tree, hence
        # the generous start timeout below.
        ExecStartPre=/bin/bash -c "$(julia) --project=$(REPO_ROOT) -e 'using Pkg; Pkg.instantiate()'"
        """)
    if has_kvm
        println(io, "ExecStartPre=/bin/bash -c \"virsh -c qemu:///system list --name >/dev/null\"")
    end
    print(io, """
        ExecStart=$(julia) --project=$(REPO_ROOT) $(repo_path("bin", "bk")) --config=$(abspath(config_file)) scheduler
        Restart=on-failure
        RestartSec=1
        TimeoutStartSec=30min
        TimeoutStopSec=5min
        KillMode=mixed
        RuntimeDirectory=$(scheduler_systemd_unit_name())
        """)
    if has_linux_sandbox
        println(io, "Delegate=cpuset")
    end
    print(io, """

        [Install]
        WantedBy=multi-user.target
        """)
end

function generate_scheduler_systemd_script(config_file::String=abspath("config.toml"); kwargs...)
    io = IOBuffer()
    generate_scheduler_systemd_script(io, config_file; kwargs...)
    unit_path = scheduler_systemd_unit_path()
    scheduler_systemd_service_installed(; unit_path) &&
        error("scheduler systemd service is already enabled; run `bk disable` first")
    @info("Installing scheduler systemd service", unit=scheduler_systemd_unit_name())
    sudo_write(unit_path, String(take!(io)))
    run(`sudo systemctl daemon-reload`)
end

function enable_scheduler_systemd_service()
    unit_name = scheduler_systemd_unit_name()
    # Enable boot start only; the operator starts it explicitly with `bk start`.
    @info("Enabling $(unit_name)")
    run(`sudo systemctl enable $(unit_name)`)
    return nothing
end

function start_scheduler_systemd_service()
    unit_name = scheduler_systemd_unit_name()
    @info("Starting $(unit_name)")
    run(`sudo systemctl start $(unit_name)`)
end

function stop_scheduler_systemd_service()
    unit_name = scheduler_systemd_unit_name()
    if !scheduler_systemd_service_installed() && !scheduler_systemd_service_running()
        @info("Scheduler systemd service is not installed", unit=unit_name)
        return nothing
    end
    if scheduler_systemd_service_running()
        @info("Killing $(unit_name)")
        run(ignorestatus(`sudo systemctl kill --signal=SIGKILL $(unit_name)`))
    end
    run(ignorestatus(`sudo systemctl stop --no-block $(unit_name)`))
    wait_for_scheduler_systemd_stop(unit_name; timeout=5.0)
    run(ignorestatus(`sudo systemctl reset-failed $(unit_name)`))
    return nothing
end

function uninstall_scheduler_systemd_service()
    unit_name = scheduler_systemd_unit_name()
    unit_path = scheduler_systemd_unit_path()
    if !scheduler_systemd_service_installed(; unit_path)
        @info("Scheduler systemd service is not installed", unit=unit_name)
        return nothing
    end
    stop_scheduler_systemd_service()
    run(ignorestatus(`sudo systemctl disable $(unit_name)`))
    run(ignorestatus(`sudo rm -f $(unit_path)`))
    run(`sudo systemctl daemon-reload`)
    return nothing
end
