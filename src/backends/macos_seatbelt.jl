## This file contains code to generate macOS Seatbelt Seatbelt

abstract type SeatbeltResource; end
SeatbeltResource(res::SeatbeltResource) = res

struct SeatbeltPath <: SeatbeltResource
    path::String
end
SeatbeltResource(path::AbstractString) = SeatbeltPath(String(path))
Base.print(io::IO, res::SeatbeltPath) = print(io, "(path \"$(res.path)\")")

struct SeatbeltSubpath <: SeatbeltResource
    path::String
end
Base.print(io::IO, res::SeatbeltSubpath) = print(io, "(subpath \"$(res.path)\")")

struct SeatbeltRegex <: SeatbeltResource
    path::String
end
SeatbeltResource(path::Regex) = SeatbeltRegex(path.pattern)
Base.print(io::IO, res::SeatbeltRegex) = print(io, "(regex #\"$(res.path)\")")

abstract type SeatbeltRule; end
struct SeatbeltGlobalRule <: SeatbeltRule
    name::String
    mode::String
end
SeatbeltRule(name::AbstractString, mode::AbstractString = "allow") = SeatbeltGlobalRule(String(name), String(mode))
Base.print(io::IO, rule::SeatbeltGlobalRule) = print(io, "($(rule.mode) $(rule.name))")

struct SeatbeltScopedRule <: SeatbeltRule
    name::String
    resources::Vector{<:SeatbeltResource}
    mode::String
end
SeatbeltRule(name::AbstractString, scopes::Vector{<:SeatbeltResource}, mode::AbstractString = "allow") = SeatbeltScopedRule(String(name), scopes, String(mode))
SeatbeltRule(name::AbstractString, scopes::Vector, mode::AbstractString = "allow") = SeatbeltRule(String(name), SeatbeltResource.(scopes), String(mode))
function Base.print(io::IO, rule::SeatbeltScopedRule)
    println(io, "($(rule.mode) $(rule.name)")
    for resource in rule.resources
        println(io, "    $(resource)")
    end
    println(io, ")")
end


struct MacOSSeatbeltConfig
    # Usually something like `"bsd.sb"`
    parent_config::Union{Nothing,String}

    # List of actions that should be allowed
    rules::Vector{<:SeatbeltRule}

    function MacOSSeatbeltConfig(;rules::Vector{<:SeatbeltRule} = SeatbeltRule[],
                                 parent_config::Union{Nothing,String} = "bsd.sb",
                                )
        return new(parent_config, rules)
    end
end

function generate_seatbelt_config(io::IO, config::MacOSSeatbeltConfig)
    # First, print out the header:
    print(io, """
    (version 1)
    (deny default)
    """)

    # Inherit from something like `bsd.sb`
    if config.parent_config !== nothing
        println(io, "(import \"$(config.parent_config)\")")
    end

    # Add all rules that are not path-based
    for rule in config.rules
        println(io, rule)
    end
end

function with_seatbelt(f::Function, seatbelt_generator::Function, args...; kwargs...)
    mktempdir() do dir
        sb_path = joinpath(dir, "macos_seatbelt.sb")
        open(sb_path, write=true) do io
            seatbelt_generator(io, args...; kwargs...)
        end
        f(sb_path)
    end
end

function dirname_chain(path::AbstractString)
    dirnames = AbstractString[]
    path = realpath(path)
    while dirname(path) != path
        path = dirname(path)
        push!(dirnames, path)
    end
    return dirnames
end


# `readable` are further directories the job may read but not write; they must
# not lie within any of the `file*` paths below.
function generate_buildkite_seatbelt_config(io::IO, workspaces::Vector{String}, temp_dir::String;
                                            readable::Vector{String}=String[])
    xnu_version = VersionNumber(String(read(`uname -r`)))

    # We'll generate here a MacOSSeatbeltConfig that allows us to run builds within a build prefix,
    # but not write to the rest of the system, nor read sensitive files
    config = MacOSSeatbeltConfig(;
        rules = vcat(
            # First, global rules that are not scoped in any way
            SeatbeltRule.([
                # These are foundational capabilities, and should potentially
                # be enabled for _all_ sandboxed processes?
                "process-fork", "process-info*", "process-codesigning-status*",
                "signal", "mach-lookup", "sysctl-read",

                # Running Julia's test suite requires IPC/shared memory mechanisms as well
                "ipc-posix-sem", "ipc-sysv-sem", "ipc-sysv-shm", "ipc-posix-shm",

                # Calling `getcwd()` on a non-existant file path returns `EACCES` instead of `ENOENT`
                # unless we give unrestricted `fcntl()` permissions.
                "system-fsctl",

                # The REPL tests require creating pseudo-tty's
                "pseudo-tty",

                # For some reason, `access()` requires `process-exec` globally.
                # I don't know why this is, and Apple's own scripts have a giant shrug
                # in `/usr/share/sandbox/com.apple.smbd.sb` about this
                "process-exec",

                # When building .dmg's, we need to talk to IOKit, although the rule
                # changed names in macOS 12+
                xnu_version >= v"20.0.0" ? "iokit-open-user-client" : "iokit-open",

                # We require network access
                "network-bind", "network-outbound", "network-inbound", "system-socket",
            ]),

            SeatbeltRule("file-read*", [
                # Provide read-only access to the majority of the system, but NOT `/Users`
                SeatbeltSubpath("/Applications"),
                SeatbeltSubpath("/Library"),
                SeatbeltSubpath("/System"),
                SeatbeltSubpath("/bin"),
                SeatbeltSubpath("/dev"),
                SeatbeltSubpath("/opt"),
                SeatbeltSubpath("/private/etc"),
                SeatbeltSubpath("/private/var"),
                SeatbeltSubpath("/sbin"),
                SeatbeltSubpath("/usr"),
                SeatbeltSubpath("/var"),

                # Specifically, allow read-only access to the entire parental chain of the workspace,
                # and the temporary directory.  Note that these are not recursive includes, but rather
                # precisely these directories
                vcat(dirname_chain.(workspaces)...)...,
                dirname_chain(temp_dir)...,

                # Allow reading of the buildkite agent, and our hooks directory
                SeatbeltSubpath(artifact"buildkite-agent"),
                SeatbeltSubpath(repo_path("agent", "hooks")),

                # The scheduler's live resource record, for the `pre-exit` hook
                SeatbeltSubpath.(realpath.(readable))...,

                # Allow reading of user preferences and keychains
                # EDIT: I don't think this should be necessary, as we override $HOME
                #SeatbeltSubpath(joinpath(homedir(), "Library", "Preferences")),

                # Also a few symlinks:
                "/tmp",
                "/etc",
            ]),

            # Provide read-write access to a more restricted set of files
            SeatbeltRule("file*", [
                # Allow control over TTY devices, and other fd's
                r"/dev/tty.*",
                "/dev/ptmx",
                "/private/var/run/utmpx",
                SeatbeltSubpath("/dev/fd"),

                # These rules necessary for creating dmg images
                # Allow write access to `/dev/rdiskN` where N is 2 or higher
                r"/dev/rdisk[2-9]+s[0-9]+",
                r"/Volumes/Julia.*",

                # Allow full control over the workspaces
                SeatbeltSubpath.(workspaces)...,

                # Allow reading/writing to the temporary directory
                SeatbeltSubpath(temp_dir),

                # Keychain access requires R/W access to a path in /private/var/folders whose path name is difficult to know beforehand
                SeatbeltSubpath("/private/var/folders"),

                # SSH needs to be able to recognize github.com
                joinpath(homedir(), ".ssh", "known_hosts"),
            ]),
        )
    )

    # Write the config out to the provided IO object
    generate_seatbelt_config(io, config)
    return nothing
