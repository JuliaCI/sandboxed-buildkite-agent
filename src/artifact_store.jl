#
# Artifact store
#
# A host-wide, read-only Julia depot (see "Artifact store" in the README).
# Runner groups that set `artifact_store` see its depot after the job's own
# depot (on Linux mounted at `/artifact-store`, on macOS at its own path), so
# Pkg finds these artifacts there instead of downloading a copy into every
# cache pool.
#
# What goes in is decided by demand: an artifact that at least
# `ARTIFACT_STORE_MIN_POOLS` pools of the store's groups hold, of any trust
# level. Pools are only counted, never copied from: the scheduler downloads the
# artifact by its tree hash from the Pkg server and verifies that hash, so a
# pull request can at most make the store hold a public artifact.
#
#     <store>/depot/                      read-only to jobs
#     <store>/depot/artifacts/<tree hash>/
#     <store>/sizes/<tree hash>           disk usage of the entry, in bytes
#     <store>/staging/                    downloads in progress
#     <store>/.sba-trash/                 evicted entries, being removed
#
# Entries are added by a rename of a verified tree, so a job sees an artifact
# either complete or not at all. Once the store is over its budget, the oldest
# are evicted while no job that can see the store runs. Idle pools of the
# store's groups lose their copies of what the store holds.
#

const ARTIFACT_STORE_MOUNT = "/artifact-store"
const ARTIFACT_STORE_SERVER = "https://pkg.julialang.org"
const ARTIFACT_STORE_MIN_POOLS = 3
# Eviction brings a store over its budget down to this fraction of it.
const ARTIFACT_STORE_LOW = 0.8
const ARTIFACT_STORE_INTERVAL = 15 * 60.0
# A failed import, such as of an artifact the Pkg server does not have, is not
# retried before this.
const ARTIFACT_IMPORT_RETRY = 24 * 60 * 60.0
# A download that takes longer than this is killed.
const ARTIFACT_IMPORT_TIMEOUT = 60 * 60.0

artifact_store_depot(store::AbstractString) = joinpath(store, "depot")
artifact_store_path(store::AbstractString, tree_hash::AbstractString) =
    joinpath(artifact_store_depot(store), "artifacts", tree_hash)
artifact_store_staging(store::AbstractString) = joinpath(store, "staging")
artifact_store_sizes(store::AbstractString) = joinpath(store, "sizes")

is_tree_hash(name::AbstractString) = occursin(r"^[0-9a-f]{40}$", name)

# The `artifacts` directories of the Julia depots that julia-buildkite-plugin
# keeps (one per pipeline) in a pool of `brg`: below `XDG_CACHE_HOME`, except
# on macOS, where the pool is the plugin's `cache_dir` (see `build_seatbelt_env`).
# Jobs write these directories: no link is followed on the way down.
function pool_artifact_dirs(brg, pool::AbstractString)
    depots = brg.backend == BACKEND_MACOS_SEATBELT ? joinpath(pool, "depots") :
        joinpath(pool, "julia-buildkite-plugin", "depots")
    is_real_dir(dirname(depots)) || return String[]
    return [joinpath(depots, depot, "artifacts") for depot in readdir_or_empty(depots)
            if is_real_dir(joinpath(depots, depot))]
end

"""
    artifact_demand(brgs, store; hostname)

For each artifact in a pool of a group that uses `store`, the number of such
pools that hold it. Only names are read from the pools.
"""
function artifact_demand(brgs, store::AbstractString; hostname::AbstractString=get_short_hostname())
    groups = Dict(brg.name => brg for brg in brgs if brg.artifact_store == store)
    demand = Dict{String,Int}()
    for root in unique(cachedir(brg) for brg in values(groups))
        for pool in main_pools(root, slot_caps(brgs); hostname)
            parsed = parse_slot_name(pool.slot, hostname)
            parsed !== nothing && haskey(groups, first(parsed)) || continue
            # A job can make its pool unreadable; that pool is not counted.
            hashes = try
                Set(hash for dir in pool_artifact_dirs(groups[first(parsed)], pool.path)
                    for hash in readdir_or_empty(dir) if is_tree_hash(hash))
            catch err
                @warn("Unable to list the artifacts of a cache pool", pool=pool.path,
                    exception=(err, catch_backtrace()), maxlog=1, _id=(:demand, pool.path))
                continue
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

