# Host system preflight: coredump pattern, sysctl params, and the AMD "zen" rr
# workaround.  The setup helpers may tweak the host, often via sudo, and should
# only run from `bk enable`; the check helpers are read-only for scheduler start.

runtime_setup_error(message::AbstractString) =
    error("$(message). Run `bk enable` to set up this host before starting the scheduler.")

#
# Coredumps
#

function get_coredump_pattern()
    @static if Sys.islinux()
        return strip(String(read("/proc/sys/kernel/core_pattern")))
    elseif Sys.isapple()
        return strip(String(read(`sysctl -n kern.corefile`)))
    else
        error("Not implemented on $(triplet(HostPlatform()))")
    end
end

function default_core_pattern()
    @static if Sys.islinux()
        return "%e-pid%p-sig%s-ts%t.core"
    elseif Sys.isapple()
        return "%N-pid%P.core"
    else
        error("Not implemented on $(triplet(HostPlatform()))")
    end
end

function set_coredump_pattern(pattern::AbstractString)
    @static if Sys.islinux()
        run(pipeline(
            `echo "$(pattern)"`,
            pipeline(`sudo tee /proc/sys/kernel/core_pattern`, devnull),
        ))

        # Ensure it gets set by default on next boot
        if isdir("/etc/sysctl.d")
            run(pipeline(
                `echo "kernel.core_pattern=$(pattern)"`,
                pipeline(`sudo tee /etc/sysctl.d/50-coredump.conf`, devnull),
            ))
        end
    elseif Sys.isapple()
        run(`sudo sysctl -w "kern.corefile=$(pattern)"`)
    else
        error("Not implemented on $(triplet(HostPlatform()))")
    end
end

const MACOS_COREFILE_LAUNCHD_LABEL = "org.julialang.buildkite.corefile"
const MACOS_CORE_CLEANUP_LAUNCHD_LABEL = "org.julialang.buildkite.core-cleanup"
const MACOS_CORE_CLEANUP_INTERVAL_SECONDS = 60 * 60
const MACOS_CORE_CLEANUP_MIN_AGE_MINUTES = 60

function macos_corefile_launchd_plist_path()
    return "/Library/LaunchDaemons/$(MACOS_COREFILE_LAUNCHD_LABEL).plist"
end

function generate_macos_corefile_launchd_plist(io::IO,
                                               pattern::AbstractString=default_core_pattern())
    launchd_plist(io;
        label=MACOS_COREFILE_LAUNCHD_LABEL,
        program_args=["/usr/sbin/sysctl", "-w", "kern.corefile=$(strip(pattern))"],
    )
    return nothing
end

function install_macos_corefile_launchd(pattern::AbstractString=default_core_pattern())
    mktempdir() do dir
        config_path = joinpath(dir, "corefile.plist")
        open(config_path, write=true) do io
            generate_macos_corefile_launchd_plist(io, pattern)
        end
        run(`sudo install -o root -g wheel -m 0644 $(config_path) $(macos_corefile_launchd_plist_path())`)
    end
    return nothing
end

function check_macos_corefile_launchd(pattern::AbstractString=default_core_pattern())
    plist_path = macos_corefile_launchd_plist_path()
    isfile(plist_path) || runtime_setup_error("macOS coredump launchd service is not installed")
    expected = "<string>kern.corefile=$(strip(pattern))</string>"
    occursin(expected, read(plist_path, String)) ||
        runtime_setup_error("macOS coredump launchd service has the wrong corefile pattern")
    return nothing
end

function macos_core_cleanup_launchd_plist_path()
    return "/Library/LaunchDaemons/$(MACOS_CORE_CLEANUP_LAUNCHD_LABEL).plist"
end

