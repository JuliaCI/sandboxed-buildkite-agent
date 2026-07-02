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


function generate_buildkite_seatbelt_config(io::IO, workspaces::Vector{String}, temp_dir::String)
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
                "ipc-posix-sem", "ipc-sysv-shm", "ipc-posix-shm",

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

struct MacSeatbeltBackend <: PlatformBackend
    logdir::String
end

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

        if brg.num_cpus != 0
            error("macOS runner group '$(brg.name)' sets num_cpus=$(brg.num_cpus), but CPU pinning is not supported on macOS")
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
    check_caffeinated()
    return nothing
end

function setup_macos_host_config!()
    setup_xcode_path!()
    setup_homebrew_tools!()
    setup_xcode_license_accepted!()
    setup_caffeinated!()
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

function build_seatbelt_env(temp_path::String, cache_path::String;
                            agent_token_path::String,
                            julia_arch::Union{String,Nothing}=nothing)
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
        "PATH" => join(paths, ":"),
        "TERM" => "screen",
    )
    julia_arch === nothing || (env["BUILDKITE_PLUGIN_JULIA_ARCH"] = julia_arch)
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

function seatbelt_setup(f::Function, brg::BuildkiteRunnerGroup;
                        backend::MacSeatbeltBackend,
                        agent_name::String,
                        cache_path::String,
                        temp_path::String,
                        agent_token_path::String=joinpath(secrets_dir(brg), "buildkite-agent-token"))
    force_delete.(host_paths_to_cleanup(backend, temp_path, cache_path))
    mkpath.(host_paths_to_create(backend, temp_path, cache_path))
    seatbelt_env = build_seatbelt_env(temp_path, cache_path;
        agent_token_path=agent_token_path,
        julia_arch=brg.tags["arch"])

    try
        cd(joinpath(cache_path, "build")) do
            with_seatbelt(generate_buildkite_seatbelt_config, [cache_path], temp_path) do sb_path
                if brg.verbose
                    run(`cat $(sb_path)`)
                    println()
                    println()
                end
                f(sb_path, seatbelt_env)
            end
        end
    finally
        force_delete.(host_paths_to_cleanup(backend, temp_path, cache_path))
    end
end

struct MacSeatbeltHandle
    backend::MacSeatbeltBackend
    slot::Slot
    job::Job
    plan::CachePlan
    agent_name::String
    temp_path::String
    log_path::String
end

function prepare(backend::MacSeatbeltBackend, slot::Slot, job::Job, plan::CachePlan)
    if plan.ccache_pool !== nothing
        error("macOS seatbelt backend does not support shared ccache pools")
    end

    mkpath(plan.cache_pool)
    agent_name = slot.name
    temp_path = joinpath(tempdir(slot.brg), "agent-tempdirs", agent_name)
    log_path = job_log_path(backend.logdir, agent_name, job)
    mkpath(dirname(log_path))
    return MacSeatbeltHandle(backend, slot, job, plan, agent_name, temp_path, log_path)
end

function run_job(handle::MacSeatbeltHandle, deadline::Union{Nothing,Float64}=nothing)
    brg = handle.slot.brg
    return seatbelt_setup(brg;
        backend=handle.backend,
        agent_name=handle.agent_name,
        cache_path=handle.plan.cache_pool,
        temp_path=handle.temp_path,
    ) do sb_path, seatbelt_env
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
            acquire_job_id=handle.job.id,
        )

        open(handle.log_path, "a") do log
            println(log, job_start_banner(handle.job, handle.plan))
            proc = run(pipeline(setenv(`sandbox-exec -f $(sb_path) $(cmd)`, seatbelt_env);
                stdout=log,
                stderr=log,
            ); wait=false)
            return wait_process_exit(proc, deadline,
                "running macOS seatbelt job $(handle.job.id)")
        end
    end
end