end

struct MacOSProcessIdentity
    agent_name::String
    temp_path::String
    cache_path::String
end

struct MacOSProcess
    pid::Int
    ppid::Int
    pgid::Int
    command::String
    cwd::Union{Nothing,String}
end

mutable struct MacSeatbeltBackend <: PlatformBackend
    logdir::String
    cleanup_identities::Vector{MacOSProcessIdentity}
    # Removes the agent user's LMDB semaphore sets; `nothing` to keep them.
    remove_semaphores::Union{Nothing,Function}
    active_jobs::Int
    active_jobs_lock::ReentrantLock
    # Identities of retired slots, kept until none of their processes remain
    retired_identities::Vector{MacOSProcessIdentity}
end

MacSeatbeltBackend(logdir::AbstractString,
                   brgs::Vector{BuildkiteRunnerGroup}=BuildkiteRunnerGroup[];
                   remove_semaphores=Sys.isapple() ? remove_macos_sysv_semaphores : nothing) =
    MacSeatbeltBackend(String(logdir), macos_reaper_identities(brgs),
        remove_semaphores, 0, ReentrantLock(), MacOSProcessIdentity[])

const MACOS_HOMEBREW_TOOLS = [
    "bash",
    "gpg",
    "jq",
    "shyaml",
    "openssl@3",
    "zstd",
    "awscli",
    "htop",
]

const MACOS_RUNTIME_TOOL_CANDIDATES = Dict(
    "bash" => ["bash"],
    "gpg" => ["gpg"],
    "jq" => ["jq"],
    "shyaml" => ["shyaml"],
    "openssl@3" => [
        "/opt/homebrew/opt/openssl@3/bin/openssl",
        "/usr/local/opt/openssl@3/bin/openssl",
    ],
    "zstd" => ["zstd"],
    "awscli" => ["aws"],
    "htop" => ["htop"],
)

function runtime_tool_available(candidates::Vector{String})
    for candidate in candidates
        if isabspath(candidate)
            isfile(candidate) && return true
        elseif Sys.which(candidate) !== nothing
            return true
        end
    end
    return false
end

function missing_macos_runtime_tools()
    return [tool for tool in MACOS_HOMEBREW_TOOLS
        if !runtime_tool_available(MACOS_RUNTIME_TOOL_CANDIDATES[tool])]
end

function check_macos_runtime_tools()
    missing_tools = missing_macos_runtime_tools()
    isempty(missing_tools) ||
        runtime_setup_error("Missing runtime tool(s): $(join(missing_tools, ", "))")
    return nothing
end

function setup_homebrew_tools!()
    missing_tools = String[]
    for tool in MACOS_HOMEBREW_TOOLS
        if !success(pipeline(`brew list $(tool)`, Base.devnull, Base.devnull))
            push!(missing_tools, tool)
        end
    end
    if !isempty(missing_tools)
        @warn("Missing Homebrew tools found, auto-installing...")
        run(`brew install $(missing_tools)`)

        for tool in MACOS_HOMEBREW_TOOLS
            if !success(pipeline(`brew list $(tool)`, Base.devnull, Base.devnull))
                error("Unable to auto-install '$(tool)'")
            end
        end
    end
    check_macos_runtime_tools()
    return nothing
end

function caffeinate_plist_path()
    return joinpath(expanduser("~"), "Library", "LaunchAgents", "org.julialang.caffeinate.plist")
end

function setup_caffeinated!()
    plist_path = caffeinate_plist_path()
    if !isfile(plist_path)
        @info("Generating caffeinate service to prevent sleep")
        mkpath(dirname(plist_path))
        open(plist_path, write=true) do io
            launchd_plist(io;
                label="org.julialang.caffeinate",
                program_args=["/usr/bin/caffeinate", "-disu"],
                env=Dict("PATH" => "/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"),
                cwd=expanduser("~"),
                keepalive="<true />",
            )
        end

        run(ignorestatus(`launchctl unload -w $(plist_path)`))
        run(`launchctl load -w $(plist_path)`)
    end
    check_caffeinated()
    return nothing
end

function uninstall_caffeinated!()
    plist_path = caffeinate_plist_path()
    isfile(plist_path) || return nothing
    run(ignorestatus(`launchctl unload -w $(plist_path)`))
    rm(plist_path; force=true)
    return nothing
end

function check_caffeinated()
    isfile(caffeinate_plist_path()) ||
        runtime_setup_error("Caffeinate launch agent is not installed")
    return nothing
end

function check_xcode_path()
    xcode_path = strip(String(read(`xcode-select -p`)))
    return ispath(joinpath(xcode_path, "usr", "bin", "altool"))
end

function setup_xcode_path!()
    if !check_xcode_path()
        @warn("Invalid `xcode-select` path, resetting, may ask for sudo password")
        run(`sudo xcode-select -r`)
    end
    check_xcode_path() ||
        error("Unable to reset to valid `xcode-select` path!  Do you need to install Xcode.app?")
    return nothing
end

function setup_xcode_license_accepted!()
    if !success(`xcodebuild -license check`)
        @info("Accepting Xcode license, may ask for sudo password")
        run(`sudo xcodebuild -license accept`)
    end
    check_xcode_license_accepted()
    return nothing
end

function check_xcode_license_accepted()
    success(`xcodebuild -license check`) ||
        runtime_setup_error("Xcode license is not accepted")
    return nothing
end

function get_macos_version()
    plist_lines = split(String(read("/System/Library/CoreServices/SystemVersion.plist")), "\n")
    vers_idx = findfirst(l -> occursin("ProductVersion", l), plist_lines)
    vers_idx === nothing && return nothing

    m = match(r">([\d\.]+)<", plist_lines[vers_idx+1])
    m === nothing && return nothing

    return VersionNumber(only(m.captures))
end

