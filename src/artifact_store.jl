#
# Artifact store
#
# A host-wide, read-only Julia depot (see "Artifact store" in the README).
# Runner groups that set `artifact_store` see its depot at `/artifact-store`,
# after the job's own depot, so Pkg finds these artifacts there instead of
# downloading a copy into every cache pool.
#
# What goes in is decided by demand: an artifact that at least
# `ARTIFACT_STORE_MIN_POOLS` protected pools of the store's groups hold. Pools
# are only counted, never copied from: the scheduler downloads the artifact by
# its tree hash from the Pkg server and verifies that hash, since jobs of every
# pipeline and trust level read the store.
#
#     <store>/depot/                      mounted read-only at /artifact-store
#     <store>/depot/artifacts/<tree hash>/
#     <store>/sizes/<tree hash>           disk usage of the entry, in bytes
#     <store>/staging/                    downloads in progress
#
# Entries are only ever added, each by a rename of a verified tree, so a job
# sees an artifact either complete or not at all. Nothing removes them.
#

const ARTIFACT_STORE_MOUNT = "/artifact-store"
const ARTIFACT_STORE_SERVER = "https://pkg.julialang.org"
const ARTIFACT_STORE_MIN_POOLS = 3
# No import starts once the store holds this much (the last one may overshoot
# by its own size); there is no eviction.
const ARTIFACT_STORE_BUDGET = 100 * 2^30
const ARTIFACT_STORE_INTERVAL = 15 * 60.0
# A failed import, such as of an artifact the Pkg server does not have, is not
# retried before this.
const ARTIFACT_IMPORT_RETRY = 24 * 60 * 60.0
# A download that takes longer than this is killed.
const ARTIFACT_IMPORT_TIMEOUT = 60 * 60.0
# Where julia-buildkite-plugin keeps its depots (one per pipeline) in a pool.
const PLUGIN_DEPOTS = joinpath("julia-buildkite-plugin", "depots")

artifact_store_depot(store::AbstractString) = joinpath(store, "depot")
artifact_store_path(store::AbstractString, tree_hash::AbstractString) =
    joinpath(artifact_store_depot(store), "artifacts", tree_hash)
artifact_store_staging(store::AbstractString) = joinpath(store, "staging")
artifact_store_sizes(store::AbstractString) = joinpath(store, "sizes")

is_tree_hash(name::AbstractString) = occursin(r"^[0-9a-f]{40}$", name)

"""
    artifact_demand(brgs, store; hostname)

For each artifact in a protected pool of a group that uses `store`, the number
of such pools that hold it. Only names are read from the pools.
"""
function artifact_demand(brgs, store::AbstractString; hostname::AbstractString=get_short_hostname())
    groups = Set(brg.name for brg in brgs if brg.artifact_store == store)
    demand = Dict{String,Int}()
    for root in unique(cachedir(brg) for brg in brgs if brg.name in groups)
        for pool in main_pools(root, slot_caps(brgs); hostname)
            parsed = parse_slot_name(pool.slot, hostname)
            pool.trust == "protected" && parsed !== nothing && first(parsed) in groups || continue
            # Jobs write these directories: follow no links on the way down.
            hashes = Set{String}()
            depots = joinpath(pool.path, PLUGIN_DEPOTS)
            is_real_dir(dirname(depots)) || continue
            for depot in readdir_or_empty(depots)
                is_real_dir(joinpath(depots, depot)) || continue
                union!(hashes, filter(is_tree_hash, readdir_or_empty(joinpath(depots, depot, "artifacts"))))
            end
            for hash in hashes
                demand[hash] = get(demand, hash, 0) + 1
            end
        end
    end
    return demand
end

# Run in a child process, so that unpacking and hashing gigabytes stay off the
# scheduler's tasks. Its only depot is the staging one, so neither an override
# nor an artifact elsewhere on the host can stand in for the download. It
# records the tree's disk usage next to the depot.
const ARTIFACT_IMPORT_SCRIPT = """
    using Pkg
    tree_hash, url, depot = ARGS
    empty!(DEPOT_PATH)
    push!(DEPOT_PATH, depot)
    result = Pkg.Artifacts.download_artifact(Base.SHA1(tree_hash), url; quiet_download=true)
    result === true || throw(result isa Exception ? result : ErrorException(repr(result)))
    bytes = sum(walkdir(joinpath(depot, "artifacts", tree_hash)); init=0) do (root, dirs, files)
        sum(name -> lstat(joinpath(root, name)).blocks * 512, [dirs; files]; init=0)
    end
    write(joinpath(depot, "size"), string(bytes))
    """

