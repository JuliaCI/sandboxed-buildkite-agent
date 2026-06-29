function get_short_hostname()
    return first(split(gethostname(), "."))
end

function repo_path(parts...)
    return joinpath(REPO_ROOT, parts...)
end

function host_os()
    Sys.islinux() && return :linux
    Sys.isapple() && return :macos
    return Symbol(os(HostPlatform()))
end

function find_python3()
    for name in ("python3", "python")
        if Sys.which(name) !== nothing
            version = readchomp(`$(name) --version`)
            m = match(r"Python (?<version_number>\d+\.\d+\.\d+)", version)
            if m !== nothing
                if parse(VersionNumber, m[:version_number]) >= v"3"
                    return Sys.which(name)
                end
            end
        end
    end
    return nothing
end

function safe_path_component(value, fallback::String)
    value isa AbstractString || return fallback
    isempty(value) && return fallback
    occursin(r"^[A-Za-z0-9_.-]+$", value) || return fallback
    return value
end

#
# Secret permissions
#

"""
    check_secret_file_permissions(path)

Ensure that one secret file is not world-readable, writable, or executable.
"""
function check_secret_file_permissions(path::AbstractString)
    mode = stat(path).mode
    if mode & 0o7 != 0
        error("unsafe permissions on secret $(path); suggest running chmod o-rwx $(path)")
    end
    return nothing
end

"""
    check_secret_permissions(secrets_dir = repo_path("secrets"))

Ensure that secrets are not world-readable.
"""
function check_secret_permissions(secrets_dir::AbstractString = repo_path("secrets"))
    for (root, dirs, files) in walkdir(secrets_dir)
        for f in vcat(dirs, files)
            check_secret_file_permissions(joinpath(root, f))
        end
    end
    return nothing
end
