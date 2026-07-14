# Buildkite integration: agent tag/query-rule semantics, trust derivation, and
# the Stacks job-source client.

#
# Agent tags & query-rule matching
#

function buildkite_agent_tags(brg::BuildkiteRunnerGroup)
    tags_with_queues = ["$tag=$value" for (tag, value) in brg.tags]
    append!(tags_with_queues, ["queue=$(queue)" for queue in brg.queues])
    return join(tags_with_queues, ",")
end

function queue_rule(rule::AbstractString)
    rule = strip(rule)
    separator = occursin("!=", rule) ? "!=" : occursin("=", rule) ? "=" : nothing
    separator === nothing && return false
    key, _ = strip.(split(rule, separator; limit=2))
    return key == "queue"
end

function normalized_agent_query_rules(job::Job)
    return [rule for rule in job.agent_query_rules if !queue_rule(rule)]
end

function agent_tags(slot::Slot)
    tags = Dict{String,String}(slot.brg.tags)
    tags["agent.name"] = slot.name
    tags["name"] = slot.name
    return tags
end

# The one place the `buildkite-agent start` invocation is defined; backends
# only vary the binary and the hook/cache/socket locations.  The flags are a
# contract with julia-buildkite (mirror paths, cancel grace, experiments).
function buildkite_agent_start_command(brg::BuildkiteRunnerGroup;
                                       agent_binary::String,
                                       hooks_path::String,
                                       cache_path::String,
                                       agent_name::String,
                                       acquire_job_id::String,
                                       sockets_path::Union{String,Nothing}=nothing)
    args = String[
        agent_binary,
        "start",
        "--acquire-job=$(acquire_job_id)",
        "--hooks-path=$(hooks_path)",
        "--build-path=$(cache_path)/build",
        "--plugins-path=$(cache_path)/plugins",
        "--experiment=resolve-commit-after-checkout",
        "--git-mirrors-path=$(cache_path)/repos",
        "--git-fetch-flags=-v --prune --tags",
        "--cancel-grace-period=300",
        "--tags=$(buildkite_agent_tags(brg))",
        "--name=$(agent_name)",
    ]
    if sockets_path !== nothing
        push!(args, "--sockets-path=$(sockets_path)")
    end
    return Cmd(args)
end

function mine(slot::Slot, job::Job)
    tags = agent_tags(slot)
    # Julia's agent rules are positive key/value matches; unsupported negated or bare non-queue rules fail closed.
    for rule in normalized_agent_query_rules(job)
        idx = findfirst('=', rule)
        idx === nothing && return false
        key = strip(rule[begin:prevind(rule, idx)])
        value = strip(rule[nextind(rule, idx):end])
        haskey(tags, key) || return false
        (value == "*" || value == tags[key]) || return false
    end
    return true
end

#
# Job trust
#

function trust_from_env(env::AbstractDict)
    return get(env, "BUILDKITE_PULL_REQUEST", "") == "false" ? :trusted : :untrusted
end

#
# JobSource interface (generic defaults, specialized by StacksJobSource below)
#

function check_source_config(::JobSource)
    return nothing
end

function register_stack(source::JobSource)
    return nothing
end

function deregister_stack(source::JobSource)
    return nothing
end

function poll_result(source::JobSource; dispatch::Bool=true)
    return JobPollResult(poll_jobs(source), false)
end

# No fallbacks for `reserve_jobs` and `get_job_env`: fabricating "reserved" or
# "trusted" answers for a source that forgot to implement them would silently
# run jobs against the wrong cache pool.

function finish_job(source::JobSource, job_id::AbstractString;
                    exit_status::Integer=1,
                    detail::AbstractString="")
    return false
end

#
# Buildkite Stacks API client
#

struct BuildkiteRateLimited <: Exception
    reset_in::Float64
end

# Non-2xx, non-429 Stacks response we don't retry; status splits permanent 4xx
# from transient 5xx.
struct BuildkiteHTTPError <: Exception
    status::Int
    message::String
end
Base.showerror(io::IO, err::BuildkiteHTTPError) = print(io, err.message)

struct StacksTransportError <: Exception
    method::String
    url::String
    error::Exception
end

function Base.showerror(io::IO, err::StacksTransportError)
    print(io, "Buildkite Stacks API ", err.method, " ", err.url, " failed: ")
    showerror(io, err.error)
