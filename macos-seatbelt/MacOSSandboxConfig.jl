abstract type SandboxResource; end
SandboxResource(res::SandboxResource) = res

struct SandboxPath <: SandboxResource
    path::String
end
SandboxResource(path::AbstractString) = SandboxPath(String(path))
Base.print(io::IO, res::SandboxPath) = print(io, "(path \"$(res.path)\")")

struct SandboxSubpath <: SandboxResource
    path::String
end
Base.print(io::IO, res::SandboxSubpath) = print(io, "(subpath \"$(res.path)\")")

struct SandboxRegex <: SandboxResource
    path::String
end
SandboxResource(path::Regex) = SandboxRegex(path.pattern)
Base.print(io::IO, res::SandboxRegex) = print(io, "(regex #\"$(res.path)\")")

struct SandboxSyscall <: SandboxResource
    name::String
end
Base.print(io::IO, res::SandboxSyscall) = print(io, "(syscall-number $(res.name))")



abstract type SandboxRule; end
struct SandboxGlobalRule <: SandboxRule
    name::String
    mode::String
end
SandboxRule(name::AbstractString, mode::AbstractString = "allow") = SandboxGlobalRule(String(name), String(mode))
Base.print(io::IO, rule::SandboxGlobalRule) = print(io, "($(rule.mode) $(rule.name))")

struct SandboxScopedRule <: SandboxRule
    name::String
    resources::Vector{<:SandboxResource}
    mode::String
end
SandboxRule(name::AbstractString, scopes::Vector{<:SandboxResource}, mode::AbstractString = "allow") = SandboxScopedRule(String(name), scopes, String(mode))
SandboxRule(name::AbstractString, scopes::Vector, mode::AbstractString = "allow") = SandboxRule(String(name), SandboxResource.(scopes), String(mode))
function Base.print(io::IO, rule::SandboxScopedRule)
    println(io, "($(rule.mode) $(rule.name)")
    for resource in rule.resources
        println(io, "    $(resource)")
    end
    println(io, ")")
end


struct MacOSSandboxConfig
    # Usually something like `"bsd.sb"`
    parent_config::Union{Nothing,String}

    # List of actions that should be allowed
    rules::Vector{<:SandboxRule}

    # Whether we should try getting debug output (doesn't work on modern macOS versions)
    debug::Bool

    function MacOSSandboxConfig(;rules::Vector{<:SandboxRule} = SandboxRule[],
                                 parent_config::Union{Nothing,String} = "bsd.sb",
                                 debug::Bool = true,
                                )
        return new(parent_config, rules, debug)
    end
end

function generate_sandbox_config(io::IO, config::MacOSSandboxConfig)
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

function with_sandbox(f::Function, sandbox_generator::Function, args...; kwargs...)
    mktempdir() do dir
        sb_path = joinpath(dir, "macos_sandbox.sb")
        open(sb_path, write=true) do io
            sandbox_generator(io, args...; kwargs...)
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