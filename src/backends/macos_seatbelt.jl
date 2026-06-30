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

    # Whether we should try getting debug output (doesn't work on modern macOS versions)
    debug::Bool

    function MacOSSeatbeltConfig(;rules::Vector{<:SeatbeltRule} = SeatbeltRule[],
                                 parent_config::Union{Nothing,String} = "bsd.sb",
                                 debug::Bool = true,
                                )
        return new(parent_config, rules, debug)
    end
end

function generate_seatbelt_config(io::IO, config::MacOSSeatbeltConfig)
    # First, print out the header:
    print(io, """
    (version 1)
    (deny default)
    """)

    if config.debug
        println(io, "(debug deny)")
    end

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

backend_name(::MacSeatbeltBackend) = BACKEND_MACOS_SEATBELT

function check_homebrew_tools()
    tools = [
        "bash",
        "gpg",
        "jq",
        "shyaml",
        "openssl@3",
        "zstd",
        "awscli",
        "htop",
    ]
    missing_tools = String[]
    for tool in tools
        if !success(pipeline(`brew list $(tool)`, Base.devnull, Base.devnull))
            push!(missing_tools, tool)
        end
    end
    if !isempty(missing_tools)
        @warn("Missing Homebrew tools found, auto-installing...")
        run(`brew install $(missing_tools)`)

        for tool in tools
            if !success(pipeline(`brew list $(tool)`, Base.devnull, Base.devnull))
                error("Unable to auto-install '$(tool)'")
            end
        end
    end
end

function check_caffeinated()
    plist_path = joinpath(expanduser("~"), "Library", "LaunchAgents", "org.julialang.caffeinate.plist")
    if !isfile(plist_path)
        @info("Generating caffeinate service to prevent sleep")
        lctl_config = LaunchctlConfig(
            "org.julialang.caffeinate",
            ["/usr/bin/caffeinate", "-disu"];
            env=Dict("PATH" => "/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"),
            cwd=expanduser("~"),
            keepalive=true,
        )
        mkpath(dirname(plist_path))
        open(plist_path, write=true) do io
            write(io, lctl_config)
        end

        run(ignorestatus(`launchctl unload -w $(plist_path)`))
        run(`launchctl load -w $(plist_path)`)
    end
end

function check_xcode_path()
    xcode_path = strip(String(read(`xcode-select -p`)))
    return ispath(joinpath(xcode_path, "usr", "bin", "altool"))
end

function check_xcode_license_accepted()
    if !success(`xcodebuild -license check`)
        @info("Accepting Xcode license, may ask for sudo password")
        run(`sudo xcodebuild -license accept`)
    end
end

function get_macos_version()
    plist_lines = split(String(read("/System/Library/CoreServices/SystemVersion.plist")), "\n")
    vers_idx = findfirst(l -> occursin("ProductVersion", l), plist_lines)
    vers_idx === nothing && return nothing

    m = match(r">([\d\.]+)<", plist_lines[vers_idx+1])
    m === nothing && return nothing

    return VersionNumber(only(m.captures))
end

function check_macos_seatbelt_configs(brgs::Vector{BuildkiteRunnerGroup})
    macos_version = get_macos_version()
    if macos_version === nothing
        error("Refusing to start without knowing what macOS version we're running under!")
    end

    for brg in brgs
        check_secret_permissions(secrets_dir(brg))

        if configured_tempdir(brg) === nothing
            error("Refusing to start up macOS runner with default tempdir!")
        end

        if brg.num_cpus != 0
            error("macOS runner group '$(brg.name)' sets num_cpus=$(brg.num_cpus), but CPU pinning is not supported on macOS")
        end

        brg.tags["macos_version"] = "$(macos_version.major).$(macos_version.minor)"
    end

    if !check_xcode_path()
        @warn("Invalid `xcode-select` path, resetting, may ask for sudo password")
        run(`sudo xcode-select -r`)
        if !check_xcode_path()
            error("Unable to reset to valid `xcode-select` path!  Do you need to install Xcode.app?")
        end
    end

    check_homebrew_tools()
    check_xcode_license_accepted()
    try
        setup_coredumps()
    catch err
        @warn("Unable to configure coredumps; continuing without coredump setup",
            exception=(err, catch_backtrace()))
    end
    check_caffeinated()