function check_macos_runner_configs(brgs::Vector{BuildkiteRunnerGroup})
    macos_version = get_macos_version()
    if macos_version === nothing
        error("Refusing to start without knowing what macOS version we're running under!")
    end

    for brg in brgs
        if configured_tempdir(brg) === nothing
            error("Refusing to start up macOS runner with default tempdir!")
        end

        brg.tags["macos_version"] = "$(macos_version.major).$(macos_version.minor)"
    end
    return nothing
end

function check_macos_host_config()
    if !check_xcode_path()
        runtime_setup_error("Invalid `xcode-select` path")
    end

    check_macos_runtime_tools()
    check_xcode_license_accepted()
    check_coredumps()
    check_caffeinated()
    return nothing
end

function setup_macos_host_config!()
    setup_xcode_path!()
    setup_homebrew_tools!()
    setup_xcode_license_accepted!()
    setup_coredumps()
    setup_caffeinated!()
    return nothing
end

function uninstall_macos_host_config!()
    uninstall_caffeinated!()

    for (label, plist_path) in (
        (MACOS_CORE_CLEANUP_LAUNCHD_LABEL, macos_core_cleanup_launchd_plist_path()),
        (MACOS_COREFILE_LAUNCHD_LABEL, macos_corefile_launchd_plist_path()),
    )
        run(pipeline(ignorestatus(`sudo launchctl bootout system/$(label)`);
            stdout=devnull, stderr=devnull))
        isfile(plist_path) && run(`sudo rm -f $(plist_path)`)
    end
    return nothing
end

function check_macos_seatbelt_configs(brgs::Vector{BuildkiteRunnerGroup})
    check_macos_runner_configs(brgs)
    check_macos_host_config()
    return nothing
end

function setup_macos_seatbelt_configs!(brgs::Vector{BuildkiteRunnerGroup})
    check_macos_runner_configs(brgs)
    setup_macos_host_config!()
    return nothing
end

