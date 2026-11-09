#
# Cache retention
#
# The scheduler owns the cache pools it creates (see "Cache retention" in the
# README): it records when each pool was created and last used, protects pools
# held by a job, and deletes whole idle pools to keep each filesystem below its
# high-water mark, and resets pools once they are older than the maximum age.
# It never measures what is inside a pool (no `du`): filesystem free space is
# the only size it looks at.
#
# Pools, with their stamp files next to them, where no job can write:
#
#     <cachedir>/<slot>/<pipeline>/<trust>/            <trust>.sba-pool
#     <sharedcache>/<pipeline>/<trust>/                <trust>.sba-pool
#
# A deletion renames the directory into `<root>/.sba-trash/` while holding the
# retention lock, which also guards leases, so a pool is either leased or gone,
# never both; the trash is removed later by an `rm` process, off the scheduling
# loop, and whatever a crash leaves there is removed at the next start.
#

const POOL_STAMP_SUFFIX = ".sba-pool"
const TRASH_DIR = ".sba-trash"
# Trust partitions sba creates, and those it once did (before #196) that no
# job uses any more.
const POOL_TRUSTS = ("protected", "untrusted")
const RETIRED_POOL_TRUSTS = ("trusted",)
# Pools expire between (1 - MAX_AGE_STAGGER) and 1 times the maximum age, by a
# hash of their path, so that caches do not all go cold at once.
const MAX_AGE_STAGGER = 0.25
# How often idle pools are checked for their age and slot leftovers removed,
# besides whenever a filesystem needs eviction.
const RETENTION_SWEEP_SECONDS = Ref(10 * 60.0)
# Evictions per pass, so that a filesystem that reclaims space late (ZFS frees
# deleted blocks asynchronously, open files keep theirs) is not emptied.
const MAX_EVICTIONS_PER_PASS = Ref(10)
# How long to wait after removing a pool before measuring free space again.
const EVICTION_SETTLE_SECONDS = Ref(2.0)

# Filesystem usage as `df` reports it: `used` excludes blocks reserved for
# root, which are not `available` either.
struct FsUsage
    device::UInt64
    total::Int
    used::Int
    available::Int
end

used_percent(usage::FsUsage) =
    usage.used + usage.available == 0 ? 0.0 : 100 * usage.used / (usage.used + usage.available)

function fs_usage(path::AbstractString)
    st = diskstat(path)
    bsize = Int(st.bsize)
    return FsUsage(UInt64(stat(path).device), bsize * Int(st.blocks),
        bsize * (Int(st.blocks) - Int(st.bfree)), bsize * Int(st.bavail))
end

struct FsLimits
    high_water_percent::Float64
    low_water_percent::Float64
end

# One filesystem holding scheduler roots, as of the last check.
mutable struct FsState
    label::String
    probe::String
    roots::Vector{String}
    usage::FsUsage
    limits::FsLimits
end

needs_eviction(fs::FsState) = used_percent(fs.usage) > fs.limits.high_water_percent
eviction_done(fs::FsState) = used_percent(fs.usage) <= fs.limits.low_water_percent
# Above high water, or still above low water from an earlier pass.
wants_eviction(retention, fs::FsState) =
    needs_eviction(fs) || (fs.label in retention.evicting && !eviction_done(fs))

struct PoolStamp
    created_at::Float64
    last_used_at::Float64
end

# A cache pool on disk: `slot` is empty for a shared pool.
struct CachePool
    path::String
    root::String
    slot::String
    pipeline::String
    trust::String
end

is_shared(pool::CachePool) = isempty(pool.slot)

mutable struct CacheRetention
    config::RetentionConfig
    # Guards `leased` and every rename of a pool, so that a pool is never
    # handed to a job while it is being deleted.
    lock::ReentrantLock
    # Pools held by jobs, by path, with how many jobs hold each; only shared
    # pools are held by more than one.
    leased::Dict{String,Int}
    # Wakes the cache worker: a pool went to the trash, or a filesystem
    # needs eviction.
    wakeup::Base.Event
    # Replaceable for tests.
    fs_usage::Function
    now::Function
    remove_tree::Function
    rename::Function
    # Filesystems over their high-water mark without an idle pool to evict,
    # which was logged once.
    stuck::Set{String}
    # Filesystems being evicted down to their low-water mark, which may take
    # several passes, with when their last pass hit `MAX_EVICTIONS_PER_PASS`.
    evicting::Set{String}
    capped_at::Dict{String,Float64}
    # Status, from the last check and sweep.
    pools::Int
    evictions::Int
    resets::Int
    leftovers_removed::Int
    removal_failures::Int
    last_check_at::Union{Nothing,Float64}
    last_sweep_at::Union{Nothing,Float64}
    last_error::Union{Nothing,String}
