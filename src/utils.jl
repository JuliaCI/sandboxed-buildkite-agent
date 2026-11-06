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

function path_within_root(path::AbstractString, root::AbstractString)
    path_abs = normpath(abspath(path))
    root_abs = normpath(abspath(root))
    root_abs == "/" && return startswith(path_abs, "/")
    return path_abs == root_abs || startswith(path_abs, string(root_abs, "/"))
end

#
# Assignment deadlines
#

struct AssignmentTimeoutError <: Exception
    message::String
end

Base.showerror(io::IO, err::AssignmentTimeoutError) = print(io, err.message)

function check_assignment_deadline!(deadline::Union{Nothing,Float64},
                                    context::AbstractString; now_fn::Function=time)
    deadline === nothing && return nothing
    remaining = deadline - now_fn()
    remaining > 0 && return nothing
    throw(AssignmentTimeoutError("Timed out while $(context)"))
end

function sleep_until_deadline(seconds::Real, deadline::Union{Nothing,Float64},
                              context::AbstractString;
                              sleep_fn::Function=sleep, now_fn::Function=time)
    if deadline === nothing
        sleep_fn(seconds)
        return nothing
    end
    remaining = deadline - now_fn()
    remaining > 0 || check_assignment_deadline!(deadline, context; now_fn)
    sleep_fn(min(Float64(seconds), remaining))
    return nothing
end

# Start `cmd` (a `Cmd` or pipeline) whose environment or arguments hold a
# credential. Julia's spawn and process errors print the whole command, so a
# failure is reported as `what` and the error code only.
function run_with_secret(cmd, what::AbstractString)
    failure = try
        return run(cmd; wait=false)
    catch err
        err isa Base.IOError ? string(Base.uverrorname(err.code)) : string(typeof(err))
    end
    error("Could not start ", what, ": ", failure)
end

# The output of `cmd`, whose arguments hold a credential; see `run_with_secret`.
function read_with_secret(cmd, what::AbstractString)
    failure = try
        return read(cmd, String)
    catch err
        if err isa ProcessFailedException
            proc = first(err.procs)
            string("exit code ", proc.exitcode, ", signal ", proc.termsignal)
        elseif err isa Base.IOError
            string(Base.uverrorname(err.code))
        else
            string(typeof(err))
        end
    end
    error(what, " failed: ", failure)
end

# Wait for a job process, enforcing the assignment deadline: past the deadline
# the process gets SIGTERM, `kill_grace` seconds to shut down, then SIGKILL.
function wait_process_exit(proc::Base.Process, deadline::Union{Nothing,Float64},
                           context::AbstractString;
                           poll_interval::Real=1.0,
                           kill_grace::Real=300.0)
    while process_running(proc)
        if deadline !== nothing && deadline - time() <= 0
            kill(proc, Base.SIGTERM)
            kill_deadline = time() + Float64(kill_grace)
            while process_running(proc) && time() < kill_deadline
                sleep(min(Float64(poll_interval), max(kill_deadline - time(), 0.0)))
            end
            process_running(proc) && kill(proc, Base.SIGKILL)
            try
                wait(proc)
            catch
            end
            check_assignment_deadline!(deadline, context)
        end
        sleep_until_deadline(poll_interval, deadline, context)
    end
    wait(proc)
    return proc.exitcode
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