check_config(::MacSeatbeltBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    check_macos_seatbelt_configs(brgs)

setup_config!(::MacSeatbeltBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    setup_macos_seatbelt_configs!(brgs)

cleanup_config!(::MacSeatbeltBackend) = uninstall_macos_host_config!()

function macos_agent_temp_path(slot::Slot)
    return joinpath(tempdir(slot.brg), "agent-tempdirs", slot.name)
end

function macos_slot_cache_root(slot::Slot)
    return joinpath(cachedir(slot.brg), slot.name)
end

function macos_slot_reaper_identity(slot::Slot)
    return MacOSProcessIdentity(slot.name, macos_agent_temp_path(slot),
        macos_slot_cache_root(slot))
end

function macos_reaper_identities(slots::Vector{Slot})
    identities = unique(macos_slot_reaper_identity.(slots))
    sort!(identities, by=id -> (id.agent_name, id.temp_path, id.cache_path))
    return identities
end

function macos_reaper_identities(brgs::Vector{BuildkiteRunnerGroup})
    macos_brgs = [brg for brg in brgs if brg.backend == BACKEND_MACOS_SEATBELT]
    return macos_reaper_identities(scheduler_slots(macos_brgs))
end

function macos_host_slot_name(name::AbstractString, hostname::AbstractString)
    parts = rsplit(name, "-$(hostname)."; limit=2)
    return length(parts) == 2 && all(!isempty, parts) && all(isdigit, parts[2])
end

function macos_retired_reaper_identities(current::Vector{MacOSProcessIdentity};
                                         hostname::AbstractString=get_short_hostname())
    roots = unique((dirname(identity.temp_path), dirname(identity.cache_path))
        for identity in current)

    retired = MacOSProcessIdentity[]
    for (temp_slots_root, cache_root) in roots
        names = Set{String}()
        for root in (temp_slots_root, cache_root)
            isdir(root) || continue
            for name in readdir(root)
                isdir(joinpath(root, name)) || continue
                macos_host_slot_name(name, hostname) && push!(names, name)
            end
        end

        for name in names
            identity = MacOSProcessIdentity(name, joinpath(temp_slots_root, name),
                joinpath(cache_root, name))
            identity in current || push!(retired, identity)
        end
    end
    sort!(retired, by=id -> (id.agent_name, id.temp_path, id.cache_path))
    return retired
end

function setup_backend!(backend::MacSeatbeltBackend, slots)
    backend.cleanup_identities = macos_reaper_identities(Vector{Slot}(slots))
    return nothing
end

function build_seatbelt_env(temp_path::String, cache_path::String;
                            agent_token_path::String,
                            julia_arch::Union{String,Nothing}=nothing,
                            alloc::Allocation=Allocation(Sys.CPU_THREADS),
                            resources_file::Union{String,Nothing}=nothing)
    paths = [
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/bin",
        "/sbin",
    ]
    if Sys.ARCH == :aarch64 && isdir("/opt/homebrew/Cellar")
        pushfirst!(paths, "/opt/homebrew/sbin")
        pushfirst!(paths, "/opt/homebrew/bin")
    end
    env = Dict(
        "TMPDIR" => joinpath(temp_path, "tmp"),
        "HOME" => joinpath(temp_path, "home"),
        "BUILDKITE_BIN_PATH" => artifact"buildkite-agent",
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => cache_path,
        "BUILDKITE_AGENT_TOKEN" => String(chomp(String(read(agent_token_path)))),
        allocation_env(alloc)...,
        "PATH" => join(paths, ":"),
        "TERM" => "screen",
    )
    julia_arch === nothing || (env["BUILDKITE_PLUGIN_JULIA_ARCH"] = julia_arch)
    resources_file === nothing || (env["SBA_RESOURCES_FILE"] = resources_file)
    return env
end

function host_paths_to_create(::MacSeatbeltBackend, temp_path, cache_path)
    return String[
        joinpath(temp_path, "tmp"),
        joinpath(temp_path, "home"),
        joinpath(temp_path, "home", "Library", "Preferences"),
        joinpath(cache_path, "build"),
    ]
end

function host_paths_to_cleanup(::MacSeatbeltBackend, temp_path, cache_path)
    return String[
        temp_path,
        joinpath(cache_path, "build"),
    ]
end

function force_delete(path)
    Base.Filesystem.prepare_for_deletion(path)
    rm(path; force=true, recursive=true)
end

function macos_identity_boundary(ch::Char)
    return isspace(ch) || ch in ('=', '"', '\'', ':', ';', ',', '(', ')', '[', ']', '{', '}', '/')
end

function macos_contains_identity(text::AbstractString, needle::AbstractString)
    isempty(needle) && return false
    idx = firstindex(text)
    while idx <= lastindex(text)
        range = findnext(needle, text, idx)
        range === nothing && return false

        before_ok = first(range) == firstindex(text) ||
            macos_identity_boundary(text[prevind(text, first(range))])
        after_idx = nextind(text, last(range))
        after_ok = after_idx > lastindex(text) ||
            macos_identity_boundary(text[after_idx])
        before_ok && after_ok && return true
        idx = nextind(text, first(range))
    end
    return false
end

function macos_command_matches_identity(command::AbstractString, identity::MacOSProcessIdentity)
    return macos_contains_identity(command, "--name=$(identity.agent_name)") ||
        macos_contains_identity(command, "--sockets-path=$(identity.temp_path)") ||
        macos_contains_identity(command, identity.temp_path) ||
        macos_contains_identity(command, identity.cache_path)
end

function macos_cwd_matches_identity(cwd::Union{Nothing,String}, identity::MacOSProcessIdentity)
    cwd === nothing && return false
    return path_within_root(cwd, identity.temp_path) ||
        path_within_root(cwd, identity.cache_path)
end

function macos_process_matches(process::MacOSProcess, identities)
    for identity in identities
        if macos_command_matches_identity(process.command, identity) ||
                macos_cwd_matches_identity(process.cwd, identity)
            return true
        end
    end
    return false
end

# The process table is read in-process from libproc and sysctl rather than from
# `ps`, which costs a process per call and can hang.
#
# Parent and group come from `struct proc_bsdshortinfo`, which unlike
# `struct proc_bsdinfo` (PROC_PIDTBSDINFO) can be read for other users'
# processes. Constants and layout are from the macOS SDK's `sys/proc_info.h`
# and `sys/sysctl.h` (Xcode 26.6): PROC_PIDT_SHORTBSDINFO = 13,
# sizeof(struct proc_bsdshortinfo) = 64, with the uint32s `pbsi_ppid` at byte
# 4 and `pbsi_pgid` at 8, and `pbsi_comm[MAXCOMLEN = 16]` at 16; CTL_KERN = 1,
# KERN_PROCARGS2 = 49.
const MACOS_PROC_PIDT_SHORTBSDINFO = Cint(13)
const MACOS_BSDINFO_SIZE = 64
const MACOS_BSDINFO_PPID = 4
const MACOS_BSDINFO_PGID = 8
const MACOS_BSDINFO_COMM = 16
const MACOS_MAXCOMLEN = 16
const MACOS_CTL_KERN = Cint(1)
const MACOS_KERN_PROCARGS2 = Cint(49)

macos_u32(buf::AbstractVector{UInt8}, offset::Integer) =
    Int(ltoh(reinterpret(UInt32, buf[offset+1:offset+4])[1]))

# NUL-terminated string at the start of `bytes`.
macos_cstring(bytes::AbstractVector{UInt8}) =
    String(bytes[1:something(findfirst(iszero, bytes), length(bytes) + 1) - 1])

# `proc_listallpids(buffer, size)`: the number of pids it wrote, or with no
# buffer the number there are.
function macos_listallpids(pids::Union{Nothing,Vector{Cint}})
    count = pids === nothing ? ccall(:proc_listallpids, Cint, (Ptr{Cvoid}, Cint), C_NULL, 0) :
        ccall(:proc_listallpids, Cint, (Ptr{Cint}, Cint), pids, sizeof(pids))
    count > 0 || error("proc_listallpids failed: ", Libc.strerror(Libc.errno()))
    return Int(count)
end

# Every pid, or an error: the kernel fills at most the buffer it is given and
# does not say whether more would have fitted, so a full buffer is retried
# larger. A partial table could make the reaper miss a job's processes, or the
# semaphore cleanup believe none are left.
function macos_all_pids(listpids=macos_listallpids; attempts::Integer=4)
    capacity = listpids(nothing) + 256
    for _ in 1:attempts
        pids = zeros(Cint, capacity)
        count = listpids(pids)
        count < capacity && return Int.(pids[1:count])
        capacity *= 2
    end
    error("The process table kept growing past $(capacity ÷ 2) processes")
end

# `(; ppid, pgid, comm)`, or `nothing` if the process is gone or a zombie.
function macos_bsdinfo(pid::Integer, buf::Vector{UInt8}=zeros(UInt8, MACOS_BSDINFO_SIZE))
    n = ccall(:proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{UInt8}, Cint),
              pid, MACOS_PROC_PIDT_SHORTBSDINFO, 0, buf, MACOS_BSDINFO_SIZE)
    n == MACOS_BSDINFO_SIZE || return nothing
    return (; ppid = macos_u32(buf, MACOS_BSDINFO_PPID), pgid = macos_u32(buf, MACOS_BSDINFO_PGID),
            comm = macos_cstring(view(buf, MACOS_BSDINFO_COMM .+ (1:MACOS_MAXCOMLEN))))
end

# Bytes as Apple's `ps` shows them in the C locale, deliberately whatever the
# scheduler's locale: `ps` passes the command line through
# `strvis(VIS_TAB | VIS_NL | VIS_NOSLASH)`, which leaves printable ASCII and
# spaces as they are, shows tab, newline and 0xa0 in octal (\011, \012, \240),
# other control characters as ^X (DEL ^?), and the other bytes from 0x80 as
# M- or M^ plus the same for the low seven bits. The reaper matches identities
# on this form, as it did on `ps`'s output: a raw newline, or a non-ASCII space,
# would count as a word boundary and let an unrelated command line match.
function macos_vis(bytes::AbstractVector{UInt8})
    out = IOBuffer()
    for b in bytes
        c = b & 0x7f
        if 0x20 <= b <= 0x7e
            write(out, b)
        elseif b == 0x09 || b == 0x0a || b == 0xa0
            print(out, '\\', string(b; base=8, pad=3))
        else
            b >= 0x80 && write(out, UInt8('M'))
            if c < 0x20 || c == 0x7f
                write(out, UInt8('^'), c == 0x7f ? UInt8('?') : c + 0x40)
            else
                write(out, UInt8('-'), c)
            end
        end
    end
    return String(take!(out))
end

# The command line from a `KERN_PROCARGS2` buffer: an int argc, the executable
# path, NUL padding, then argc NUL-terminated arguments (the environment
# follows). The arguments joined by spaces, as `ps -ww -o command` shows them,
# or `nothing` if the buffer is malformed.
function parse_macos_procargs(bytes::AbstractVector{UInt8})
    length(bytes) >= 4 || return nothing
    argc = Int(ltoh(reinterpret(Int32, bytes[1:4])[1]))
    argc > 0 || return nothing
    pos = findnext(iszero, bytes, 5)                    # end of the executable path
    pos === nothing && return nothing
    pos = findnext(!iszero, bytes, pos)                 # past the padding
    pos === nothing && return nothing
    args = String[]
    while length(args) < argc
        stop = findnext(iszero, bytes, pos)
        stop === nothing && return nothing
        push!(args, macos_vis(view(bytes, pos:stop-1)))
        pos = stop + 1
    end
    return join(args, " ")
end

# `nothing` for processes whose arguments this user cannot read (other users'
# and setuid ones) and ones that are gone.
function macos_procargs(pid::Integer, buf::Vector{UInt8})
    mib = Cint[MACOS_CTL_KERN, MACOS_KERN_PROCARGS2, pid]
    size = Ref{Csize_t}(length(buf))
    ccall(:sysctl, Cint, (Ptr{Cint}, Cuint, Ptr{UInt8}, Ref{Csize_t}, Ptr{Cvoid}, Csize_t),
          mib, length(mib), buf, size, C_NULL, 0) == 0 || return nothing
    return parse_macos_procargs(view(buf, 1:Int(size[])))
end

function macos_argmax()
    value, size = Ref{Cint}(0), Ref{Csize_t}(sizeof(Cint))
    ccall(:sysctlbyname, Cint, (Cstring, Ptr{Cint}, Ref{Csize_t}, Ptr{Cvoid}, Csize_t),
          "kern.argmax", value, size, C_NULL, 0) == 0 || return 1024 * 1024
    return Int(value[])
end

# Without readable arguments the command is the short name in parentheses;
# `ps`, being setuid root, shows those in full. Processes that exit during the
# scan are left out, and so are zombies, which have no short BSD info (`ps`
# shows them as `<defunct>`). Off macOS, where the backend's tests run without
# libproc, there are none.
function macos_process_list()
    processes = MacOSProcess[]
    Sys.isapple() || return processes
    info = zeros(UInt8, MACOS_BSDINFO_SIZE)
    args = zeros(UInt8, macos_argmax())
    for pid in macos_all_pids()
        pid > 0 || continue
        bsd = macos_bsdinfo(pid, info)
        bsd === nothing && continue
        command = something(macos_procargs(pid, args), "($(macos_vis(codeunits(bsd.comm))))")
        push!(processes, MacOSProcess(pid, bsd.ppid, bsd.pgid, command, nothing))
    end
    return processes
end

# `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, which is also what `lsof` reads, but
# without a process per batch of PIDs: the resource sampler needs the process
# table every few seconds. A `struct proc_vnodepathinfo` starts with the cwd's
# `struct vnode_info_path`: a 152-byte `vnode_info`, then the path.
const MACOS_PROC_PIDVNODEPATHINFO = Cint(9)
const MACOS_VNODEPATHINFO_SIZE = 2352
const MACOS_VNODEPATHINFO_CWD = 152
const MACOS_MAXPATHLEN = 1024

# Nothing for processes of other users, and ones that are gone. Nothing at all
# off macOS, where the backend's tests run without the call existing.
function macos_process_cwd(pid::Integer, buf::Vector{UInt8}=zeros(UInt8, MACOS_VNODEPATHINFO_SIZE))
    Sys.isapple() || return nothing
    n = ccall(:proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{UInt8}, Cint),
              pid, MACOS_PROC_PIDVNODEPATHINFO, 0, buf, length(buf))
    n == length(buf) || return nothing
    path = view(buf, MACOS_VNODEPATHINFO_CWD .+ (1:MACOS_MAXPATHLEN))
    len = something(findfirst(iszero, path), MACOS_MAXPATHLEN + 1) - 1
    return len == 0 ? nothing : String(path[1:len])