end

CacheRetention(config::RetentionConfig; fs_usage::Function=fs_usage, now::Function=time,
               remove_tree::Function=remove_tree, rename::Function=rename_exact) =
    CacheRetention(config, ReentrantLock(), Dict{String,Int}(), Base.Event(true),
        fs_usage, now, remove_tree, rename, Set{String}(), Set{String}(),
        Dict{String,Float64}(), 0, 0, 0, 0, 0, nothing, nothing, nothing)

#
# Deleting
#

# Unlike `Base.Filesystem.rename`, never falls back to copying.
function rename_exact(src::AbstractString, dst::AbstractString)
    err = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), src, dst)
    err < 0 && Base.uv_error("rename($(repr(src)), $(repr(dst)))", err)
    return nothing
end

is_real_dir(path::AbstractString) = isdir(lstat(path))
path_exists(path::AbstractString) = ispath(lstat(path))

"""
    remove_tree(path)

Remove `path` and everything below it with `rm -rf`, which deletes symbolic
links rather than following them and does not cross into other filesystems,
in a process, so that removing a large tree does not hold up the scheduler.
Directories a job made read-only (Pkg's package sources) or inaccessible
(overlayfs work directories) are made accessible first if needed, by `find`,
which does not follow symbolic links either, and changes each directory before
it descends into it. Returns whether `path` is gone.
"""
function remove_tree(path::AbstractString)
    path_exists(path) || return true
    flags = Sys.islinux() ? ["--one-file-system"] : ["-x"]
    rm_cmd = pipeline(`rm -rf $flags -- $path`; stdout=devnull, stderr=devnull)
    success(rm_cmd) && !path_exists(path) && return true
    success(pipeline(`find $path -type d ! -perm -700 -exec chmod u+rwx '{}' ';'`;
        stdout=devnull, stderr=devnull))
    success(rm_cmd)
    return !path_exists(path)
end

trash_dir(root::AbstractString) = joinpath(root, TRASH_DIR)

# Rename `path` into its root's trash, where nothing uses it any more; the
# caller holds the retention lock. Returns the new path.
function move_to_trash!(retention::CacheRetention, path::AbstractString, root::AbstractString)
    trash = trash_dir(root)
    is_real_dir(trash) || mkdir(trash; mode=0o700)
    dest = joinpath(trash, string(round(Int, retention.now()), "-", basename(path), "-",
        string(rand(UInt32); base=16)))
    retention.rename(path, dest)
    return dest
end

#
# Pools and their stamps
#

pool_stamp_path(pool::AbstractString) = string(pool, POOL_STAMP_SUFFIX)

function read_pool_stamp(pool::AbstractString)
    path = pool_stamp_path(pool)
    st = lstat(path)
    isfile(st) || return nothing
    try
        data = TOML.parsefile(path)
        return PoolStamp(Float64(data["created_at"]), Float64(data["last_used_at"]))
    catch
        return nothing
    end
end

function write_pool_stamp(pool::AbstractString, stamp::PoolStamp)
    write_atomically(pool_stamp_path(pool)) do io
        println(io, "created_at = ", stamp.created_at)
        println(io, "last_used_at = ", stamp.last_used_at)
    end
    return stamp
end

# A pool from before stamps (or whose stamp was lost): last used when its
# newest top-level entry changed, as no job runs without touching one (the
# Linux and macOS backends recreate `build`, KVM writes its cache disk). Its
# creation is unknown; that time is the latest it can have been.
function adopted_pool_stamp(pool::AbstractString, now::Float64)
    is_real_dir(pool) || return PoolStamp(now, now)
    newest = lstat(pool).mtime
    for name in readdir_or_empty(pool)
        newest = max(newest, lstat(joinpath(pool, name)).mtime)
    end
    newest = min(newest, now)
    return PoolStamp(newest, newest)
