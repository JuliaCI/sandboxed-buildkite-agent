## General utilities for dealing with `launchd` on macOS
## Note; this file needs the `buildkite_config.jl` and `mac_seatbelt_config.jl` files both to be defined!

struct LaunchctlConfig
    # The label of the launchctl job, usually "org.julialang.buildkite.$(agent_name)"
    label::String
    # The execution target, usually something like ["/bin/sh", "-c", "foo"]
    target::Vector{String}

    # Environment variables to set
    env::Dict{String,String}

    # Working directory
    cwd::Union{String,Nothing}

    # File that would contain `stdout` and `stderr`
    logpath::Union{String,Nothing}

    # Whether the job should be restarted after it dies
    keepalive::Union{Bool,Nothing}

    function LaunchctlConfig(label, target; env = Dict{String,String}(), cwd = nothing, logpath = nothing, keepalive = true)
        return new(label, target, env, cwd, logpath, keepalive)
    end
end

# Generate the XML representation of the `LaunchctlConfig` object
function write(io::IO, config::LaunchctlConfig)
    println(io, """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    """)

    # Job label, e.g. "org.julialang.buildkite.solstice-default.0"
    println(io, """
        <key>Label</key>
        <string>$(config.label)</string>
    """)

    # Target process to launch
    print(io, """
        <key>ProgramArguments</key>
            <array>
    """)
    for word in config.target
        println(io, "            <string>$(word)</string>")
    end
    println(io, """
            </array>
    """)

    # We always want these things to be run at load
    println(io, """
        <key>RunAtLoad</key>
        <true />
    """)

    # If we've been asked to print a keepalive
    if config.keepalive !== nothing
        println(io, """
            <key>KeepAlive</key>
            <$(config.keepalive) />
        """)
    end

    if config.cwd !== nothing
        println(io, """
            <key>WorkingDirectory</key>
            <string>$(config.cwd)</string>
        """)
    end

    if config.logpath !== nothing
        println(io, """
            <key>StandardOutPath</key>
            <string>$(config.logpath)</string>
            <key>StandardErrorPath</key>
            <string>$(config.logpath)</string>
        """)
    end

    # Write out environment variables path
    print(io, """
        <key>EnvironmentVariables</key>
        <dict>
    """)
    for (k, v) in config.env
        println(io, """
                <key>$(k)</key>
                <string>$(v)</string>
        """)
    end
    println(io, """
        </dict>
    </dict></plist>
    """)
end