end

function macos_process_cwds(pids::Vector{Int})
    cwds = Dict{Int,String}()
    buf = zeros(UInt8, MACOS_VNODEPATHINFO_SIZE)
    for pid in unique(filter(>(0), pids))
        cwd = macos_process_cwd(pid, buf)
        cwd === nothing || (cwds[pid] = cwd)
    end
    return cwds
end

function macos_process_table()
    processes = macos_process_list()
    cwds = macos_process_cwds([process.pid for process in processes])
    return [MacOSProcess(process.pid, process.ppid, process.pgid, process.command,
                get(cwds, process.pid, nothing))
            for process in processes]
end

function macos_reap_process_ids(processes::Vector{MacOSProcess}, identities;
                                self_pid::Integer=getpid())
    selected = Set{Int}()
    for process in processes
        process.pid == self_pid && continue
        macos_process_matches(process, identities) && push!(selected, process.pid)
    end

    changed = true
    while changed
        changed = false
        for process in processes
            process.pid == self_pid && continue
            if process.ppid in selected && !(process.pid in selected)
                push!(selected, process.pid)
                changed = true
            end
        end
    end
    return sort(collect(selected), rev=true)
end

const MACOS_ESRCH = 3

function macos_signal_process(pid::Integer, signal::Integer)
    ret = ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(signal))
    ret == 0 && return true
    errno = Base.Libc.errno()
    errno == MACOS_ESRCH && return true
    @warn("Unable to signal macOS job process", pid, signal, errno)
    return false
end

function macos_process_alive(pid::Integer)
    ret = ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(0))
    ret == 0 && return true
    return Base.Libc.errno() != MACOS_ESRCH
end

function reap_macos_processes!(identities;
                               term_grace::Real=10.0,
                               poll_interval::Real=0.25)
    isempty(identities) && return Int[]
    pids = macos_reap_process_ids(macos_process_table(), identities)
    isempty(pids) && return Int[]

    @info("Reaping macOS job process(es)", pids)
    foreach(pid -> macos_signal_process(pid, Base.SIGTERM), pids)

    deadline = time() + Float64(term_grace)
    while time() < deadline && any(macos_process_alive, pids)
        sleep(min(Float64(poll_interval), max(deadline - time(), 0.0)))
    end

    remaining = macos_reap_process_ids(macos_process_table(), identities)
    if !isempty(remaining)
        @warn("Force killing lingering macOS job process(es)", pids=remaining)
        foreach(pid -> macos_signal_process(pid, Base.SIGKILL), remaining)
    end
    return unique(vcat(pids, remaining))
end

# IDs of the LMDB semaphore sets that `owner` owns, from the output of `ipcs -s`. LMDB
# derives the key with `ftok(lockfile, 'M')`, so its keys start with 0x4d; sets with
# other keys belong to something else and are left alone.
function parse_ipcs_semaphores(output::AbstractString, owner::AbstractString)
    ids = Int[]
    key_col = owner_col = nothing
    for line in split(output, '\n')
        fields = split(line)
        isempty(fields) && continue
        if fields[1] == "T"
            key_col = findfirst(==("KEY"), fields)
            owner_col = findfirst(==("OWNER"), fields)
        elseif fields[1] == "s" && key_col !== nothing && owner_col !== nothing &&
                length(fields) >= max(key_col, owner_col) &&
                fields[owner_col] == owner && startswith(fields[key_col], "0x4d")
            id = tryparse(Int, fields[2])
            id === nothing || push!(ids, id)
        end
    end
    return ids
end