end

function pool_stamp(pool::AbstractString, now::Float64)
    stamp = read_pool_stamp(pool)
    return stamp === nothing ? adopted_pool_stamp(pool, now) : stamp
end

function pool_expires_at(config::RetentionConfig, pool::AbstractString, stamp::PoolStamp)
    config.max_age_days > 0 || return Inf
    jitter = (Base._crc32c(pool) % 1024) / 1024
    return stamp.created_at + config.max_age_days * 86400 * (1 - MAX_AGE_STAGGER * jitter)
end

# A pool's root: the cachedir above `<slot>/<pipeline>/<trust>`, or the
# sharedcache above `<pipeline>/<trust>`.
pool_root(path::AbstractString; shared::Bool) =
    shared ? dirname(dirname(path)) : dirname(dirname(dirname(path)))

# Delete a pool that no job holds and no running guest uses a disk of; the
# caller holds the retention lock. The cache worker, which removes the trash
# itself, does not `wake` itself.
function discard_pool_locked!(retention::CacheRetention, path::AbstractString;
                              shared::Bool, attached, wake::Bool=true)
    haskey(retention.leased, path) && return nothing
    holds_attached_disk(path, attached) && return nothing
    dest = move_to_trash!(retention, path, pool_root(path; shared))
    rm(pool_stamp_path(path); force=true)
    # `<slot>/<pipeline>` (or `<pipeline>`) once its last pool is gone.
    try
        rm(dirname(path))
    catch
    end
    wake && notify(retention.wakeup)
    return dest
end

struct PoolUnavailable <: Exception
    pool::String
end
Base.showerror(io::IO, err::PoolUnavailable) =
    print(io, "cache pool ", err.pool, " is past its maximum age and could not be reset")

const NO_ATTACHED_DISKS = () -> Set{String}()

"""
    acquire_pools!(retention, plan; attached)

Hold `plan`'s pools for a job until `release_pools!`; no pool is deleted while
held. A pool past its maximum age is reset first (deleted, so the job starts
with an empty one); if that fails, `PoolUnavailable` is thrown and nothing is
held, as an expired pool is never used again. Shared pools are never reset,
and get their ccache size when the first job takes them. `attached()` lists
the disks of running guests (see `attached_guest_disks`), asked only for a
reset. Failures to stamp are logged: a job never fails over those.
"""
function acquire_pools!(retention::CacheRetention, plan::CachePlan;
                        attached::Function=NO_ATTACHED_DISKS)
    acquire_pool!(retention, plan.cache_pool; shared=false, attached)
    plan.ccache_pool === nothing || acquire_pool!(retention, plan.ccache_pool; shared=true)
    return nothing
end

function release_pools!(retention::CacheRetention, plan::CachePlan;
                        attached::Function=NO_ATTACHED_DISKS)
    release_pool!(retention, plan.cache_pool; shared=false, attached)
    plan.ccache_pool === nothing || release_pool!(retention, plan.ccache_pool; shared=true)
    return nothing
end

# Whether `path` will be due for a reset, judged before taking the lock, so
# that `attached()` (libvirt) is not asked while holding it.
function reset_due(retention::CacheRetention, path::AbstractString; shared::Bool)
    retention.config.enabled && !shared || return false
    try
        now = Float64(retention.now())
        return now >= pool_expires_at(retention.config, path, pool_stamp(path, now))
    catch
        return false
    end
end

# `attached()` now if a reset is due, else a function asking it later.
prefetch_attached(retention, path, attached; shared) =
    reset_due(retention, path; shared) ? (disks = attached(); () -> disks) : attached

