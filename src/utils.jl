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

function parse_cpu_list(text::AbstractString)
    cpus = Int[]
    for part in split(strip(text), ",")
        isempty(part) && continue
        if occursin("-", part)
            first_cpu, last_cpu = parse.(Int, split(part, "-"; limit=2))
            append!(cpus, first_cpu:last_cpu)
        else
            push!(cpus, parse(Int, part))
        end
    end
    return cpus
end

function cpu_topology_permutation()
    cpu_dir = "/sys/devices/system/cpu"
    if !isdir(cpu_dir)
        return collect(0:Sys.CPU_THREADS-1)
    end

    cores = filter(d -> match(r"^cpu\d+$", d) !== nothing, readdir(cpu_dir))
    cores = sort([parse(Int, c[4:end]) for c in cores])

    cpus = Int[]
    for core_idx in cores
        core_idx in cpus && continue
        siblings_path = joinpath(cpu_dir, "cpu$(core_idx)", "topology", "thread_siblings_list")
        if isfile(siblings_path)
            append!(cpus, parse_cpu_list(read(siblings_path, String)))
        else
            push!(cpus, core_idx)
        end
    end
    return cpus
end

function condense_cpu_selection(cpus::Vector{Int})
    cpus = sort(cpus)
    ret = String[]
    idx = 1
    while idx <= length(cpus)
        start_idx = idx
        while idx < length(cpus) && cpus[idx+1] - cpus[idx] == 1
            idx += 1
        end
        if idx > start_idx
            push!(ret, "$(cpus[start_idx])-$(cpus[idx])")
            idx += 1
        else
            push!(ret, "$(cpus[start_idx])")
            idx += 1
        end
    end
    return join(ret, ",")
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