function artifact_import_command(tree_hash::AbstractString, url::AbstractString,
                                 staging::AbstractString)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    depot = joinpath(staging, "depot")
    idle = Sys.islinux() ? `nice -n 19 ionice -c 3` : `nice -n 19`
    cmd = `$(idle) $(julia) --startup-file=no --history-file=no -e $(ARTIFACT_IMPORT_SCRIPT)
           $(tree_hash) $(url) $(depot)`
    env = Dict(k => v for (k, v) in ENV if !startswith(k, "JULIA_"))
    env["JULIA_LOAD_PATH"] = "@stdlib"
    env["JULIA_PKG_IGNORE_HASHES"] = "false"
    # Pkg keeps the compressed download in `tempdir()`; in staging, it counts
    # against the store's filesystem and goes away with the rest.
    env["TMPDIR"] = staging
    return setenv(cmd, env)
end

# The running download, killed when the scheduler exits, after which no new
# one starts.
const ARTIFACT_IMPORT = Ref{Union{Nothing,Base.Process}}(nothing)
const ARTIFACT_IMPORTS_STOPPED = Ref(false)

function kill_artifact_import(proc::Base.Process)
    process_running(proc) && kill(proc, Base.SIGKILL)
    wait(proc)
    return nothing
end

"""
    import_artifact(store, tree_hash; server, command, timeout)

Download the artifact `tree_hash` from the Pkg server into staging, verify its
tree hash, and publish it into the store's depot. Returns whether it is in the
store.
"""
function import_artifact(store::AbstractString, tree_hash::AbstractString;
                         server::AbstractString=ARTIFACT_STORE_SERVER,
                         command::Function=artifact_import_command,
                         timeout::Real=ARTIFACT_IMPORT_TIMEOUT)
    dst = artifact_store_path(store, tree_hash)
    path_exists(dst) && return true
    url = "$(server)/artifact/$(tree_hash)"
    # Removed below; an exit-time cleanup of a large tree would delay shutdown.
    staging = mktempdir(artifact_store_staging(store); prefix="import-", cleanup=false)
    proc = nothing
    try
        cmd = pipeline(command(tree_hash, url, staging); stdout=devnull, stderr=stderr)
        ARTIFACT_IMPORTS_STOPPED[] && error("the scheduler is exiting")
        proc = ARTIFACT_IMPORT[] = run_with_secret(cmd, "the download of $(tree_hash)")
        timer = Timer(_ -> process_running(proc) && kill(proc, Base.SIGKILL), timeout)
        try
            wait(proc)
        finally
            close(timer)
        end
        success(proc) || error("the download process failed (exit code $(proc.exitcode), signal $(proc.termsignal))")
        src = joinpath(staging, "depot", "artifacts", tree_hash)
        is_real_dir(src) || error("the download process left no $(src)")
        rename_exact(joinpath(staging, "depot", "size"), joinpath(artifact_store_sizes(store), tree_hash))
        rename_exact(src, dst)
        return true
    catch err
        @error("Unable to import an artifact into the artifact store", store, url,
            exception=(err, catch_backtrace()))
        return false
    finally
        proc === nothing || kill_artifact_import(proc)
        ARTIFACT_IMPORT[] = nothing
        remove_tree(staging) ||
            @error("Unable to remove an artifact store download", path=staging)
    end
end

# The disk usage of the store's entries, as recorded when they were imported.
function artifact_store_bytes(store::AbstractString)
    bytes = 0
    for hash in readdir(artifact_store_sizes(store))
        is_tree_hash(hash) && path_exists(artifact_store_path(store, hash)) || continue
        bytes += something(tryparse(Int, read(joinpath(artifact_store_sizes(store), hash), String)), 0)
    end
    return bytes
