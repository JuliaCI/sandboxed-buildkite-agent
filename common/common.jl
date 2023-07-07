using LazyArtifacts

include("buildkite_config.jl")
include("security.jl")
include("coredump_config.jl")

function get_short_hostname()
    return first(split(gethostname(), "."))
end

if Sys.islinux()
    include("linux_systemd_config.jl")
    include("linux_sysctl.jl")
end
if Sys.isapple()
    include("mac_launchctl_config.jl")
    include("mac_seatbelt_config.jl")
end