function acquire_pool!(retention::CacheRetention, path::AbstractString; shared::Bool,
                       attached::Function=NO_ATTACHED_DISKS)
    path = String(path)
    attached = prefetch_attached(retention, path, attached; shared)
    lock(retention.lock) do
        now = Float64(retention.now())
        count = get(retention.leased, path, 0)
        stamp = try
            pool_stamp(path, now)
        catch err
            @warn("Unable to read cache pool stamp", pool=path, exception=(err, catch_backtrace()))
            PoolStamp(now, now)
        end
        if retention.config.enabled && !shared && count == 0 &&
                now >= pool_expires_at(retention.config, path, stamp)
            if path_exists(path)
                dest = try
                    discard_pool_locked!(retention, path; shared, attached=attached())
                catch err
                    @error("Unable to reset cache pool past its maximum age", pool=path,
                        exception=(err, catch_backtrace()))
                    nothing
                end
                dest === nothing && throw(PoolUnavailable(path))
                retention.resets += 1
                @info("Reset cache pool past its maximum age", pool=path,
                    age_days=round((now - stamp.created_at) / 86400; digits=1))
            end
            stamp = PoolStamp(now, now)
        end
        retention.leased[path] = count + 1
        try
            mkpath(dirname(path))
            write_pool_stamp(path, PoolStamp(stamp.created_at, now))
            shared && count == 0 && write_ccache_size(retention.config, path)
        catch err
            @warn("Unable to stamp cache pool", pool=path, exception=(err, catch_backtrace()))
        end
    end
    return nothing
end

function release_pool!(retention::CacheRetention, path::AbstractString; shared::Bool,
                       attached::Function=NO_ATTACHED_DISKS)
    path = String(path)
    attached = prefetch_attached(retention, path, attached; shared)
    lock(retention.lock) do
        count = get(retention.leased, path, 0)
        if count == 0
            @error("Releasing a cache pool that is not held", pool=path)
            return
        end
        count == 1 ? delete!(retention.leased, path) : (retention.leased[path] = count - 1)
        now = Float64(retention.now())
        try
            stamp = pool_stamp(path, now)
            write_pool_stamp(path, PoolStamp(stamp.created_at, now))
            # A pool that expired while it was held is reset now, before its
            # slot can take it again (which would otherwise reset it then).
            if retention.config.enabled && !shared && count == 1 &&
                    now >= pool_expires_at(retention.config, path, stamp) &&
                    discard_pool_locked!(retention, path; shared, attached=attached()) !== nothing
                retention.resets += 1
                @info("Reset cache pool past its maximum age", pool=path,
                    age_days=round((now - stamp.created_at) / 86400; digits=1))
            end
        catch err
            @warn("Unable to stamp cache pool", pool=path, exception=(err, catch_backtrace()))
        end
    end
    return nothing
end

# Bound the shared pool's ccache (`<pool>/ccache`, where pipelines point
# `CCACHE_DIR`), which is never idle long enough to be evicted. Called while
# no job holds the pool, so none can swap in a symbolic link meanwhile; one
# found here is left alone, as is a `max_size` already right.
function write_ccache_size(config::RetentionConfig, pool::AbstractString)
    config.ccache_max_size_gb > 0 || return nothing
    is_real_dir(pool) || mkpath(pool)
    is_real_dir(pool) || return nothing
    dir = joinpath(pool, "ccache")
    path_exists(dir) || mkdir(dir)
    if !is_real_dir(dir)
        @warn("Not setting the shared ccache size: its directory is not a plain directory", path=dir)
        return nothing
    end
    conf = joinpath(dir, "ccache.conf")
    lines = String[]
    st = lstat(conf)
    if islink(st) || (ispath(st) && !isfile(st))
        @warn("Not setting the shared ccache size: its configuration is not a plain file", path=conf)
        return nothing
    end
    isfile(st) && (lines = readlines(conf))
    setting = "max_size = $(config.ccache_max_size_gb)G"
    is_max_size(line) = occursin(r"^\s*max_size\s*=", line)
    any(==(setting), lines) && count(is_max_size, lines) == 1 && return nothing
    filter!(!is_max_size, lines)
    push!(lines, setting)
    write_atomically(io -> foreach(line -> println(io, line), lines), conf)
    return nothing
end

#
# Finding pools and leftovers
#

const PIPELINE_COMPONENT = r"^[A-Za-z0-9_.-]+$"

is_pool_name(name::AbstractString) = name in POOL_TRUSTS || name in RETIRED_POOL_TRUSTS
is_pipeline_name(name::AbstractString) =
    occursin(PIPELINE_COMPONENT, name) && !startswith(name, ".")

