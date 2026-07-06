# Shared domain model: the types and abstract interfaces that the job sources
# (buildkite.jl), the backends (backends/*.jl), and the scheduler (scheduler.jl)
# all build on.  Scheduler-private types (Assignment, Scheduler) live in
# scheduler.jl alongside their methods.

abstract type JobSource end
abstract type PlatformBackend end

struct Job
    id::String
    pipeline_id::Union{String,Nothing}
    agent_query_rules::Vector{String}
end

struct Slot
    brg::BuildkiteRunnerGroup
    index::Int
    name::String
end

function Slot(brg::BuildkiteRunnerGroup, index::Int)
    return Slot(brg, index, string(brg.name, "-", get_short_hostname(), ".", index))
end

struct CachePlan
    cache_pool::String
    ccache_pool::Union{String,Nothing}
    trust::Symbol
    pipeline::String
end

# Per-job backend log location; `bk logs` relies on this layout.
job_log_path(logdir::AbstractString, agent_name::AbstractString, job::Job) =
    joinpath(logdir, agent_name, "$(safe_path_component(job.id, "unknown-job")).log")

job_start_banner(job::Job, plan::CachePlan) =
    "Starting Buildkite job $(job.id) in $(plan.pipeline)/$(plan.trust)"

struct JobPollResult
    jobs::Vector{Job}
    paused::Bool
end

struct ReservationResult
    reserved::Vector{String}
    not_reserved::Vector{String}
end

prepare(::PlatformBackend, slot::Slot, job::Job, plan::CachePlan, alloc) =
    error("backend does not implement prepare")

check_config(::PlatformBackend, brgs::Vector{BuildkiteRunnerGroup}) = nothing

setup_config!(backend::PlatformBackend, brgs::Vector{BuildkiteRunnerGroup}) =
    check_config(backend, brgs)

setup_backend!(::PlatformBackend, slots) = nothing

run_job(handle, deadline::Union{Nothing,Float64}=nothing) =
    error("backend handle does not implement run_job")

reap(handle) = nothing

cleanup(::PlatformBackend) = nothing