end

artifact_stores(brgs) =
    sort(unique(brg.artifact_store for brg in brgs if brg.artifact_store !== nothing))

# Creates the store's directories, and checks that a download can be renamed
# from staging into the depot.
function prepare_artifact_store(store::AbstractString)
    staging = artifact_store_staging(store)
    artifacts = joinpath(artifact_store_depot(store), "artifacts")
    mkpath.((staging, artifacts, artifact_store_sizes(store)))
    stat(staging).device == stat(artifacts).device == stat(artifact_store_sizes(store)).device ||
        error("The artifact store's directories are on different filesystems")
    return artifacts
end

# Per store, for the metrics: the bytes it holds, and the artifacts in demand
# that it lacks (not yet imported, over budget, above high water, or failed),
# updated before a pass and after each import.
const ARTIFACT_STORE_STATUS = Dict{String,@NamedTuple{bytes::Int, not_promoted::Int}}()
# When an import of a tree hash into a store last failed.
const ARTIFACT_IMPORT_FAILURES = Dict{Tuple{String,String},Float64}()

"""
    fill_artifact_store!(scheduler, store, demand; budget, import_artifact)

Import the artifacts that `demand` (from `artifact_demand`) puts in at least
`ARTIFACT_STORE_MIN_POOLS` pools and the store lacks, most demanded first, one
at a time, while the store is under `budget` and its filesystem below its
high-water mark.
"""
function fill_artifact_store!(scheduler, store::String, demand::AbstractDict{String,Int};
                              budget::Integer=ARTIFACT_STORE_BUDGET,
                              import_artifact::Function=import_artifact)
    artifacts = prepare_artifact_store(store)
    wanted = sort!([hash for (hash, pools) in demand
                    if pools >= ARTIFACT_STORE_MIN_POOLS && !path_exists(artifact_store_path(store, hash))];
                   by=hash -> (-demand[hash], hash))
    record_status() = ARTIFACT_STORE_STATUS[store] = (; bytes=artifact_store_bytes(store),
        not_promoted=count(hash -> !path_exists(artifact_store_path(store, hash)), wanted))
    record_status()
    for hash in wanted
        time() < get(ARTIFACT_IMPORT_FAILURES, (store, hash), -Inf) + ARTIFACT_IMPORT_RETRY && continue
        bytes = artifact_store_bytes(store)
        if bytes >= budget
            @warn("Not filling the artifact store: it is over its budget", store, bytes, budget)
            break
        end
        fs = only(filesystems(scheduler.retention, [artifacts]))
        if needs_eviction(fs)
            @warn("Not filling the artifact store: its filesystem is above its high-water mark",
                store, used_percent=round(used_percent(fs.usage); digits=1),
                high_water_percent=fs.limits.high_water_percent)
            break
        end
        if import_artifact(store, hash)
            @info("Added an artifact to the artifact store", store, tree_hash=hash, pools=demand[hash])
        else
            ARTIFACT_IMPORT_FAILURES[(store, hash)] = time()
        end
        record_status()
    end
    return nothing
end

function artifact_store_forever!(scheduler, stores::Vector{String};
                                 interval::Real=ARTIFACT_STORE_INTERVAL)
    atexit() do
        ARTIFACT_IMPORTS_STOPPED[] = true
        proc = ARTIFACT_IMPORT[]
        proc === nothing || kill_artifact_import(proc)
    end
    # Downloads a previous scheduler left behind; the scheduler is the only writer.
    for store in stores
        try
            prepare_artifact_store(store)
            for name in readdir(artifact_store_staging(store))
                startswith(name, "import-") || continue
                remove_tree(joinpath(artifact_store_staging(store), name)) ||
                    error("Unable to remove $(joinpath(artifact_store_staging(store), name))")
            end
        catch err
            @error("Unable to prepare the artifact store", store, exception=(err, catch_backtrace()))
        end
    end
    while true
        for store in stores
            try
                fill_artifact_store!(scheduler, store, artifact_demand(scheduler.brgs, store))
            catch err
                @error("Unable to fill the artifact store", store, exception=(err, catch_backtrace()))
            end
        end
        sleep(interval)
    end
end