end

mutable struct StacksJobSource <: JobSource
    brg::BuildkiteRunnerGroup
    stack_key::String
    queue_key::String
    token_path::String
    endpoint::String
    limit::Int
    max_pages::Int
    reservation_expiry_seconds::Int
end

function StacksJobSource(config::SchedulerConfig, brg::BuildkiteRunnerGroup;
                         endpoint::String="https://agent.buildkite.com/v3",
                         limit::Int=100, max_pages::Int=10)
    isempty(brg.queues) && throw(ArgumentError("Runner group '$(brg.name)' has no queue and cannot register a Buildkite stack"))
    return StacksJobSource(
        brg,
        something(stack_key_override(brg), default_stack_key(brg)),
        only(brg.queues),
        joinpath(secrets_dir(brg), "buildkite-agent-token"),
        endpoint,
        limit,
        max_pages,
        config.reservation_expiry_seconds,
    )
end

function default_job_sources(config::SchedulerConfig, brgs::Vector{BuildkiteRunnerGroup})
    return Dict(brg.name => StacksJobSource(config, brg) for brg in brgs if !isempty(brg.queues))
end

function default_stack_key(brg::BuildkiteRunnerGroup)
    key = replace("julia-$(brg.name)-$(get_short_hostname())", r"[^A-Za-z0-9_-]" => "-")
    ncodeunits(key) <= 80 && return key
    digest = bytes2hex(sha1(key))[1:8]
    return string(first(key, 71), "-", digest)
end

function check_source_config(source::StacksJobSource)
    check_secret_file_permissions(source.token_path)
    return nothing
end

function agent_token(source::StacksJobSource)
    return strip(String(read(source.token_path)))
end

function maybe_string(value)
    value === nothing && return nothing
    return string(value)
end

function dict_value(dict, key, default=nothing)
    dict isa AbstractDict || return default
    return get(dict, key, default)
end

function string_vector(value)
    value isa AbstractVector || return String[]
    return [string(v) for v in value]
end

function string_dict(value)
    value isa AbstractDict || return Dict{String,String}()
    return Dict{String,String}(string(k) => string(v) for (k, v) in value)
end

function header_value(headers, name::AbstractString)
    lower_name = lowercase(name)
    for (key, value) in headers
        lowercase(string(key)) == lower_name && return string(value)
    end
    return nothing
end

# How long to back off after a 429, in seconds.
#
# Upstream `buildkite-agent` honors only the `Retry-After` header, parsed as
# relative seconds (`core/client.go`'s `handleRetriableJobAcquisitionError`
# does `time.ParseDuration(retryAfter + "s")`).  We prefer it for the same
# reason, then fall back to the `RateLimit-*Reset` headers that the public REST
# API surfaces.  All three are relative delta-seconds, not an absolute epoch, so
# the value is the backoff duration; just clamp it non-negative.
function rate_limit_reset_seconds(headers)
    value = header_value(headers, "Retry-After")
    value === nothing && (value = header_value(headers, "RateLimit-User-Reset"))
    value === nothing && (value = header_value(headers, "RateLimit-Reset"))
    value === nothing && return 0.0
    reset_in = tryparse(Float64, value)
    reset_in === nothing && return 0.0
    return max(reset_in, 0.0)
end

# Jittered exponential backoff for transient failures (5xx and transport errors).
transient_backoffs(n::Integer) = Base.ExponentialBackOff(;
    n=max(n, 0),
    first_delay=0.25,
    max_delay=10.0,
    factor=2.0,
    jitter=0.25,
)

escape_uri(x) = replace(string(x), r"[^A-Za-z0-9_.~-]" => s -> "%" * uppercase(string(codepoint(only(s)); base=16, pad=2)))
rails_path_escape(x) = replace(escape_uri(x), "." => "%2E")

query_items(query::AbstractDict) = collect(query)
query_items(query) = collect(query)

function encode_query(query)
    params = ["$(escape_uri(k))=$(escape_uri(v))" for (k, v) in query_items(query)]
    return join(params, "&")
end

function stacks_url(source::StacksJobSource, path::AbstractString; query=Pair{String,String}[])
    query_string = encode_query(query)
    endpoint = replace(source.endpoint, r"/+$" => "")
    return string(endpoint, path, isempty(query_string) ? "" : "?", query_string)
