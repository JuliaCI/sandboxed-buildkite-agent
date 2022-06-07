include("buildkite_config.jl")
include("security.jl")

function get_short_hostname()
    return first(split(gethostname(), "."))
end

if Sys.islinux()
    include("linux_systemd_config.jl")
    include("linux_coredump_config.jl")
end
if Sys.isapple()
    include("mac_launchctl_config.jl")
    include("mac_seatbelt_config.jl")
end