function generate_macos_core_cleanup_launchd_plist(io::IO)
    launchd_plist(io;
        label=MACOS_CORE_CLEANUP_LAUNCHD_LABEL,
        program_args=[
            "/usr/bin/find", "/cores", "-type", "f", "-name", "core.*",
            "-mmin", "+$(MACOS_CORE_CLEANUP_MIN_AGE_MINUTES)", "-delete",
        ],
        start_interval=MACOS_CORE_CLEANUP_INTERVAL_SECONDS,
    )
    return nothing
end


function install_macos_core_cleanup_launchd()
    plist_path = macos_core_cleanup_launchd_plist_path()
    mktempdir() do dir
        config_path = joinpath(dir, "core-cleanup.plist")
        open(config_path, write=true) do io
            generate_macos_core_cleanup_launchd_plist(io)
        end
        run(`sudo install -o root -g wheel -m 0644 $(config_path) $(plist_path)`)
    end

    run(pipeline(ignorestatus(
        `sudo launchctl bootout system/$(MACOS_CORE_CLEANUP_LAUNCHD_LABEL)`);
        stdout=devnull, stderr=devnull))
    run(`sudo launchctl bootstrap system $(plist_path)`)
    return nothing
end

function check_macos_core_cleanup_launchd()
    plist_path = macos_core_cleanup_launchd_plist_path()
    isfile(plist_path) || runtime_setup_error("macOS coredump cleanup service is not installed")
    plist = read(plist_path, String)
    occursin("<string>core.*</string>", plist) ||
        runtime_setup_error("macOS coredump cleanup service has the wrong file pattern")
    success(`launchctl print system/$(MACOS_CORE_CLEANUP_LAUNCHD_LABEL)`) ||
        runtime_setup_error("macOS coredump cleanup service is not loaded")
    return nothing
end

function ensure_coredump_pattern(pattern::String = default_core_pattern())
    pattern = strip(pattern)
    if get_coredump_pattern() != pattern
        @info("Setting coredump pattern, may ask for sudo password...")
        # Set coredump pattern immediately
        set_coredump_pattern(pattern)

        # Ensure that the change was effective
        if get_coredump_pattern() != pattern
            error("Unable to set coredump pattern!")
        end
    end
end

function check_coredump_pattern(pattern::String = default_core_pattern())
    pattern = strip(pattern)
    current = get_coredump_pattern()
    current == pattern ||
        runtime_setup_error("Coredump pattern is '$(current)', expected '$(pattern)'")
    return nothing
end

function ensure_apport_disabled()
    # Apport messes with our core dump naming, disable it.
    if Sys.which("systemctl") !== nothing
        apport_active = success(`systemctl is-active --quiet apport`)
        apport_enabled = success(`systemctl is-enabled --quiet apport`)
        if apport_active || apport_enabled
            @info("Disabling apport, may ask for sudo password...")
        end

        if apport_active
            run(`sudo systemctl stop apport`)
        end
        if apport_enabled
            run(`sudo systemctl disable apport`)
        end
    end
end

function check_apport_disabled()
    Sys.which("systemctl") === nothing && return nothing
    apport_active = success(`systemctl is-active --quiet apport`)
    apport_enabled = success(`systemctl is-enabled --quiet apport`)
    if apport_active || apport_enabled
        runtime_setup_error("Apport is active or enabled")
    end
    return nothing
end

function setup_coredumps()
    ensure_coredump_pattern()

    @static if Sys.islinux()
        ensure_apport_disabled()
    elseif Sys.isapple()
        install_macos_corefile_launchd()
        install_macos_core_cleanup_launchd()
    end
end

function check_coredumps()
    check_coredump_pattern()
    @static if Sys.islinux()
        check_apport_disabled()
    elseif Sys.isapple()
        check_macos_corefile_launchd()
        check_macos_core_cleanup_launchd()
    end
    return nothing
end

#
# sysctl
#

function sysctl_param_value(name)
    vals = split(readchomp(`sysctl $(name)`), "=")
    length(vals) < 2 && return nothing
    return strip(vals[2])
end