end

check_config(::MacSeatbeltBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    check_macos_seatbelt_configs(brgs)

function build_seatbelt_env(temp_path::String, cache_path::String;
                            agent_token_path::String=repo_path("agent", "secrets", "buildkite-agent-token"))
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
    return Dict(
        "TMPDIR" => joinpath(temp_path, "tmp"),
        "HOME" => joinpath(temp_path, "home"),
        "BUILDKITE_BIN_PATH" => artifact"buildkite-agent",
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR" => cache_path,
        "BUILDKITE_AGENT_TOKEN" => String(chomp(String(read(agent_token_path)))),
        "PATH" => join(paths, ":"),
        "TERM" => "screen",
    )
end

function macos_buildkite_agent_start_command(brg::BuildkiteRunnerGroup;
                                             agent_name::String,
                                             cache_path::String,
                                             acquire_job_id::Union{String,Nothing}=nothing)
    agent_path = artifact"buildkite-agent/buildkite-agent"
    hooks_path = repo_path("agent", "hooks")
    args = String[
        agent_path,
        "start",
        "--hooks-path=$(hooks_path)",
        "--build-path=$(cache_path)/build",
        "--plugins-path=$(cache_path)/plugins",
        "--experiment=resolve-commit-after-checkout",
        "--git-mirrors-path=$(cache_path)/repos",
        "--git-fetch-flags=-v --prune --tags",
        "--tags=$(buildkite_agent_tags(brg))",
        "--name=$(agent_name)",
    ]

    if acquire_job_id === nothing
        insert!(args, 3, "--disconnect-after-job")
    else
        insert!(args, 3, "--acquire-job=$(acquire_job_id)")
    end

    return Cmd(args)
end

function agent_start_command(::MacSeatbeltBackend, brg::BuildkiteRunnerGroup; kwargs...)
    return macos_buildkite_agent_start_command(brg; kwargs...)
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

default_agent_name(::MacSeatbeltBackend, brg::BuildkiteRunnerGroup) =
    string(brg.name, "-", get_short_hostname(), ".1")

function seatbelt_setup(f::Function, brg::BuildkiteRunnerGroup;
                        backend::MacSeatbeltBackend=MacSeatbeltBackend(""),
                        agent_name::String=default_agent_name(backend, brg),
                        cache_path::String=joinpath(@get_scratch!("agent-cache"), agent_name),
                        temp_path::String=joinpath(tempdir(brg), "agent-tempdirs", agent_name),
                        agent_token_path::String=joinpath(secrets_dir(brg), "buildkite-agent-token"))
    force_delete.(host_paths_to_cleanup(backend, temp_path, cache_path))
    mkpath.(host_paths_to_create(backend, temp_path, cache_path))
    seatbelt_env = build_seatbelt_env(temp_path, cache_path; agent_token_path)

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
    log_path = joinpath(backend.logdir, agent_name, "$(safe_path_component(job.id, "unknown-job")).log")
    mkpath(dirname(log_path))
    return MacSeatbeltHandle(backend, slot, job, plan, agent_name, temp_path, log_path)
end

function run_job(handle::MacSeatbeltHandle)
    brg = handle.slot.brg
    return seatbelt_setup(brg;
        backend=handle.backend,
        agent_name=handle.agent_name,
        cache_path=handle.plan.cache_pool,
        temp_path=handle.temp_path,
    ) do sb_path, seatbelt_env
        cmd = agent_start_command(handle.backend, brg;
            agent_name=handle.agent_name,
            cache_path=handle.plan.cache_pool,
            acquire_job_id=handle.job.id,
        )

        open(handle.log_path, "a") do log
            println(log, "Starting Buildkite job $(handle.job.id) in $(handle.plan.pipeline)/$(handle.plan.trust)")
            proc = run(pipeline(setenv(`sandbox-exec -f $(sb_path) $(cmd)`, seatbelt_env);
                stdout=log,
                stderr=log,
            ); wait=false)
            wait(proc)
            return proc.exitcode
        end
    end
end