# Julia's JIT object cache uses LMDB, which on macOS locks with a SysV semaphore set per
# cache directory. Julia does not remove the set when it exits, and the sets last until
# reboot, so after some days of jobs the system limit is reached and the cache stops
# working (JuliaLang/julia#63789). Removing a set is only safe while no process has its
# environment open: the next process to open it alone creates the set again. The agent
# user runs nothing but jobs, so that holds whenever no job is running.
function remove_macos_sysv_semaphores()
    owner = Libc.getpwuid(Libc.getuid()).username
    ids = parse_ipcs_semaphores(read(`ipcs -s`, String), owner)
    isempty(ids) && return 0
    for chunk in Iterators.partition(ids, 100)
        args = collect(Iterators.flatten(("-s", string(id)) for id in chunk))
        success(`ipcrm $(args)`) ||
            @warn("Unable to remove some SysV semaphore sets", ids=chunk)
    end
    @info("Removed SysV semaphore sets", count=length(ids))
    return length(ids)
end

# Call with `backend.active_jobs_lock` held, so that no job starts meanwhile.
function remove_idle_macos_sysv_semaphores_locked(backend)
    backend.remove_semaphores !== nothing && backend.active_jobs == 0 || return nothing
    try
        # Reaping can fail or leave a process behind, which may still have its
        # environment open.
        identities = vcat(backend.cleanup_identities, backend.retired_identities)
        survivors = macos_reap_process_ids(macos_process_table(), identities)
        if !isempty(survivors)
            @warn("Keeping SysV semaphore sets while job processes remain", pids=survivors)
            return nothing
        end
        empty!(backend.retired_identities)
        backend.remove_semaphores()
    catch err
        @warn("Unable to remove SysV semaphore sets", exception=(err, catch_backtrace()))
    end
    return nothing
end

function macos_build_dirs(cache_root::AbstractString)
    build_dirs = String[]
    isdir(cache_root) || return build_dirs
    for pipeline_dir in readdir(cache_root; join=true)
        isdir(pipeline_dir) || continue
        for trust_dir in readdir(pipeline_dir; join=true)
            isdir(trust_dir) || continue
            push!(build_dirs, joinpath(trust_dir, "build"))
        end
    end
    return build_dirs
end

function cleanup_macos_identity_paths(identity::MacOSProcessIdentity)
    paths = unique(vcat(
        String[identity.temp_path, joinpath(identity.cache_path, "build")],
        macos_build_dirs(identity.cache_path),
    ))
    for path in paths
        try
            force_delete(path)
        catch err
            @warn("Unable to remove macOS job scratch path",
                path, exception=(err, catch_backtrace()))
        end
    end
    return nothing
end

function cleanup_retired_macos_identity_paths(identity::MacOSProcessIdentity)
    for path in (identity.temp_path, identity.cache_path)
        try
            force_delete(path)
        catch err
            @warn("Unable to remove retired macOS slot path",
                path, exception=(err, catch_backtrace()))
        end
    end
    return nothing
end

function cleanup(backend::MacSeatbeltBackend)
    retired = macos_retired_reaper_identities(backend.cleanup_identities)
    reap_macos_processes!(vcat(backend.cleanup_identities, retired))
    cleanup_macos_identity_paths.(backend.cleanup_identities)
    cleanup_retired_macos_identity_paths.(retired)
    lock(backend.active_jobs_lock) do
        union!(backend.retired_identities, retired)
        remove_idle_macos_sysv_semaphores_locked(backend)
    end
    return nothing
end

function seatbelt_setup(f::Function, brg::BuildkiteRunnerGroup;
                        backend::MacSeatbeltBackend,
                        agent_name::String,
                        cache_path::String,
                        temp_path::String,
                        alloc::Allocation,
                        live_path::Union{Nothing,String}=nothing,
                        agent_token_path::String=joinpath(secrets_dir(brg), "buildkite-agent-token"))
    force_delete.(host_paths_to_cleanup(backend, temp_path, cache_path))
    mkpath.(host_paths_to_create(backend, temp_path, cache_path))
    seatbelt_env = build_seatbelt_env(temp_path, cache_path;
        agent_token_path=agent_token_path,
        julia_arch=brg.tags["arch"],
        alloc,
        resources_file=live_path === nothing ? nothing : joinpath(live_path, LIVE_RECORD_NAME))
    build_path = joinpath(cache_path, "build")

    try
        with_seatbelt(generate_buildkite_seatbelt_config, [cache_path], temp_path;
                      readable=live_path === nothing ? String[] : [live_path]) do sb_path
            if brg.verbose
                run(`cat $(sb_path)`)
                println()
                println()
            end
            f(sb_path, seatbelt_env, build_path)
        end
    finally
        identity = MacOSProcessIdentity(agent_name, temp_path, cache_path)
        reap_macos_processes!([identity])
        cleanup_macos_identity_paths(identity)
    end
end

#
# Job resource usage
#

# The job as a `ResourceSource` (see resources.jl). macOS jobs get the whole host
# and there are no cgroups, so CPU is host-wide: the busy time of all cores from
# `Sys.cpu_info()`, which includes the host's background work. Memory is per
# process: the summed `phys_footprint` of the job's processes (the reaper's
# selection: the agent's descendants and processes that escaped the tree), which
# is their resident anonymous memory plus its compressed and swapped-out parts,
# the figure Activity Monitor shows. There is no per-job page cache or swap
# figure; the host's memory in use and swap go in `details`, with their values
# at the start, as does the largest single process's lifetime peak footprint,
# kept by the kernel and so not missed between samples.
#
# The record is published in a per-slot directory of the scheduler's log
# directory, which the seatbelt profile lets the job read but not write, and the
# job finds it through `SBA_RESOURCES_FILE`.
mutable struct MacOSResourceSource <: ResourceSource
    identity::MacOSProcessIdentity
    live_dir::Union{Nothing,String}
    # Jobs running on the host, as host-wide figures are shared between them.
    active_jobs::Function
    host_cpus::Int
    # Apple Silicon numbers its efficiency cores first; 0 elsewhere.
    efficiency_cpus::Int
    efficiency_first::Union{Nothing,Float64}
    efficiency_last::Union{Nothing,Float64}
    peak_processes::Int
    peak_process_footprint::Int
    host_used_at_start::Union{Nothing,Int}
    peak_host_used::Union{Nothing,Int}
    swap_at_start::Union{Nothing,Int}
    peak_swap::Union{Nothing,Int}
    peak_pressure::Union{Nothing,Int}
    peak_loadavg::Float64
    peak_jobs::Int
end

MacOSResourceSource(identity::MacOSProcessIdentity; live_dir=nothing, active_jobs=() -> 1,
                    host_cpus=length(Sys.cpu_info()), efficiency_cpus=macos_efficiency_cpus()) =
    MacOSResourceSource(identity, live_dir, active_jobs, host_cpus, efficiency_cpus, nothing, nothing,
        0, 0, nothing, nothing, nothing, nothing, nothing, 0.0, 0)