function readdir_or_empty(path::AbstractString)
    is_real_dir(path) || return String[]
    try
        return readdir(path)
    catch err
        @warn("Unable to list cache directory", path, exception=(err, catch_backtrace()))
        return String[]
    end
end

function pools_below(root::AbstractString, slot::AbstractString, base::AbstractString)
    pools = CachePool[]
    for pipeline in readdir_or_empty(base)
        is_pipeline_name(pipeline) || continue
        pipeline_dir = joinpath(base, pipeline)
        for trust in readdir_or_empty(pipeline_dir)
            is_pool_name(trust) || continue
            path = joinpath(pipeline_dir, trust)
            is_real_dir(path) && push!(pools, CachePool(path, root, slot, pipeline, trust))
        end
    end
    return pools
end

# The pools under a cachedir: `<slot>/<pipeline>/<trust>` for every slot name
# of this host (configured or not). `persist-<slot>` directories, which a
# Linux persistence root inside the cachedir holds, are not slots.
function main_pools(root::AbstractString, configured_slots::Set{String};
                    hostname::AbstractString=get_short_hostname())
    pools = CachePool[]
    for slot in readdir_or_empty(root)
        host_slot_name(slot, hostname) || continue
        startswith(slot, "persist-") && slot ∉ configured_slots && continue
        append!(pools, pools_below(root, slot, joinpath(root, slot)))
    end
    return pools
end

shared_pools(root::AbstractString) = pools_below(root, "", root)

# Directories a backend keeps per slot outside the cache pools, as
# `(root, prefix)`: a slot's is `joinpath(root, prefix * slot.name)`.
slot_scratch_roots(::PlatformBackend, ::BuildkiteRunnerGroup) = Tuple{String,String}[]

# Paths of the disks of running guests, or `nothing` if unknown.
attached_disks(::PlatformBackend) = Set{String}()

struct RetentionRoots
    main::Vector{String}
    shared::Vector{String}
    scratch::Vector{Tuple{String,String}}
    slots::Set{String}
end

function retention_roots(brgs::Vector{BuildkiteRunnerGroup}, backends::AbstractDict)
    main = sort(unique(normpath(cachedir(brg)) for brg in brgs))
    shared = sort(unique(normpath(sharedcachedir(brg)) for brg in brgs if has_shared_cache(brg)))
    scratch = Tuple{String,String}[]
    for brg in brgs
        backend = get(backends, brg.backend, nothing)
        backend === nothing && continue
        try
            append!(scratch, slot_scratch_roots(backend, brg))
        catch err
            @warn("Unable to list the slot directories of a runner group", runner_group=brg.name,
                exception=(err, catch_backtrace()))
        end
    end
    scratch = sort(unique((normpath(root), prefix) for (root, prefix) in scratch))
    slots = Set(slot.name for slot in scheduler_slots(brgs))
    return RetentionRoots(main, shared, scratch, slots)
end

retention_roots(scheduler) = retention_roots(scheduler.brgs, scheduler.backends)

function all_pools(roots::RetentionRoots)
    pools = CachePool[]
    for root in roots.main
        append!(pools, main_pools(root, roots.slots))
    end
    for root in roots.shared
        append!(pools, shared_pools(root))
    end
    return pools
end

# Whether a disk of a running guest lies within `path`; with the guests'
# disks unknown, assume so.
function holds_attached_disk(path::AbstractString, attached)
    attached === nothing && return true
    return any(disk -> path_within_root(disk, path), attached)
end

function attached_guest_disks(backends)
    disks = Set{String}()
    for backend in values(backends)
        found = try
            attached_disks(backend)
        catch err
            @warn("Unable to list the disks of running guests", exception=(err, catch_backtrace()))
            nothing
        end
        found === nothing && return nothing
        union!(disks, found)
    end
    return disks
end

#
# Filesystems
#

function disk_limits(config::RetentionConfig, overrides::Dict{UInt64,DiskThresholds},
                     usage::FsUsage)
    given = get(overrides, usage.device, DiskThresholds(nothing, nothing))
    high = something(given.high_water_percent, config.defaults.high_water_percent)
    low = something(given.low_water_percent, config.defaults.low_water_percent)
    return FsLimits(high, low)
end