end

function error_detail(body::AbstractString)
    isempty(strip(body)) && return ""
    parsed = try
        JSON.parse(body)
    catch
        nothing
    end
    if parsed isa AbstractDict
        for key in ("message", "error", "detail")
            value = dict_value(parsed, key)
            value === nothing || return string(": ", value)
        end
    end
    return string(": ", body)
end

const STACKS_HTTP_POOL = HTTP.Pool(32)
const STACKS_CONNECT_TIMEOUT = 15
const STACKS_READ_TIMEOUT = 60

function stacks_http_request(method::AbstractString, url::AbstractString, headers, body;
                             connect_timeout::Int=STACKS_CONNECT_TIMEOUT,
                             readtimeout::Int=STACKS_READ_TIMEOUT)
    try
        return HTTP.request(method, url, headers, body;
            status_exception=false,
            retry=false,
            cookies=false,
            redirect=false,
            connect_timeout,
            readtimeout,
            pool=STACKS_HTTP_POOL,
        )
    catch err
        err isa HTTP.Exceptions.HTTPError || rethrow()
        throw(StacksTransportError(String(method), String(url), err))
    end
end

function stacks_request(source::StacksJobSource, method::AbstractString, path::AbstractString;
                        query=Pair{String,String}[], payload=nothing, max_attempts::Int=3,
                        sleep_fn=sleep)
    headers = [
        "Authorization" => "Token $(agent_token(source))",
        "Accept" => "application/json",
    ]
    input_payload = nothing
    if payload !== nothing
        push!(headers, "Content-Type" => "application/json")
        input_payload = JSON.json(payload)
    end
    url = stacks_url(source, path; query)
    backoffs = collect(transient_backoffs(max_attempts - 1))

    for attempt in 1:max_attempts
        response = try
            stacks_http_request(method, url, headers,
                something(input_payload, ""))
        catch err
            err isa StacksTransportError || rethrow()
            attempt < max_attempts || throw(err)
            sleep_fn(backoffs[attempt])
            continue
        end
        body_text = String(response.body)

        if response.status == 429
            throw(BuildkiteRateLimited(rate_limit_reset_seconds(response.headers)))
        elseif response.status >= 500 && response.status < 600 && attempt < max_attempts
            sleep_fn(max(rate_limit_reset_seconds(response.headers), backoffs[attempt]))
            continue
        elseif response.status < 200 || response.status >= 300
            throw(BuildkiteHTTPError(response.status,
                "Buildkite Stacks API $(method) $(path) failed with HTTP $(response.status)$(error_detail(body_text))"))
        end

        isempty(strip(body_text)) && return Dict{String,Any}()
        return JSON.parse(body_text)
    end
end

function register_stack(source::StacksJobSource)
    stacks_request(source, "POST", "/stacks/register"; payload=Dict(
        "key" => source.stack_key,
        "type" => "custom",
        "queue_key" => source.queue_key,
        "metadata" => Dict(
            "hostname" => get_short_hostname(),
            "runner_group" => source.brg.name,
            "backend" => source.brg.backend,
        ),
    ))
    @info("Registered Buildkite stack", runner_group=source.brg.name,
        stack_key=source.stack_key, queue=source.queue_key)
    return nothing
end

function deregister_stack(source::StacksJobSource)
    stacks_request(source, "POST", "/stacks/$(rails_path_escape(source.stack_key))/deregister")
    @info("Deregistered Buildkite stack", runner_group=source.brg.name,
        stack_key=source.stack_key, queue=source.queue_key)
    return nothing
end

function scheduled_job_from_json(job)
    job isa AbstractDict || error("Buildkite scheduled job was not a JSON object")
    job_id = dict_value(job, "id")
    job_id === nothing && error("Buildkite scheduled job is missing id")
    pipeline = dict_value(job, "pipeline", Dict())
    return Job(
        string(job_id),
        maybe_string(dict_value(pipeline, "uuid")),
        string_vector(dict_value(job, "agent_query_rules", String[])),
    )
end

function parse_paused(response)
    cluster_queue = dict_value(response, "cluster_queue", Dict())
    return dict_value(cluster_queue, "dispatch_paused", false) === true
end