function macos_sysctl(name::AbstractString, ::Type{T}) where {T}
    value = Ref{T}()
    size = Ref{Csize_t}(sizeof(T))
    ret = ccall(:sysctlbyname, Cint, (Cstring, Ptr{Cvoid}, Ref{Csize_t}, Ptr{Cvoid}, Csize_t),
                name, value, size, C_NULL, 0)
    return ret == 0 && size[] == sizeof(T) ? value[] : nothing
end

function macos_efficiency_cpus()
    Sys.isapple() && macos_sysctl("hw.nperflevels", Cint) == 2 || return 0
    return Int(something(macos_sysctl("hw.perflevel1.logicalcpu", Cint), 0))
end

# `proc_pid_rusage(RUSAGE_INFO_V4)`: a `struct rusage_info_v4` as 64-bit words,
# a 16-byte UUID first. Nothing for processes of other users, and ones that are gone.
const MACOS_RUSAGE_INFO_V4 = Cint(4)
const MACOS_RUSAGE_V4_WORDS = 37
const MACOS_RUSAGE_PHYS_FOOTPRINT = 10
const MACOS_RUSAGE_LIFETIME_MAX_PHYS_FOOTPRINT = 31

function macos_process_footprint(pid::Integer)
    buf = zeros(UInt64, MACOS_RUSAGE_V4_WORDS)
    ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{UInt64}), pid, MACOS_RUSAGE_INFO_V4, buf) == 0 ||
        return nothing
    return (current=Int(buf[MACOS_RUSAGE_PHYS_FOOTPRINT]),
            lifetime_max=Int(buf[MACOS_RUSAGE_LIFETIME_MAX_PHYS_FOOTPRINT]))
end

# Memory in use as Activity Monitor counts it: app memory (anonymous, less
# purgeable), wired and compressed, from `host_statistics64(HOST_VM_INFO64)`,
# whose `vm_statistics64` counts pages in 32-bit fields at these byte offsets.
const MACOS_HOST_VM_INFO64 = Cint(4)
const MACOS_HOST_VM_INFO64_COUNT = 62
const MACOS_MACH_HOST = Ref{Cuint}(0)

function macos_host_used_bytes()
    MACOS_MACH_HOST[] == 0 && (MACOS_MACH_HOST[] = ccall(:mach_host_self, Cuint, ()))
    buf = zeros(UInt32, MACOS_HOST_VM_INFO64_COUNT)
    count = Ref{Cuint}(MACOS_HOST_VM_INFO64_COUNT)
    ccall(:host_statistics64, Cint, (Cuint, Cint, Ptr{UInt32}, Ref{Cuint}),
          MACOS_MACH_HOST[], MACOS_HOST_VM_INFO64, buf, count) == 0 || return nothing
    page_size = macos_sysctl("hw.pagesize", Int64)
    page_size === nothing && return nothing
    field(offset) = Int(buf[offset ÷ 4 + 1])
    wired, purgeable, compressed, internal = field(12), field(88), field(128), field(140)
    return (internal - purgeable + wired + compressed) * page_size
end

# `vm.swapusage` is a `struct xsw_usage`: total, available and used bytes, then more.
function macos_swap_used_bytes()
    usage = macos_sysctl("vm.swapusage", NTuple{4,UInt64})
    return usage === nothing ? nothing : Int(usage[3])
end

const MACOS_PRESSURE_LEVELS = Dict(1 => "normal", 2 => "warn", 4 => "critical")

resource_platform(::MacOSResourceSource) = "macos"
resource_host_cpus(source::MacOSResourceSource) = source.host_cpus

# Errors reading one figure leave it out of this sample, as a throwing sample
# would end the sampler's timer.
function sample_resources(source::MacOSResourceSource)
    busy = try
        [(cpu.cpu_times!user + cpu.cpu_times!nice + cpu.cpu_times!sys) / 1000
         for cpu in Sys.cpu_info()]
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
    if busy !== nothing && source.efficiency_cpus > 0
        efficiency = sum(busy[1:min(source.efficiency_cpus, end)])
        source.efficiency_first === nothing && (source.efficiency_first = efficiency)
        source.efficiency_last = efficiency
    end

    needed = try
        pids = macos_reap_process_ids(macos_process_table(), [source.identity])
        footprints = filter(!isnothing, map(macos_process_footprint, pids))
        source.peak_processes = max(source.peak_processes, length(footprints))
        for footprint in footprints
            source.peak_process_footprint = max(source.peak_process_footprint, footprint.lifetime_max)
        end
        sum(footprint -> footprint.current, footprints; init=0)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end

    host_used = macos_host_used_bytes()
    source.host_used_at_start === nothing && (source.host_used_at_start = host_used)
    source.peak_host_used = maxpeak(source.peak_host_used, host_used)
    swap = macos_swap_used_bytes()
    source.swap_at_start === nothing && (source.swap_at_start = swap)
    source.peak_swap = maxpeak(source.peak_swap, swap)
    pressure = macos_sysctl("kern.memorystatus_vm_pressure_level", Cint)
    source.peak_pressure = maxpeak(source.peak_pressure, pressure === nothing ? nothing : Int(pressure))
    source.peak_loadavg = max(source.peak_loadavg, Sys.loadavg()[1])
    source.peak_jobs = max(source.peak_jobs, source.active_jobs())

    return ResourceSample(; cpu_seconds=busy === nothing ? nothing : sum(busy), needed_bytes=needed)
end

function resource_details(source::MacOSResourceSource)
    efficiency = source.efficiency_last === nothing ? nothing :
                 round(source.efficiency_last - source.efficiency_first; digits=1)
    return Dict{String,Any}(
        "efficiency_cpus" => source.efficiency_cpus,
        "efficiency_cpu_seconds" => efficiency,
        "peak_processes" => source.peak_processes,
        "peak_process_footprint_bytes" => source.peak_process_footprint,
        "host_used_bytes_at_start" => source.host_used_at_start,
        "peak_host_used_bytes" => source.peak_host_used,
        "swap_used_bytes_at_start" => source.swap_at_start,
        "peak_swap_used_bytes" => source.peak_swap,
        "peak_memory_pressure" => get(MACOS_PRESSURE_LEVELS, source.peak_pressure, source.peak_pressure),
        "peak_loadavg" => round(source.peak_loadavg; digits=1),
        "peak_jobs" => source.peak_jobs,
    )
end

function publish_resources(source::MacOSResourceSource, content::AbstractString)
    source.live_dir === nothing && return nothing
    publish_file_atomically(joinpath(source.live_dir, LIVE_RECORD_NAME), content)
end

