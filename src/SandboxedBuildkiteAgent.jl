module SandboxedBuildkiteAgent

using Base.BinaryPlatforms
using Base64
using Downloads
using JSON
using LazyArtifacts
using LibGit2
using Logging
using Sandbox
using Scratch
using SHA
using TOML

const REPO_ROOT = dirname(@__DIR__)

include("utils.jl")
include("config.jl")
include("service/systemd.jl")
include("service/launchd.jl")
include("host.jl")
include("types.jl")
include("buildkite.jl")
include("scheduler.jl")
include("backends/linux_sandbox.jl")
include("backends/macos_seatbelt.jl")
include("backends/kvm.jl")
include("cli.jl")
include("precompile.jl")

export BuildkiteRunnerGroup, SchedulerConfig, read_config, read_configs, read_scheduler_config
export Job, Slot, CachePlan, JobSource, StacksJobSource
export PlatformBackend, Scheduler, run_scheduler, start_scheduler!, run_once!, run_forever!
export LinuxSandboxBackend, MacSeatbeltBackend, KVMBackend
export main

end