# The filesystems of `roots` by device, each labelled with its first root.
function filesystems(retention::CacheRetention, roots::Vector{String})
    overrides = Dict{UInt64,DiskThresholds}()
    for (path, thresholds) in retention.config.disks
        try
            overrides[retention.fs_usage(path).device] = thresholds
        catch err
            @warn("Unable to find the filesystem of a `disks` entry", path,
                exception=(err, catch_backtrace()), maxlog=1, _id=(:disks, path))
        end
    end
    by_device = Dict{UInt64,FsState}()
    for root in sort(unique(normpath.(roots)))
        probe = existing_disk_probe_path(root)
        probe === nothing && continue
        usage = try
            retention.fs_usage(probe)
        catch err
            @warn("Unable to measure filesystem", path=root, exception=(err, catch_backtrace()),
                maxlog=1, _id=(:fs_usage, root))
            continue
        end
        fs = get(by_device, usage.device, nothing)
        if fs === nothing
            by_device[usage.device] = FsState(root, probe, [root], usage,
                disk_limits(retention.config, overrides, usage))
        else
            push!(fs.roots, root)
        end
    end
    return sort!(collect(values(by_device)); by=fs -> fs.label)
end

function refresh!(retention::CacheRetention, fs::FsState)
    fs.usage = retention.fs_usage(fs.probe)
    return fs
end

"""
    check_disks!(scheduler)

Measure every filesystem holding a cache or scratch root, and wake the cache
worker if one needs eviction. Cheap: one `statvfs` per root. Free space never
gates admission: a filesystem that fills up despite eviction is the
operator's to handle (node_exporter reports it).
"""
function check_disks!(scheduler)
    retention = scheduler.retention
    fss = filesystems(retention, scheduler_disk_roots(scheduler.brgs))
    lock(() -> retention.last_check_at = retention.now(), retention.lock)
    # A capped eviction pass resumes from here, so batches are at least a check
    # interval apart, which gives late reclamation (ZFS) time to show.
    retention.config.enabled && any(fs -> wants_eviction(retention, fs), fss) &&
        notify(retention.wakeup)
    return fss
end

#
# The cache worker
#

# Remove everything in the trash of every root.
function purge_trash!(retention::CacheRetention, roots::RetentionRoots)
    for root in unique([roots.main; roots.shared; first.(roots.scratch)])
        trash = trash_dir(root)
        for name in readdir_or_empty(trash)
            path = joinpath(trash, name)
            if !retention.remove_tree(path)
                lock(() -> retention.removal_failures += 1, retention.lock)
                @warn("Unable to remove deleted cache data; retrying later", path)
            end
        end
    end
    return nothing
end

"""
    sweep_pools!(scheduler, roots)

Stamp pools that have no stamp, reset idle pools past their maximum age
(shared pools: not used for that long), and remove the per-slot scratch,
temporary and persistence directories of slots no longer configured.
"""
function sweep_pools!(scheduler, roots::RetentionRoots; attached=attached_guest_disks(scheduler.backends))
    retention = scheduler.retention
    config = retention.config
    pools = all_pools(roots)
    for pool in pools
        yield()
        lock(retention.lock) do
            haskey(retention.leased, pool.path) && return
            path_exists(pool.path) || return
            now = Float64(retention.now())
            stamp = read_pool_stamp(pool.path)
            if stamp === nothing
                stamp = adopted_pool_stamp(pool.path, now)
                # Without the stamp (a full disk), the pool is judged by its
                # adopted one; eviction must not wait for the write.
                try
                    write_pool_stamp(pool.path, stamp)
                catch err
                    @warn("Unable to stamp cache pool", pool=pool.path,
                        exception=(err, catch_backtrace()), maxlog=1, _id=(:stamp, pool.path))
                end
            end
            config.enabled || return
            expired = is_shared(pool) ?
                config.max_age_days > 0 && now - stamp.last_used_at >= config.max_age_days * 86400 :
                now >= pool_expires_at(config, pool.path, stamp)
            expired || return
            dest = try
                discard_pool_locked!(retention, pool.path; shared=is_shared(pool), attached,
                    wake=false)
            catch err
                @warn("Unable to reset cache pool past its maximum age", pool=pool.path,
                    exception=(err, catch_backtrace()))
                nothing
            end
            if dest === nothing
                @warn("Not resetting a cache pool whose disk a guest may use", pool=pool.path,
                    maxlog=1, _id=(:attached, pool.path))
                return
            end
            retention.resets += 1
            @info("Reset idle cache pool past its maximum age", pool=pool.path,
                age_days=round((now - stamp.created_at) / 86400; digits=1),
                idle_days=round((now - stamp.last_used_at) / 86400; digits=1))
        end
    end
    config.enabled && remove_slot_leftovers!(retention, roots, attached)
    lock(retention.lock) do
        retention.pools = length(pools)
        retention.last_sweep_at = retention.now()
    end
    return pools