struct MacSeatbeltHandle
    backend::MacSeatbeltBackend
    slot::Slot
    job::Job
    plan::CachePlan
    alloc::Allocation
    agent_name::String
    temp_path::String
    log_path::String
    # `sandbox-exec` execs the agent, so this is the agent process.
    agent_proc::Base.RefValue{Union{Nothing,Base.Process}}
    # Whether `reap` has finished and this job no longer counts as active.
    reaped::Base.RefValue{Bool}
    launch::LaunchGate
    resources::ResourceSampler{MacOSResourceSource}
end

# The job must not be able to write where the scheduler publishes its record:
# it could change the record, or plant a symlink for the scheduler to write
# through. These are the seatbelt profile's writable paths that a `logdir`
# could plausibly be in.
function check_macos_live_path(live_path::AbstractString; temp_path::AbstractString,
                               cache_path::AbstractString)
    resolve(path) = ispath(path) ? realpath(path) : normpath(abspath(path))
    live = resolve(live_path)
    for root in (temp_path, cache_path, "/private/var/folders")
        path_within_root(live, resolve(root)) &&
            error("The scheduler's log directory is within $(root), which macOS jobs can write to")
    end
    startswith(live, "/Volumes/Julia") &&
        error("The scheduler's log directory is on a /Volumes/Julia* volume, which macOS jobs can write to")
    return nothing
end

function prepare(backend::MacSeatbeltBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    if plan.ccache_pool !== nothing
        error("macOS seatbelt backend does not support shared ccache pools")
    end

    mkpath(plan.cache_pool)
    agent_name = slot.name
    temp_path = macos_agent_temp_path(slot)
    log_path = job_log_path(backend.logdir, agent_name, job)
    mkpath(dirname(log_path))
    live_path = live_resources_path(backend.logdir, agent_name)
    rm(live_path; recursive=true, force=true)
    mkpath(live_path)
    check_macos_live_path(live_path; temp_path, cache_path=plan.cache_pool)
    identity = MacOSProcessIdentity(agent_name, temp_path, plan.cache_pool)
    source = MacOSResourceSource(identity; live_dir=live_path,
        active_jobs=() -> backend.active_jobs)
    lock(backend.active_jobs_lock) do
        backend.active_jobs += 1
    end
    return MacSeatbeltHandle(backend, slot, job, plan, alloc, agent_name, temp_path, log_path,
        Ref{Union{Nothing,Base.Process}}(nothing), Ref(false), LaunchGate(),
        ResourceSampler(source; context=job_resource_context(; job, slot=slot.name,
            group=slot.brg.name, queue=job_queue(slot.brg, job), alloc)))
end

function run_job(handle::MacSeatbeltHandle, deadline::Union{Nothing,Float64}=nothing)
    brg = handle.slot.brg
    return seatbelt_setup(brg;
        backend=handle.backend,
        agent_name=handle.agent_name,
        cache_path=handle.plan.cache_pool,
        temp_path=handle.temp_path,
        alloc=handle.alloc,
        live_path=handle.resources.source.live_dir,
    ) do sb_path, seatbelt_env, build_path
        # Keep the agent's Unix sockets (e.g. the job-api socket) directly under
        # the short temp dir.  The default is `$HOME/.buildkite-agent/sockets`,
        # which on macOS blows past the 104-character `sun_path` limit and
        # crashes the agent before it can run the job.
        cmd = buildkite_agent_start_command(brg;
            agent_binary=artifact"buildkite-agent/buildkite-agent",
            hooks_path=repo_path("agent", "hooks"),
            cache_path=handle.plan.cache_pool,
            sockets_path=handle.temp_path,
            agent_name=handle.agent_name,
            job=handle.job,
        )

        open(handle.log_path, "a") do log
            println(log, job_start_banner(handle.job, handle.plan))
            sandbox_cmd = Cmd(`sandbox-exec -f $(sb_path) $(cmd)`; dir=build_path)
            commit_launch!(handle.launch)
            proc = run(pipeline(setenv(sandbox_cmd, seatbelt_env);
                stdout=log,
                stderr=log,
            ); wait=false)
            handle.agent_proc[] = proc
            sampler = start_resource_sampler(handle.resources)
            try
                return wait_process_exit(proc, deadline,
                    "running macOS seatbelt job $(handle.job.id)")
            finally
                close(sampler)
            end
        end
    end
end

# The runner's teardown reaps whatever the agent leaves behind.
function macos_descendant_pids(processes::Vector{MacOSProcess}, root::Integer)
    selected = Set{Int}((root,))
    changed = true
    while changed
        changed = false
        for process in processes
            if process.ppid in selected && !(process.pid in selected)
                push!(selected, process.pid)
                changed = true
            end
        end
    end
    delete!(selected, root)
    return sort(collect(selected), rev=true)
end

function stop_job(handle::MacSeatbeltHandle; force::Bool=false, kill_delay::Real=STOP_KILL_DELAY,
                  process_table::Function=macos_process_table)
    committed = close_launch_gate!(handle.launch)
    proc = handle.agent_proc[]
    if proc === nothing
        committed || return :not_acquired
        return force ? :failed : :no_agent
    end
    process_running(proc) || return :ended
    try
        if force
            kill(proc, Base.SIGKILL)
            return :stopped
        end
        kill(proc, Base.SIGQUIT)
        # As on Linux: kill the job instead of waiting out the agent's cancel grace period.
        sleep(kill_delay)
        for _ in 1:5
            pids = macos_descendant_pids(process_table(), getpid(proc))
            isempty(pids) && break
            foreach(pid -> macos_signal_process(pid, Base.SIGKILL), pids)
            sleep(0.2)
        end
    catch err
        # A signal may have been delivered, so the job may be stopped all the same.
        @warn("Unable to finish stopping the Buildkite job", slot=handle.slot.name,
            exception=(err, catch_backtrace()))
        return :unconfirmed
    end
    return :stopped
end

# A job counts as active until its processes have been reaped, so a reap that
# failed (and is retried by the scheduler) keeps it counted, and only the reap
# that succeeds uncounts it.
function reap(handle::MacSeatbeltHandle; reap_processes::Function=reap_macos_processes!)
    identity = MacOSProcessIdentity(handle.agent_name, handle.temp_path, handle.plan.cache_pool)
    backend = handle.backend
    # Stop sampling first, on every attempt, and before removing the live
    # record, so no late sample recreates it.
    stop_resources!(handle.resources)
    live_dir = handle.resources.source.live_dir
    live_dir === nothing || rm(live_dir; recursive=true, force=true)
    reap_processes([identity])
    cleanup_macos_identity_paths(identity)
    lock(backend.active_jobs_lock) do
        handle.reaped[] && return
        handle.reaped[] = true
        backend.active_jobs -= 1
        remove_idle_macos_sysv_semaphores_locked(backend)
    end
    return true
end