# The store's entries, with their disk usage as recorded when they were imported.
function artifact_store_entries(store::AbstractString)
    sizes = artifact_store_sizes(store)
    return Dict(hash => something(tryparse(Int, read(joinpath(sizes, hash), String)), 0)
                for hash in readdir(sizes)
                if is_tree_hash(hash) && path_exists(artifact_store_path(store, hash)))
end

artifact_store_bytes(store::AbstractString) = sum(values(artifact_store_entries(store)); init=0)

artifact_stores(brgs) =
    sort(unique(brg.artifact_store for brg in brgs if brg.artifact_store !== nothing))

# Creates the store's directories, and checks that an entry can be renamed
# from staging into the depot, and from there into the trash.
function prepare_artifact_store(store::AbstractString)
    artifacts = joinpath(artifact_store_depot(store), "artifacts")
    dirs = (artifact_store_staging(store), artifacts, artifact_store_sizes(store), trash_dir(store))
    mkpath.(dirs)
    allequal(stat(dir).device for dir in dirs) ||
        error("The artifact store's directories are on different filesystems")
    return artifacts
end

# Per store, for the metrics: the bytes it holds, and the artifacts in demand
# that it lacks (not yet imported, over budget, above high water, or failed),
# updated before a pass and after each import.
const ARTIFACT_STORE_STATUS = Dict{String,@NamedTuple{bytes::Int, not_promoted::Int}}()
# When an import of a tree hash into a store last failed.
const ARTIFACT_IMPORT_FAILURES = Dict{Tuple{String,String},Float64}()

# Remove an idle pool's copies of the artifacts its group's store holds: its
# jobs find them in the store. The caller holds the retention lock and has
# checked that no job holds the pool.
function prune_stored_artifacts_locked!(retention::CacheRetention, pool::CachePool, groups)
    parsed = parse_slot_name(pool.slot)
    brg = parsed === nothing ? nothing : get(groups, first(parsed), nothing)
    brg === nothing && return nothing
    store = brg.artifact_store
    try
        for dir in pool_artifact_dirs(brg, pool.path), hash in readdir_or_empty(dir)
            is_tree_hash(hash) && path_exists(artifact_store_path(store, hash)) || continue
            move_to_trash!(retention, joinpath(dir, hash), pool.root)
            retention.pruned += 1
        end
    catch err
        @warn("Unable to remove stored artifacts from a cache pool", pool=pool.path,
            exception=(err, catch_backtrace()), maxlog=1, _id=(:prune, pool.path))
    end
    return nothing
end

# Entries evicted from each store since the scheduler started.
const ARTIFACT_STORE_EVICTIONS = Dict{String,Int}()

# The group of a slot's pool (`<cachedir>/<slot>/<pipeline>/<trust>`), if any.
function pool_group(pool::AbstractString)
    parsed = parse_slot_name(basename(dirname(dirname(pool))))
    return parsed === nothing ? nothing : first(parsed)
end