function list_scheduled_jobs(source::StacksJobSource; limit::Int=source.limit,
                             max_pages::Int=source.max_pages)
    jobs = Job[]
    paused = false
    after = nothing
    for _ in 1:max_pages
        query = Pair{String,String}[
            "queue_key" => source.queue_key,
            "limit" => string(limit),
        ]
        after === nothing || push!(query, "after" => after)
        response = stacks_request(source, "GET",
            "/stacks/$(rails_path_escape(source.stack_key))/scheduled-jobs"; query)
        response isa AbstractDict || error("Buildkite scheduled-jobs response was not a JSON object")
        paused |= parse_paused(response)
        append!(jobs, [scheduled_job_from_json(job) for job in dict_value(response, "jobs", Any[])])

        page_info = dict_value(response, "page_info", Dict())
        has_next_page = dict_value(page_info, "has_next_page", false) === true
        end_cursor = maybe_string(dict_value(page_info, "end_cursor"))
        has_next_page && end_cursor !== nothing || break
        after = end_cursor
    end
    return JobPollResult(jobs, paused)
end

function poll_jobs(source::StacksJobSource)
    return list_scheduled_jobs(source).jobs
end

function poll_result(source::StacksJobSource; dispatch::Bool=true)
    return list_scheduled_jobs(source;
        limit=dispatch ? source.limit : 1,
        max_pages=dispatch ? source.max_pages : 1)
end

function reserve_jobs(source::StacksJobSource, job_ids::Vector{String})
    response = stacks_request(source, "PUT",
        "/stacks/$(rails_path_escape(source.stack_key))/scheduled-jobs/batch-reserve";
        payload=Dict(
            "job_uuids" => job_ids,
            "reservation_expiry_seconds" => source.reservation_expiry_seconds,
        ))
    response isa AbstractDict || error("Buildkite batch-reserve response was not a JSON object")
    return ReservationResult(
        string_vector(dict_value(response, "reserved", String[])),
        string_vector(dict_value(response, "not_reserved", String[])),
    )
end

function get_job(source::StacksJobSource, job_id::AbstractString)
    return stacks_request(source, "GET",
        "/stacks/$(rails_path_escape(source.stack_key))/jobs/$(rails_path_escape(job_id))")
end

function get_job_env(source::StacksJobSource, job_id::AbstractString)
    response = get_job(source, job_id)
    response isa AbstractDict || error("Buildkite job response was not a JSON object")
    env = dict_value(response, "env", Dict())
    env isa AbstractDict || error("Buildkite job response env was not a JSON object")
    return string_dict(env)
end

const STACKS_FINISH_DETAIL_LIMIT = 4 * 1024
const STACKS_FINISH_DETAIL_SUFFIX = "... (detail truncated because it exceeded the max size)"

function truncate_utf8_bytes(text::AbstractString, max_bytes::Integer,
                             suffix::AbstractString=STACKS_FINISH_DETAIL_SUFFIX)
    ncodeunits(text) <= max_bytes && return String(text)
    suffix_text = String(suffix)
    budget = max(Int(max_bytes) - ncodeunits(suffix_text), 0)
    io = IOBuffer()
    used = 0
    for char in text
        chunk = string(char)
        chunk_size = ncodeunits(chunk)
        used + chunk_size > budget && break
        write(io, chunk)
        used += chunk_size
    end
    return String(take!(io)) * suffix_text
end

function finish_job_path(source::StacksJobSource, job_id::AbstractString)
    return "/stacks/$(rails_path_escape(source.stack_key))/jobs/$(rails_path_escape(job_id))/finish"
end

function finish_job_payload(exit_status::Integer, detail::AbstractString)
    return Dict(
        "exit_status" => Int(exit_status),
        "detail" => truncate_utf8_bytes(detail, STACKS_FINISH_DETAIL_LIMIT),
    )
end

function finish_job(source::StacksJobSource, job_id::AbstractString;
                    exit_status::Integer=1,
                    detail::AbstractString="")
    stacks_request(source, "POST", finish_job_path(source, job_id);
        payload=finish_job_payload(exit_status, detail))
    @info("Marked Buildkite job finished",
        runner_group=source.brg.name,
        stack_key=source.stack_key,
        job=job_id,
        exit_status=Int(exit_status))
    return true
end