end

function remove_slot_leftovers!(retention::CacheRetention, roots::RetentionRoots, attached)
    hostname = get_short_hostname()
    for (root, prefix) in roots.scratch
        for name in readdir_or_empty(root)
            startswith(name, prefix) || continue
            slot = name[nextind(name, lastindex(prefix)):end]
            host_slot_name(slot, hostname) && slot ∉ roots.slots || continue
            path = joinpath(root, name)
            holds_attached_disk(path, attached) && continue
            try
                lock(retention.lock) do
                    move_to_trash!(retention, path, root)
                    retention.leftovers_removed += 1
                end
                @info("Removing the directory of a slot that is no longer configured", path)
            catch err
                @warn("Unable to remove the directory of a slot that is no longer configured",
                    path, exception=(err, catch_backtrace()))
            end
        end
    end
    return nothing
end

"""
    eviction_candidates(retention, roots, fs; now)

Idle pools on `fs` in the order they are evicted: first those no job will use
again (of slots no longer configured, of retired trust partitions, and of
pipelines no pool of which was used for `retired_days`), then the least
recently used. Shared pools are only evicted in the first group: every slot
uses them, so they are never idle for long.
"""
function eviction_candidates(retention::CacheRetention, roots::RetentionRoots, fs::FsState;
                             pools::Vector{CachePool}=all_pools(roots),
                             now::Float64=Float64(retention.now()))
    stamps = Dict{String,PoolStamp}()
    pipeline_used = Dict{String,Float64}()
    for pool in pools
        stamp = haskey(retention.leased, pool.path) ? PoolStamp(now, now) :
            pool_stamp(pool.path, now)
        stamps[pool.path] = stamp
        pipeline_used[pool.pipeline] = max(get(pipeline_used, pool.pipeline, -Inf),
            stamp.last_used_at)
    end
    retired_before = now - retention.config.retired_days * 86400
    candidates = Tuple{Int,Float64,CachePool}[]
    for pool in pools
        pool.root in fs.roots || continue
        haskey(retention.leased, pool.path) && continue
        retired = pool.trust in RETIRED_POOL_TRUSTS ||
            (!is_shared(pool) && pool.slot ∉ roots.slots) ||
            pipeline_used[pool.pipeline] < retired_before
        is_shared(pool) && !retired && continue
        push!(candidates, (retired ? 0 : 1, stamps[pool.path].last_used_at, pool))
    end
    sort!(candidates; by=c -> (c[1], c[2], c[3].path))
    return [c[3] for c in candidates]
end