function setup_sysctl_param(name, val)
    if sysctl_param_value(name) != strip(val)
        @info("Adding sysctl mapping", name, val)
        if isdir("/etc/sysctl.d")
            run(pipeline(
                `echo "$(name) = $(val)"`,
                pipeline(`sudo tee /etc/sysctl.d/99-$(replace(name, "." => "_")).conf`, devnull),
            ))
            run(`sudo sysctl --system`)
        else
            error("Don't know how to do that on this system, do it manually!")
        end
    end
end

function check_sysctl_param(name, val)
    current = sysctl_param_value(name)
    current == strip(val) ||
        runtime_setup_error("sysctl $(name) is '$(something(current, "missing"))', expected '$(val)'")
    return nothing
end

function sysctl_param_int(name)
    value = sysctl_param_value(name)
    value === nothing && return nothing
    return tryparse(Int, value)
end

# perf_event_paranoid is a ceiling, not an exact value: lower is strictly more
# permissive, so any value at or below the required maximum is fine.  Checking
# `<=` (rather than `==`) accepts hosts tuned for profiling (e.g. a
# `sysctl.d/*.conf` pinning it to 0) instead of rejecting them.
function check_sysctl_param_max(name, max_val::Integer)
    current = sysctl_param_int(name)
    current !== nothing && current <= max_val ||
        runtime_setup_error("sysctl $(name) is '$(something(sysctl_param_value(name), "missing"))', expected <= $(max_val)")
    return nothing
end

# Only tighten the value when it is missing or too high; never overwrite a
# host that is already more permissive than we require (writing a numbered
# drop-in that a later-sorting file overrides would fail the check anyway).
function setup_sysctl_param_max(name, max_val::Integer)
    current = sysctl_param_int(name)
    (current === nothing || current > max_val) && setup_sysctl_param(name, string(max_val))
    return nothing
end

function setup_sysctl_params()
    setup_sysctl_param_max("kernel.perf_event_paranoid", 1)
end

function check_sysctl_params()
    check_sysctl_param_max("kernel.perf_event_paranoid", 1)
end

#
# AMD "zen" rr workaround
#

function is_amd_cpu()
    # Nothing to do if we're not on AMD
    return !isempty(filter(l -> match(r"vendor_id\s+:\s+AuthenticAMD", l) !== nothing, split(String(read("/proc/cpuinfo")), "\n")))
end

function setup_zen_workaround()
    is_amd_cpu() || return nothing

    # If we don't already have an `rr-workaround` service, generate it:
    rr_systemd_script_path = "/etc/systemd/system/zen_workaround.service"
    if !isfile(rr_systemd_script_path)
        @info("Writing out and starting up rr workaround service, may ask for sudo password...")
        workaround_script = joinpath(@get_scratch!("agent-cache"), "zen_workaround.py")
        if !isfile(workaround_script)
            Downloads.download("https://github.com/rr-debugger/rr/raw/master/scripts/zen_workaround.py", workaround_script)
        end

        # We need python3 to run this
        python3 = find_python3()
        if python3 === nothing
            error("Must install python 3 to run zen_workaround.py!")
        end

        # The `+` prefix runs ExecStart with full privileges.
        sudo_write(rr_systemd_script_path, """
            [Unit]
            Description=rr workaround script

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            WorkingDirectory=$(dirname(workaround_script))
            ExecStart=+$(python3) $(workaround_script)

            [Install]
            WantedBy=multi-user.target
            """)
        run(`sudo systemctl daemon-reload`)
    end

    if !success(`systemctl status zen_workaround`)
        run(`sudo systemctl enable zen_workaround`)
        run(`sudo systemctl start zen_workaround`)
    end
    return nothing
end

function check_zen_workaround()
    is_amd_cpu() || return nothing
    rr_systemd_script_path = "/etc/systemd/system/zen_workaround.service"
    isfile(rr_systemd_script_path) ||
        runtime_setup_error("AMD rr workaround service is not installed")
    success(`systemctl status zen_workaround`) ||
        runtime_setup_error("AMD rr workaround service is not running")
    return nothing
end