"""
    evict_artifact_store!(scheduler, store, demand; budget)

Once the store's entries use more than `budget` bytes, evict entries until they
use at most `ARTIFACT_STORE_LOW` of it: first those `demand` (from
`artifact_demand`) would not import, then the others, oldest import first. Only
while no job of a group using the store holds a cache pool. Then remove the
store's trash. Returns the evicted tree hashes.
"""
function evict_artifact_store!(scheduler, store::String, demand::AbstractDict{String,Int};
                               budget::Integer)
    retention = scheduler.retention
    sizes = artifact_store_sizes(store)
    groups = Set(brg.name for brg in scheduler.brgs if brg.artifact_store == store)
    wanted(hash) = get(demand, hash, 0) >= ARTIFACT_STORE_MIN_POOLS
    bytes = 0
    evicted = String[]
    try
        prepare_artifact_store(store)
        entries = artifact_store_entries(store)
        bytes = sum(values(entries); init=0)
        bytes > budget || return evicted
        order = last.(sort!([(wanted(hash), mtime(joinpath(sizes, hash)), hash)
                             for hash in keys(entries)]))
        # Held from the idle check through the last rename: a job may read any
        # entry, and needs this lock to get its pool.
        lock(retention.lock) do
            if any(pool -> pool_group(pool) in groups, keys(retention.leased))
                @info("Artifact store is over its budget; evicting once no job uses it",
                    store, bytes, budget)
                return
            end
            for hash in order
                bytes <= ARTIFACT_STORE_LOW * budget && break
                move_to_trash!(retention, artifact_store_path(store, hash), store)
                push!(evicted, hash)
                bytes -= entries[hash]
                rm(joinpath(sizes, hash); force=true)
            end
        end
        if any(wanted, evicted)
            @warn("Evicting the artifact store to 80% of its budget removed artifacts in demand",
                store, budget, demanded_bytes=sum(size for (hash, size) in entries if wanted(hash)))
        end
    finally
        if !isempty(evicted)
            ARTIFACT_STORE_EVICTIONS[store] = get(ARTIFACT_STORE_EVICTIONS, store, 0) + length(evicted)
            @info("Evicted artifacts from the artifact store", store, evicted=length(evicted),
                bytes, budget)
        end
        trash = trash_dir(store)
        for name in readdir_or_empty(trash)
            retention.remove_tree(joinpath(trash, name)) ||
                @warn("Unable to remove evicted artifacts; retrying later", path=joinpath(trash, name))
        end
    end
    return evicted
end

"""
    fill_artifact_store!(scheduler, store, demand; budget, skip, import_artifact)

Import the artifacts that `demand` (from `artifact_demand`) puts in at least
`ARTIFACT_STORE_MIN_POOLS` pools and the store lacks, except those in `skip`,
most demanded first, one at a time, while the store is under `budget` and its
filesystem below its high-water mark.
"""
function fill_artifact_store!(scheduler, store::String, demand::AbstractDict{String,Int};
                              budget::Integer, skip=(),
                              import_artifact::Function=import_artifact)
    artifacts = prepare_artifact_store(store)
    wanted = sort!([hash for (hash, pools) in demand
                    if pools >= ARTIFACT_STORE_MIN_POOLS && !path_exists(artifact_store_path(store, hash))];
                   by=hash -> (-demand[hash], hash))
    record_status() = ARTIFACT_STORE_STATUS[store] = (; bytes=artifact_store_bytes(store),
        not_promoted=count(hash -> !path_exists(artifact_store_path(store, hash)), wanted))
    record_status()
    for hash in wanted
        hash in skip && continue
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

# Evict, then import what is in demand, except what was just evicted.
function artifact_store_pass!(scheduler, store::String; budget::Integer, kwargs...)
    demand = artifact_demand(scheduler.brgs, store)
    skip = evict_artifact_store!(scheduler, store, demand; budget)
    return fill_artifact_store!(scheduler, store, demand; budget, skip, kwargs...)
end

function artifact_store_forever!(scheduler, stores::Vector{String};
                                 interval::Real=ARTIFACT_STORE_INTERVAL)
    atexit() do
        ARTIFACT_IMPORTS_STOPPED[] = true
        proc = ARTIFACT_IMPORT[]
        proc === nothing || kill_artifact_import(proc)
    end
    # Downloads a previous scheduler left behind; the scheduler is the only writer.
    budget = gib_bytes(scheduler.retention.config.artifact_store_budget_gib)
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
                artifact_store_pass!(scheduler, store; budget)
            catch err
                @error("Unable to update the artifact store", store, exception=(err, catch_backtrace()))
            end
        end
        sleep(interval)
    end
end