"""
    evict!(scheduler, roots, fs)

Delete idle pools from `fs`, in `eviction_candidates` order and one at a time,
until it is at or below its low-water mark, measuring its free space again
after each.
"""
function evict!(scheduler, roots::RetentionRoots, fs::FsState;
                attached=attached_guest_disks(scheduler.backends))
    retention = scheduler.retention
    evicted = 0
    # After a capped pass, give late reclamation a check interval to show.
    capped = get(retention.capped_at, fs.label, -Inf)
    retention.now() - capped < retention.config.check_interval && return 0
    candidates = eviction_candidates(retention, roots, fs)
    if !isempty(candidates)
        @info("Evicting cache pools down to the filesystem's low-water mark",
            filesystem=fs.label, used_percent=round(used_percent(fs.usage); digits=1),
            available_bytes=fs.usage.available,
            low_water_percent=fs.limits.low_water_percent)
    end
    for pool in candidates
        eviction_done(fs) && break
        evicted < MAX_EVICTIONS_PER_PASS[] || break
        dest = lock(retention.lock) do
            dest = try
                discard_pool_locked!(retention, pool.path; shared=is_shared(pool), attached,
                    wake=false)
            catch err
                @warn("Unable to evict cache pool", pool=pool.path,
                    exception=(err, catch_backtrace()))
                nothing
            end
            dest === nothing || (retention.evictions += 1)
            dest
        end
        dest === nothing && continue
        evicted += 1
        before = fs.usage.available
        if !retention.remove_tree(dest)
            lock(() -> retention.removal_failures += 1, retention.lock)
            @warn("Unable to remove evicted cache pool; retrying later", pool=pool.path, path=dest)
        end
        EVICTION_SETTLE_SECONDS[] > 0 && sleep(EVICTION_SETTLE_SECONDS[])
        refresh!(retention, fs)
        @info("Evicted cache pool", pool=pool.path, filesystem=fs.label,
            freed_bytes=fs.usage.available - before,
            used_percent=round(used_percent(fs.usage); digits=1))
    end
    evicted >= MAX_EVICTIONS_PER_PASS[] && (retention.capped_at[fs.label] = retention.now())
    if eviction_done(fs)
        delete!(retention.stuck, fs.label)
        delete!(retention.evicting, fs.label)
    elseif evicted < MAX_EVICTIONS_PER_PASS[] && fs.label ∉ retention.stuck
        push!(retention.stuck, fs.label)
        @warn("Filesystem stays above its low-water mark; no idle cache pool is left to evict",
            filesystem=fs.label, used_percent=round(used_percent(fs.usage); digits=1),
            available_bytes=fs.usage.available)
    end
    return evicted
end

# One pass of the cache worker: what the last check asked for, and the
# periodic sweep when it is due.
function retention_pass!(scheduler; force_sweep::Bool=false)
    retention = scheduler.retention
    roots = retention_roots(scheduler)
    purge_trash!(retention, roots)
    last = retention.last_sweep_at
    fss = filesystems(retention, scheduler_disk_roots(scheduler.brgs))
    due = force_sweep || last === nothing ||
        retention.now() - last >= RETENTION_SWEEP_SECONDS[] ||
        (retention.config.enabled && any(fs -> wants_eviction(retention, fs), fss))
    due || return nothing
    attached = attached_guest_disks(scheduler.backends)
    sweep_pools!(scheduler, roots; attached)
    purge_trash!(retention, roots)
    if retention.config.enabled
        for fs in fss
            refresh!(retention, fs)
            if wants_eviction(retention, fs)
                push!(retention.evicting, fs.label)
                evict!(scheduler, roots, fs; attached)
            else
                delete!(retention.stuck, fs.label)
                delete!(retention.evicting, fs.label)
            end
        end
    end
    purge_trash!(retention, roots)
    return nothing
end

function record_retention_error!(retention::CacheRetention, err)
    lock(retention.lock) do
        retention.last_error = sprint(showerror, err)
    end
    return nothing
end

function disk_monitor_forever!(scheduler)
    while true
        try
            check_disks!(scheduler)
        catch err
            @error("Disk check failed", exception=(err, catch_backtrace()))
            record_retention_error!(scheduler.retention, err)
        end
        sleep(scheduler.retention.config.check_interval)
    end
end

function cache_worker_forever!(scheduler)
    retention = scheduler.retention
    while true
        try
            retention_pass!(scheduler)
        catch err
            @error("Cache retention pass failed", exception=(err, catch_backtrace()))
            record_retention_error!(retention, err)
        end
        timer = Timer(_ -> notify(retention.wakeup), RETENTION_SWEEP_SECONDS[])
        try
            wait(retention.wakeup)
        finally
            close(timer)
        end
    end
end

function retention_status(retention::CacheRetention)
    return lock(retention.lock) do
        Dict{String,Any}(
            "enabled" => retention.config.enabled,
            "pools" => retention.pools,
            "leased_pools" => length(retention.leased),
            "evictions" => retention.evictions,
            "resets" => retention.resets,
            "leftovers_removed" => retention.leftovers_removed,
            "removal_failures" => retention.removal_failures,
            "last_check_at" => retention.last_check_at,
            "last_sweep_at" => retention.last_sweep_at,
            "last_error" => retention.last_error,
        )
    end
end
