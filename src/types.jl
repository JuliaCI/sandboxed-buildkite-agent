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
    priority::Int
    # ISO 8601 UTC as Buildkite returns it, so it orders as a string; "" if unknown.
    # `scheduled_at` is the build's: every job of a build has the same one.
    scheduled_at::String
    # When the job's dependencies finished and it could start.
    runnable_at::String
end

Job(id, pipeline_id, agent_query_rules, priority=0, scheduled_at="") =
    Job(id, pipeline_id, agent_query_rules, priority, scheduled_at, "")

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

# Per-job backend log location; `sba logs` relies on this layout.
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

cleanup_config!(::PlatformBackend) = nothing

setup_backend!(::PlatformBackend, slots) = nothing
# A slot made after `setup_backend!`, before its first job: from then on the
# backend's start and stop clean-up covers it too.
slot_created!(::PlatformBackend, slot) = nothing

backend_available(::PlatformBackend, brg::BuildkiteRunnerGroup) = true

# Run the job's agent, until it exits or `deadline`. Right before launching the
# agent, and not earlier, a backend calls `job_token()` for the token the agent
# registers with; it throws if there is none, and the agent must then not start.
run_job(handle, deadline::Union{Nothing,Float64}, job_token::Function) =
    error("backend handle does not implement run_job")

reap(handle) = nothing

# Make a running job end so its runner reaps it. By default, stop the job's
# Buildkite agent ungracefully: it cancels the job and reports `signal_reason:
# agent_stop`. With `force`, kill the job outright. Returns
# - `:stopped`;
# - `:not_acquired`: the backend never committed to launching the agent, and
#   now will not, so Buildkite only holds the job's reservation;
# - `:no_agent`: the agent's launch was committed but no agent runs, as it
#   has not started yet or already exited;
# - `:unconfirmed`: a stop may have been sent, but whether it took is unknown;
# - `:ended`: nothing of the job runs any more (with `force`);
# - `:failed`: the backend could not stop the job, and demonstrably sent
#   nothing.
stop_job(handle; force::Bool=false) = :failed

# Lets a stop keep a job's agent from being launched, and tell whether the
# backend had committed to launching it. A committed launch is no proof the
# agent started, let alone acquired the job.
mutable struct LaunchGate
    lock::ReentrantLock
    committed::Bool
    closed::Bool
end

LaunchGate() = LaunchGate(ReentrantLock(), false, false)

struct StoppedBeforeLaunch <: Exception end
Base.showerror(io::IO, ::StoppedBeforeLaunch) =
    print(io, "the job was stopped before its agent was launched")

# Called by a backend right before it launches the job's agent; throws once the
# gate is closed.
function commit_launch!(gate::LaunchGate)
    lock(gate.lock) do
        gate.closed && throw(StoppedBeforeLaunch())
        gate.committed = true
    end
    return nothing
end

# Whether the launch had been committed; from now on, it will not be.
close_launch_gate!(gate::LaunchGate) = lock(() -> (gate.closed = true; gate.committed), gate.lock)

cleanup(::PlatformBackend) = nothing
