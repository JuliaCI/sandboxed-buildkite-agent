# Host system preflight: coredump pattern, sysctl params, and the AMD "zen" rr
# workaround.  These tweak the host (often via sudo) and run from each backend's
# check_config.

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

        # Ensure it gets set by default on next boot
        label = "org.julialang.buildkite.corefile"
        config = LaunchctlConfig(
            label,
            [Sys.which("sysctl"), "-w", "kern.corefile=$(pattern)"]
        )
        mktempdir() do dir
            open(joinpath(dir, "config"); write=true) do io
                write(io, config)
            end
            plist_path = "/Library/LaunchDaemons/$(label).plist"
            run(`sudo mv $(joinpath(dir, "config")) $(plist_path)`)
            run(`sudo chown root:wheel $(plist_path)`)
        end
    else
        error("Not implemented on $(triplet(HostPlatform()))")
    end
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

function setup_coredumps()
    ensure_coredump_pattern()

    @static if Sys.islinux()
        ensure_apport_disabled()
    end
end

#
# sysctl
#

function check_sysctl_param(name, val)
    vals = split(readchomp(`sysctl $(name)`), "=")
    if length(vals) < 2 || strip(vals[2]) != strip(val)
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

function check_sysctl_params()
    check_sysctl_param("kernel.perf_event_paranoid", "1")
end

#
# AMD "zen" rr workaround
#

function check_zen_workaround()
    # Nothing to do if we're not on AMD
    if isempty(filter(l -> match(r"vendor_id\s+:\s+AuthenticAMD", l) !== nothing, split(String(read("/proc/cpuinfo")), "\n")))
        return
    end

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

        systemd_config = SystemdConfig(;
            description="rr workaround script",
            working_dir=dirname(workaround_script),
            type=:oneshot,
            remain_after_exit=true,
            exec_start=SystemdTarget("$(python3) $(workaround_script)", [:Sudo]),
        )
        open(`/bin/bash -c "sudo tee $(rr_systemd_script_path) > /dev/null"`, write=true) do io
            write(io, systemd_config)
        end
        run(`sudo systemctl daemon-reload`)
    end

    if !success(`systemctl status zen_workaround`)
        run(`sudo systemctl enable zen_workaround`)
        run(`sudo systemctl start zen_workaround`)
    end
end
