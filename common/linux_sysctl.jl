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
