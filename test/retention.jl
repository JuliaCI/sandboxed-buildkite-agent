# Cache retention (src/retention.jl). Included from runtests.jl, whose helpers
# (`runner_group`, `job`, `StaticJobSource`, `NullBackend`, `test_scheduler`) it uses.

import SandboxedBuildkiteAgent: CacheRetention, CachePool, FsUsage, PoolStamp,
    RetentionConfig, DiskThresholds, acquire_pool!, acquire_pools!, release_pool!,
    release_pools!, retention_pass!, check_disks!, eviction_candidates, all_pools,
    retention_roots, filesystems, pool_expires_at, read_pool_stamp, write_pool_stamp,
    pool_stamp_path, remove_tree, rename_exact, sweep_pools!, purge_trash!, evict!,
    host_slot_name, path_within_root, retention_status, scheduler_metrics,
    scheduler_status_snapshot

const R = SandboxedBuildkiteAgent
const DAY = 86400.0

# A filesystem whose use is the size of the files below `roots`, plus `extra`
# bytes used by others; `du` is fine in tests.
mutable struct FakeDisk
    device::UInt64
    total::Int
    extra::Int
    roots::Vector{String}
end

# Files under 500 bytes (stamps, logs, configuration) are not counted, so
# that the thresholds below are round numbers.
function tree_bytes(path)
    st = lstat(path)
    isfile(st) && return st.size >= 500 ? Int(st.size) : 0
    (isdir(st) && !islink(st)) || return 0
    return sum((tree_bytes(joinpath(path, name)) for name in readdir(path)); init=0)
end

# Paths on none of `disks` (such as the default tempdir) are on an empty one.
function fake_fs_usage(disks::Vector{FakeDisk})
    return function (path)
        for disk in disks
            any(root -> path_within_root(path, root), disk.roots) || continue
            used = disk.extra + sum(tree_bytes, disk.roots)
            return FsUsage(disk.device, disk.total, used, disk.total - used)
        end
        return FsUsage(UInt64(1), 10^12, 0, 10^12)
    end
end

# A scheduler over one fake disk holding `base`, and a clock.
function retention_scheduler(brgs, base; total=10_000, extra=0, backend=NullBackend(),
                             retention=RetentionConfig(; defaults=DiskThresholds(85.0, 75.0),
                                                        max_age_days=0))
    config = SchedulerConfig(joinpath(base, "logs"), 0.01, 0.01, 900, 60.0, 4, 8, 0,
        nothing, true, retention)
    mkpath(config.logdir)
    scheduler = test_scheduler(config, brgs, StaticJobSource(Job[]), backend)
    disk = FakeDisk(UInt64(7), total, extra, [base])
    # Ahead of the files' modification times.
    clock = Ref(time() + 60)
    scheduler.retention = CacheRetention(retention; fs_usage=fake_fs_usage([disk]),
        now=() -> clock[])
    return scheduler, disk, clock
end

function make_pool(root, slot, pipeline, trust="protected"; bytes=1000, last_used=nothing,
                   created=last_used)
    path = joinpath(root, slot, pipeline, trust)
    mkpath(path)
    write(joinpath(path, "data"), zeros(UInt8, bytes))
    last_used === nothing || write_pool_stamp(path, PoolStamp(created, last_used))
    return path
end

function make_shared_pool(root, pipeline, trust="protected"; bytes=1000, last_used=nothing)
    path = joinpath(root, pipeline, trust)
    mkpath(path)
    write(joinpath(path, "data"), zeros(UInt8, bytes))
    last_used === nothing || write_pool_stamp(path, PoolStamp(last_used, last_used))
    return path
end

trash_entries(root) = isdir(joinpath(root, ".sba-trash")) ? readdir(joinpath(root, ".sba-trash")) : String[]

function retention_group(base; name="linux", max_slots=4, shared=false, mem_gib=0)
    return runner_group(; name, cachedir_root=joinpath(base, "cache"), max_slots, mem_gib,
        sharedcache_root=shared ? joinpath(base, "shared") : nothing)
end

@testset "cache retention config" begin
    config = SchedulerConfig(Dict{String,Any}())
    @test config.retention.enabled
    config = SchedulerConfig(Dict{String,Any}(
        "cache_retention" => false,
        "disk_check_interval" => 30,
        "disk_high_water_percent" => 90,
        "disk_low_water_percent" => 80,
        "disks" => Dict("/srv/agent_build/" => Dict("high_water_percent" => 80)),
        "cache_max_age_days" => 0,
        "cache_retired_days" => 3,
        "ccache_max_size_gb" => 250,
    ))
    retention = config.retention
    @test !retention.enabled
    @test retention.check_interval == 30
    @test retention.defaults == DiskThresholds(90.0, 80.0)
    @test retention.disks == Dict("/srv/agent_build/" => DiskThresholds(80.0, nothing))
    @test retention.max_age_days == 0
    @test retention.retired_days == 3
    @test retention.ccache_max_size_gb == 250
    for bad in (Dict("disk_high_water_percent" => 101), Dict("disk_low_water_percent" => 0),
                Dict("disk_high_water_percent" => 70),  # below the default low-water mark
                Dict("cache_max_age_days" => -1),
                Dict("cache_retired_days" => 0), Dict("ccache_max_size_gb" => 1.5),
                Dict("cache_retention" => "yes"), Dict("disk_check_interval" => 0),
                Dict("disks" => Dict("relative" => Dict("high_water_percent" => 90))),
                Dict("disks" => Dict("/x" => Dict("reserve" => 1))),
                Dict("disks" => Dict("/x" => Dict("low_water_percent" => 90))),
                Dict("disks" => 1))
        @test_throws ArgumentError SchedulerConfig(Dict{String,Any}(bad))
    end
end

@testset "cache pools: stamps, eviction order and leases" begin
    base = mktempdir()
    brg = retention_group(base)
    scheduler, disk, clock = retention_scheduler([brg], base)
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    now = clock[]
    cache = joinpath(base, "cache")
    slot(i) = Slot(brg, i).name
    @test all(i -> host_slot_name(slot(i)), 1:4)
    @test !host_slot_name("persist-foo") && !host_slot_name(".sba-trash")

    # Below the high-water mark nothing goes, however old.
    pools = [make_pool(cache, slot(i), "pipeline-a"; bytes=2000, last_used=now - i * DAY)
             for i in 1:4]
    retention_pass!(scheduler)
    @test all(isdir, pools)
    @test scheduler.retention.evictions == 0

    # Above it, the least recently used pools go until the low-water mark is
    # reached: 8000 + 1000 of 10000 is 90%; one 2000-byte pool brings it to 70%.
    disk.extra = 1000
    retention_pass!(scheduler)
    @test !isdir(pools[4]) && !isfile(pool_stamp_path(pools[4]))
    @test all(isdir, pools[1:3])
    @test scheduler.retention.evictions == 1
    @test isempty(trash_entries(cache))
    # Further over, more go, one at a time: 6000 + 4000 is 100%, 80% after one.
    disk.extra = 4000
    retention_pass!(scheduler)
    @test !isdir(pools[3]) && !isdir(pools[2]) && isdir(pools[1])

    # A pool held by a job is never evicted, however old it looks.
    disk.extra = 0
    rm(pools[1]; recursive=true)
    old = make_pool(cache, slot(1), "pipeline-a"; bytes=2000, last_used=now - 30 * DAY,
        created=now - DAY)
    newer = [make_pool(cache, slot(i), "pipeline-a"; bytes=2000, last_used=now - i * DAY)
             for i in 2:4]
    acquire_pool!(scheduler.retention, old; shared=false)
    @test scheduler.retention.leased[old] == 1
    # Acquiring stamps the pool as used now; make it look unused instead.
    @test read_pool_stamp(old) == PoolStamp(now - DAY, now)
    write_pool_stamp(old, PoolStamp(now - DAY, now - 30 * DAY))
    disk.extra = 1000
    retention_pass!(scheduler)
    @test isdir(old)
    @test !isdir(newer[3]) && all(isdir, newer[1:2])
    # Nothing idle left that helps: what is held stays, whatever the disk.
    disk.extra = 20_000
    @test_logs (:warn, r"no idle cache pool") match_mode=:any retention_pass!(scheduler)
    @test isdir(old)
    release_pool!(scheduler.retention, old; shared=false)
    @test !haskey(scheduler.retention.leased, old)
    @test read_pool_stamp(old).last_used_at == now
    @test_logs (:error, r"not held") release_pool!(scheduler.retention, old; shared=false)
    @test !haskey(scheduler.retention.leased, old)
end

@testset "cache pools: retired first" begin
    base = mktempdir()
    brg = retention_group(base)
    scheduler, disk, clock = retention_scheduler([brg], base)
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    now = clock[]
    cache = joinpath(base, "cache")
    slot(i) = Slot(brg, i).name
    # A live pipeline with one slot's pool unused for 20 days; a pipeline last
    # used 10 days ago (retired after 7); a slot no longer configured.
    live_recent = make_pool(cache, slot(1), "live"; last_used=now - DAY)
    live_stale = make_pool(cache, slot(2), "live"; last_used=now - 20 * DAY)
    retired = make_pool(cache, slot(1), "retired"; last_used=now - 10 * DAY)
    gone_slot = make_pool(cache, "removed-$(R.get_short_hostname()).1", "live";
        last_used=now - 2 * DAY)
    # Not pools: a persistence root's slot directory, foreign entries.
    persist = mkpath(joinpath(cache, "persist-$(slot(1))", "upper", "x", "protected"))
    foreign = mkpath(joinpath(cache, "other", "live", "protected"))
    roots = retention_roots(scheduler)
    fs = only(filesystems(scheduler.retention, [cache]))
    order = eviction_candidates(scheduler.retention, roots, fs)
    @test [pool.path for pool in order] == [retired, gone_slot, live_stale, live_recent]
    @test !any(pool -> startswith(pool.path, dirname(persist)) || startswith(pool.path, foreign), order)
    # Pools without a stamp (from before stamps) count as last used when their
    # newest entry changed.
    unstamped = make_pool(cache, slot(4), "live")
    t = mtime(joinpath(unstamped, "data"))
    @test isnothing(read_pool_stamp(unstamped))
    order = eviction_candidates(scheduler.retention, roots, fs)
    @test order[end].path == unstamped
    sweep_pools!(scheduler, roots)
    @test read_pool_stamp(unstamped) == PoolStamp(t, t)

    # Evicted in that order: 5000 of 10000 bytes plus 4000 extra is 90%, so
    # two go.
    disk.extra = 4000
    retention_pass!(scheduler)
    @test !isdir(retired) && !isdir(gone_slot)
    @test isdir(live_stale) && isdir(live_recent) && isdir(unstamped)
end

@testset "cache pools: no acquisition during deletion" begin
    base = mktempdir()
    brg = retention_group(base)
    scheduler, disk, clock = retention_scheduler([brg], base)
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    cache = joinpath(base, "cache")
    pool = make_pool(cache, Slot(brg, 1).name, "pipeline"; bytes=5000,
        last_used=clock[] - DAY)
    entered = Base.Event()
    proceed = Base.Event()
    scheduler.retention.rename = function (src, dst)
        notify(entered)
        wait(proceed)
        rename_exact(src, dst)
    end
    disk.extra = 4000
    evicting = @async retention_pass!(scheduler)
    wait(entered)
    # The pool is being renamed away: a job taking it now waits, and then gets
    # an empty pool, never a half-deleted one.
    acquiring = @async acquire_pool!(scheduler.retention, pool; shared=false)
    for _ in 1:10
        yield()
    end
    @test !istaskdone(acquiring)
    notify(proceed)
    wait(evicting)
    wait(acquiring)
    @test scheduler.retention.evictions == 1
    @test scheduler.retention.leased[pool] == 1
    @test !isfile(joinpath(pool, "data"))
    @test read_pool_stamp(pool).created_at == clock[]

    # And the other way around: a held pool is not renamed.
    scheduler.retention.rename = rename_exact
    mkpath(pool)
    write(joinpath(pool, "data"), zeros(UInt8, 5000))
    @test_logs (:warn, r"no idle cache pool") match_mode=:any retention_pass!(scheduler)
    @test isfile(joinpath(pool, "data"))
    release_pool!(scheduler.retention, pool; shared=false)
end

@testset "cache pools: trash removal and symbolic links" begin
    base = mktempdir()
    brg = retention_group(base)
    scheduler, disk, clock = retention_scheduler([brg], base)
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    cache = joinpath(base, "cache")
    outside = mktempdir()
    write(joinpath(outside, "precious"), "keep")
    outside_file = joinpath(outside, "file")
    write(outside_file, "keep too")

    # What a crash left in the trash goes at the next start, read-only
    # directories (Pkg's package sources) included.
    trash = mkpath(joinpath(cache, ".sba-trash", "1-protected-dead"))
    readonly = mkpath(joinpath(trash, "packages", "Foo", "src"))
    write(joinpath(readonly, "Foo.jl"), "module Foo end")
    chmod(joinpath(trash, "packages", "Foo"), 0o555; recursive=true)
    inaccessible = mkpath(joinpath(trash, "persist", "work", "work", "deeper"))
    write(joinpath(inaccessible, "file"), "x")
    chmod(joinpath(trash, "persist", "work", "work"), 0o000)
    symlink(outside, joinpath(trash, "escape"))
    retention_pass!(scheduler)
    @test isempty(trash_entries(cache))
    @test read(joinpath(outside, "precious"), String) == "keep"

    # Evicting a pool whose job planted links out of the root deletes the
    # links, not what they point to.
    pool = make_pool(cache, Slot(brg, 1).name, "pipeline"; bytes=9000,
        last_used=clock[] - DAY)
    symlink(outside, joinpath(pool, "dir-link"))
    symlink(outside_file, joinpath(pool, "file-link"))
    mkpath(joinpath(pool, "nested"))
    symlink(outside, joinpath(pool, "nested", "deeper"))
    retention_pass!(scheduler)
    @test !ispath(pool)
    @test isempty(trash_entries(cache))
    @test read(joinpath(outside, "precious"), String) == "keep"
    @test read(outside_file, String) == "keep too"
    @test remove_tree(joinpath(base, "does-not-exist"))
    # A pool that is itself a link to elsewhere is not a pool.
    other = mkpath(joinpath(mktempdir(), "protected"))
    write(joinpath(other, "data"), zeros(UInt8, 9000))
    mkpath(joinpath(cache, Slot(brg, 2).name, "linked"))
    symlink(other, joinpath(cache, Slot(brg, 2).name, "linked", "protected"))
    @test isempty(all_pools(retention_roots(scheduler)))
end

@testset "cache pools: maximum age" begin
    base = mktempdir()
    brg = retention_group(base)
    scheduler, disk, clock = retention_scheduler([brg], base;
        retention=RetentionConfig(; defaults=DiskThresholds(85.0, 75.0), max_age_days=14))
    config = scheduler.retention.config
    cache = joinpath(base, "cache")
    created = clock[]
    stamp = PoolStamp(created, created)
    # Staggered between 10.5 and 14 days, per pool.
    expiries = [pool_expires_at(config, joinpath(cache, "slot-$(i)", "p", "protected"), stamp)
                for i in 1:50]
    @test all(e -> created + 10.5 * DAY <= e <= created + 14 * DAY, expiries)
    @test length(unique(expiries)) > 40
    @test pool_expires_at(RetentionConfig(; max_age_days=0), "x", stamp) == Inf

    # A held pool that expires is reset when it is released, before its slot
    # takes it again.
    pool = joinpath(cache, Slot(brg, 1).name, "pipeline", "protected")
    acquire_pool!(scheduler.retention, pool; shared=false)
    mkpath(pool)
    write(joinpath(pool, "data"), "warm")
    expiry = pool_expires_at(config, pool, read_pool_stamp(pool))
    clock[] = expiry + 1
    sweep_pools!(scheduler, retention_roots(scheduler))
    @test isfile(joinpath(pool, "data"))
    @test scheduler.retention.resets == 0
    release_pool!(scheduler.retention, pool; shared=false)
    @test !ispath(pool)
    @test scheduler.retention.resets == 1
    purge_trash!(scheduler.retention, retention_roots(scheduler))
    @test isempty(trash_entries(cache))
    # The next job starts afresh, and its pool ages from then.
    acquire_pool!(scheduler.retention, pool; shared=false)
    @test read_pool_stamp(pool) == PoolStamp(clock[], clock[])
    release_pool!(scheduler.retention, pool; shared=false)

    # An expired pool is reset when a job takes it, too.
    mkpath(pool)
    write(joinpath(pool, "data"), "warm")
    clock[] += 15 * DAY
    acquire_pool!(scheduler.retention, pool; shared=false)
    @test !isfile(joinpath(pool, "data"))
    @test scheduler.retention.resets == 2
    release_pool!(scheduler.retention, pool; shared=false)

    # And an idle one by the sweep.
    mkpath(pool)
    write(joinpath(pool, "data"), "warm")
    clock[] += 15 * DAY
    retention_pass!(scheduler; force_sweep=true)
    @test !ispath(pool)
    @test scheduler.retention.resets == 3

    # Without retention, nothing is reset.
    scheduler.retention.config = RetentionConfig(; enabled=false, max_age_days=14)
    mkpath(pool)
    write(joinpath(pool, "data"), "warm")
    acquire_pool!(scheduler.retention, pool; shared=false)
    clock[] += 15 * DAY
    release_pool!(scheduler.retention, pool; shared=false)
    retention_pass!(scheduler; force_sweep=true)
    @test isfile(joinpath(pool, "data"))
end

@testset "cache pools: shared pools" begin
    base = mktempdir()
    brg = retention_group(base; shared=true)
    scheduler, disk, clock = retention_scheduler([brg], base)
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    now = clock[]
    shared = joinpath(base, "shared")
    pool = joinpath(shared, "pipeline", "protected")
    # Two jobs hold it at once; the first sets the ccache size.
    acquire_pool!(scheduler.retention, pool; shared=true)
    conf = joinpath(pool, "ccache", "ccache.conf")
    @test readlines(conf) == ["max_size = 50G"]
    write(conf, "compression = true\nmax_size = 500G\n")
    acquire_pool!(scheduler.retention, pool; shared=true)
    @test scheduler.retention.leased[pool] == 2
    @test readlines(conf) == ["compression = true", "max_size = 500G"]
    write(joinpath(pool, "ccache", "blob"), zeros(UInt8, 9000))
    # However full the disk and however long ago the pipeline's other pools
    # were used, a held shared pool stays.
    clock[] = now + 30 * DAY
    retention_pass!(scheduler)
    @test isdir(pool)
    release_pool!(scheduler.retention, pool; shared=true)
    @test scheduler.retention.leased[pool] == 1
    retention_pass!(scheduler)
    @test isdir(pool)
    release_pool!(scheduler.retention, pool; shared=true)
    @test !haskey(scheduler.retention.leased, pool)
    # Idle, but its pipeline is live: not evicted.
    retention_pass!(scheduler)
    @test isdir(pool)
    # The next first job fixes the size again, keeping the other settings.
    acquire_pool!(scheduler.retention, pool; shared=true)
    @test readlines(conf) == ["compression = true", "max_size = 50G"]
    release_pool!(scheduler.retention, pool; shared=true)
    # Once the pipeline is retired, it goes.
    clock[] += 8 * DAY
    retention_pass!(scheduler)
    @test !ispath(pool)

    # A job-planted link is not written through.
    pool = joinpath(shared, "other", "untrusted")
    mkpath(pool)
    target = mktempdir()
    symlink(target, joinpath(pool, "ccache"))
    @test_logs (:warn, r"not a plain directory") acquire_pool!(scheduler.retention, pool; shared=true)
    @test isempty(readdir(target))
    release_pool!(scheduler.retention, pool; shared=true)
    rm(joinpath(pool, "ccache"))
    mkpath(joinpath(pool, "ccache"))
    victim = joinpath(target, "victim")
    write(victim, "x")
    symlink(victim, joinpath(pool, "ccache", "ccache.conf"))
    @test_logs (:warn, r"not a plain file") acquire_pool!(scheduler.retention, pool; shared=true)
    @test read(victim, String) == "x"
    release_pool!(scheduler.retention, pool; shared=true)

    # Scheduler acquisition and release cover both pools of a job.
    plan = cache_plan(Slot(brg, 1), job(), :protected)
    acquire_pools!(scheduler.retention, plan)
    @test scheduler.retention.leased[plan.cache_pool] == 1
    @test scheduler.retention.leased[plan.ccache_pool] == 1
    release_pools!(scheduler.retention, plan)
    @test isempty(scheduler.retention.leased)
end

struct GuestDisksBackend <: PlatformBackend
    disks::Union{Nothing,Set{String}}
end
SandboxedBuildkiteAgent.attached_disks(backend::GuestDisksBackend) = backend.disks

@testset "cache pools: KVM cache disks" begin
    base = mktempdir()
    brg = retention_group(base)
    disks = Set{String}()
    scheduler, disk, clock = retention_scheduler([brg], base; backend=GuestDisksBackend(disks))
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    cache = joinpath(base, "cache")
    attached = make_pool(cache, Slot(brg, 1).name, "pipeline"; bytes=1000,
        last_used=clock[] - 3 * DAY)
    write(joinpath(attached, "cache.qcow2-1"), zeros(UInt8, 3000))
    detached = make_pool(cache, Slot(brg, 2).name, "pipeline"; bytes=1000,
        last_used=clock[] - DAY)
    write(joinpath(detached, "cache.qcow2-1"), zeros(UInt8, 3000))
    push!(disks, joinpath(attached, "cache.qcow2-1"))
    # The older pool's disk is attached to a running guest (which no lease
    # explains): only the other is discarded, whole. 8000 + 1000 is 90%.
    disk.extra = 1000
    retention_pass!(scheduler)
    @test isfile(joinpath(attached, "cache.qcow2-1"))
    @test !ispath(detached)
    # With the guests' disks unknown, nothing is.
    scheduler.backends[brg.backend] = GuestDisksBackend(nothing)
    empty!(disks)
    disk.extra = 8000
    retention_pass!(scheduler)
    @test isfile(joinpath(attached, "cache.qcow2-1"))
    scheduler.backends[brg.backend] = GuestDisksBackend(disks)
    retention_pass!(scheduler)
    @test !ispath(attached)

    # The KVM backend lists every running domain's disks.
    kvm = KVMBackend(mktempdir())
    found = R.attached_disks(kvm; domains=() -> ["a", "b"],
        disk_paths=domain -> ["/srv/$(domain)/cache.qcow2-1", "/srv/$(domain)/os.qcow2"])
    @test found == Set(["/srv/a/cache.qcow2-1", "/srv/a/os.qcow2", "/srv/b/cache.qcow2-1",
                        "/srv/b/os.qcow2"])
    @test (@test_logs (:warn,) R.attached_disks(kvm; domains=() -> error("libvirt down"))) === nothing
end

struct ScratchBackend <: PlatformBackend
    roots::Vector{Tuple{String,String}}
end
SandboxedBuildkiteAgent.slot_scratch_roots(backend::ScratchBackend, ::BuildkiteRunnerGroup) =
    backend.roots

struct DirBackend <: PlatformBackend
    scratch::Vector{Tuple{String,String}}
    dirs::Vector{Tuple{String,String}}
end
SandboxedBuildkiteAgent.slot_scratch_roots(backend::DirBackend, ::BuildkiteRunnerGroup) =
    backend.scratch
SandboxedBuildkiteAgent.slot_dir_roots(backend::DirBackend, ::BuildkiteRunnerGroup) =
    backend.dirs

@testset "cache pools: leftovers of removed slots" begin
    base = mktempdir()
    brg = retention_group(base; max_slots=2)
    temp = joinpath(base, "tmp", "agent-tempdirs")
    persist = joinpath(base, "cache")
    scheduler, disk, clock = retention_scheduler([brg], base;
        backend=ScratchBackend([(temp, ""), (persist, "persist-")]))
    host = R.get_short_hostname()
    configured = [mkpath(joinpath(temp, Slot(brg, i).name)) for i in 1:2]
    configured_persist = mkpath(joinpath(persist, "persist-$(Slot(brg, 1).name)", "upper"))
    removed = [mkpath(joinpath(temp, "renamed-$(host).3")),
               mkpath(joinpath(temp, Slot(brg, 5).name)),
               mkpath(joinpath(persist, "persist-renamed-$(host).1", "work"))]
    unrelated = [mkpath(joinpath(temp, "renamed-otherhost.1")),
                 mkpath(joinpath(temp, "notes")),
                 mkpath(joinpath(persist, "renamed-$(host).1"))]
    retention_pass!(scheduler; force_sweep=true)
    @test all(isdir, configured) && isdir(configured_persist)
    @test !any(ispath, removed)
    @test all(isdir, unrelated)
    @test scheduler.retention.leftovers_removed == 3
    @test isempty(trash_entries(temp)) && isempty(trash_entries(persist))

    # A group without `max_slots` keeps every slot index; one above a cap, or of
    # a removed group, is not configured.
    caps = Dict("open" => 0, "capped" => 2)
    @test R.configured_slot(caps, "open-$(host).1") && R.configured_slot(caps, "open-$(host).97")
    @test R.configured_slot(caps, "capped-$(host).2") && !R.configured_slot(caps, "capped-$(host).3")
    @test !R.configured_slot(caps, "gone-$(host).1") && !R.configured_slot(caps, "open-$(host).0")
    @test !R.configured_slot(caps, "open-otherhost.1") && !R.configured_slot(caps, "persist-open-$(host).1")
    @test R.parse_slot_name("my-group-$(host).12") == ("my-group", 12)
    base = mktempdir()
    open_brg = retention_group(base; name="open", max_slots=nothing)
    capped_brg = retention_group(base; name="capped", max_slots=2)
    temp = joinpath(base, "tmp", "agent-tempdirs")
    scheduler, disk, clock = retention_scheduler([open_brg, capped_brg], base;
        backend=ScratchBackend([(temp, "")]))
    kept = [mkpath(joinpath(temp, Slot(open_brg, 9).name)),
            mkpath(joinpath(temp, Slot(capped_brg, 2).name))]
    gone = mkpath(joinpath(temp, Slot(capped_brg, 3).name))
    retention_pass!(scheduler; force_sweep=true)
    @test all(isdir, kept) && !ispath(gone)

    # Backends clean every slot up to the highest index found on disk, and all
    # slots of a capped group.
    mkpath(joinpath(base, "cache", Slot(open_brg, 4).name))
    known = R.known_slots([open_brg, capped_brg], scheduler.backends)
    @test sort([s.name for s in known]) == sort(vcat([Slot(open_brg, i).name for i in 1:9],
        [Slot(capped_brg, i).name for i in 1:2]))
    rm(kept[1]; recursive=true)
    @test count(s -> s.brg === open_brg, R.known_slots([open_brg, capped_brg], scheduler.backends)) == 4
    @test count(s -> s.brg === open_brg, R.known_slots([open_brg])) == 4
    # Directories retention may not delete from still count, such as a Linux
    # persistence root found among the host's mounts.
    fallback = mktempdir()
    mkpath(joinpath(fallback, "persist-$(Slot(open_brg, 6).name)"))
    dirs = DirBackend([(temp, "")], [(temp, ""), (fallback, "persist-")])
    @test count(s -> s.brg === open_brg, R.known_slots([open_brg], Dict(open_brg.backend => dirs))) == 6

    # The real backends' slot directories.
    lbrg = retention_group(mktempdir())
    @test (joinpath(tempdir(lbrg), "agent-tempdirs"), "") in
        R.slot_scratch_roots(MacSeatbeltBackend(mktempdir(), BuildkiteRunnerGroup[]), lbrg)
    kbrg = BuildkiteRunnerGroup("windows", Dict{String,Any}("backend" => "kvm",
        "guest" => "windows", "max_slots" => 1, "tempdir" => base,
        "default" => Dict("cpus" => 1, "mem_gib" => 4)); host=:linux)
    @test R.slot_scratch_roots(KVMBackend(mktempdir()), kbrg) ==
        [(joinpath(base, "kvm-agent-scratch"), "")]
end

@testset "cache pools: a full filesystem never blocks admission" begin
    # Charged and uncharged (launcher) groups alike.
    for cpus in (1, 0)
        base = mktempdir()
        brg = runner_group(; name="linux", cachedir_root=joinpath(base, "cache"), max_slots=2,
            cpus)
        source = StaticJobSource([job(; id="full-disk-job")])
        retention = RetentionConfig(; max_age_days=0)
        config = SchedulerConfig(joinpath(base, "logs"), 0.01, 0.01, 900, 60.0, 4, 8, 0,
            nothing, true, retention)
        mkpath(config.logdir)
        mkpath(joinpath(base, "cache"))
        scheduler = test_scheduler(config, [brg], source, NullBackend())
        # The cache filesystem and the log filesystem are both full.
        disks = [FakeDisk(UInt64(7), 10_000, 10_000, [joinpath(base, "cache")]),
                 FakeDisk(UInt64(8), 10_000, 10_000, [config.logdir])]
        clock = Ref(time() + 60)
        scheduler.retention = CacheRetention(retention; fs_usage=fake_fs_usage(disks),
            now=() -> clock[])
        replace_all_pending_jobs!(scheduler, poll_jobs(source))
        fss = check_disks!(scheduler)
        # The log filesystem is not watched; the full cache filesystem wakes eviction.
        @test joinpath(base, "cache") in [fs.label for fs in fss]
        @test !any(fs -> config.logdir in fs.roots, fss)
        @test scheduler.retention.wakeup.set
        snapshot = scheduler_status_snapshot(scheduler)
        @test !snapshot["pool"]["groups"][brg.name]["blocked"]
        assignment = take_assignment!(scheduler)
        @test assignment.job.id == "full-disk-job"
        # Its pool is held until the job's slot is released.
        @test scheduler.retention.leased[assignment.plan.cache_pool] == 1
        release!(scheduler, assignment)
        @test isempty(scheduler.retention.leased)
        @test read_pool_stamp(assignment.plan.cache_pool).last_used_at == clock[]
    end
end

@testset "cache pools: failures and partial passes" begin
    base = mktempdir()
    brg = retention_group(base)
    scheduler, disk, clock = retention_scheduler([brg], base)
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    cache = joinpath(base, "cache")
    now = clock[]
    slot(i) = Slot(brg, i).name

    # A pool whose stamp cannot be written (a full disk) is still evicted.
    stuck = make_pool(cache, slot(1), "p"; bytes=5000)
    mkdir(pool_stamp_path(stuck))
    disk.extra = 4000
    retention_pass!(scheduler)
    @test !ispath(stuck)
    @test scheduler.retention.evictions == 1

    # Eviction capped per pass carries on to the low-water mark at the next
    # pass, below high water by then.
    disk.extra = 4500
    pools = [make_pool(cache, slot(i), "p"; bytes=1000, last_used=now - i * DAY) for i in 1:4]
    write(joinpath(pools[1], "more"), zeros(UInt8, 1000))  # 5000 + 4500: 95%
    R.MAX_EVICTIONS_PER_PASS[] = 1
    try
        retention_pass!(scheduler)
        @test !ispath(pools[4]) && ispath(pools[3])          # 85%: not above high water
        @test "$(cache)" in scheduler.retention.evicting
        check_disks!(scheduler)
        @test scheduler.retention.wakeup.set                 # the monitor resumes it
        retention_pass!(scheduler)
        @test ispath(pools[3])                               # not within a check interval
        clock[] += 60
        retention_pass!(scheduler)
        @test !ispath(pools[3]) && ispath(pools[2])          # 75%: done
        @test isempty(scheduler.retention.evicting)
        retention_pass!(scheduler)
        @test ispath(pools[2])
    finally
        R.MAX_EVICTIONS_PER_PASS[] = 10
    end
end

@testset "cache pools: an expired pool that cannot be reset is not used" begin
    base = mktempdir()
    brg = retention_group(base; mem_gib=2)
    source = StaticJobSource([job(; id="expired-job")])
    retention = RetentionConfig(; defaults=DiskThresholds(85.0, 75.0), max_age_days=14)
    config = SchedulerConfig(joinpath(base, "logs"), 0.01, 0.01, 900, 60.0, 4, 8, 0,
        nothing, true, retention)
    mkpath(config.logdir)
    scheduler = test_scheduler(config, [brg], source, NullBackend())
    clock = Ref(time() + 60)
    scheduler.retention = CacheRetention(retention; now=() -> clock[],
        rename=(src, dst) -> error("rename refused"))
    plan = cache_plan(Slot(brg, 1), job(; id="expired-job"), :protected)
    pool = plan.cache_pool
    mkpath(pool)
    write_pool_stamp(pool, PoolStamp(clock[] - 30 * DAY, clock[] - DAY))
    @test_throws R.PoolUnavailable acquire_pool!(scheduler.retention, pool; shared=false)
    @test !haskey(scheduler.retention.leased, pool)
    # Nor while a guest uses its disk.
    scheduler.retention.rename = rename_exact
    @test_throws R.PoolUnavailable acquire_pool!(scheduler.retention, pool; shared=false,
        attached=() -> Set([joinpath(pool, "cache.qcow2-1")]))
    @test_throws R.PoolUnavailable acquire_pool!(scheduler.retention, pool; shared=false,
        attached=() -> nothing)
    @test isdir(pool) && !haskey(scheduler.retention.leased, pool)
    # libvirt is asked before the lock is taken, and only when a reset is due.
    asked = Ref(0)
    lock(scheduler.retention.lock)
    t = @async acquire_pool!(scheduler.retention, pool; shared=false,
        attached=() -> (asked[] += 1; Set([joinpath(pool, "cache.qcow2-1")])))
    for _ in 1:10
        yield()
    end
    @test asked[] == 1 && !istaskdone(t)
    unlock(scheduler.retention.lock)
    @test_throws TaskFailedException wait(t)
    fresh = joinpath(dirname(pool), "untrusted")
    acquire_pool!(scheduler.retention, fresh; shared=false, attached=() -> (asked[] += 1; nothing))
    @test asked[] == 1
    release_pool!(scheduler.retention, fresh; shared=false, attached=() -> (asked[] += 1; nothing))
    @test asked[] == 1
    # The scheduler leaves such a job to its reservation's expiry.
    scheduler.retention.rename = (src, dst) -> error("rename refused")
    replace_all_pending_jobs!(scheduler, poll_jobs(source))
    @test take_assignment!(scheduler) === nothing
    @test haskey(scheduler.quarantined_jobs, "expired-job")
    @test isempty(scheduler.retention.leased)
    @test R.free_slots(scheduler.lease_pools[brg.name]) == brg.max_slots
    @test available(scheduler.cpu_pool) == 4 && available(scheduler.mem_pool) == 8
    # A pool that expired while held, but cannot be reset at release, stays
    # expired and is reset by its next job.
    scheduler.retention.rename = rename_exact
    write_pool_stamp(pool, PoolStamp(clock[], clock[]))
    acquire_pool!(scheduler.retention, pool; shared=false)
    clock[] += 15 * DAY
    release_pool!(scheduler.retention, pool; shared=false,
        attached=() -> Set([joinpath(pool, "cache.qcow2-1")]))
    @test isdir(pool)
    acquire_pool!(scheduler.retention, pool; shared=false)
    @test !isdir(pool)
    @test scheduler.retention.resets == 1
end

@testset "cache retention metrics and status" begin
    base = mktempdir()
    brg = retention_group(base)
    retention = RetentionConfig(; max_age_days=0)
    scheduler, disk, clock = retention_scheduler([brg], base; retention, extra=9000)
    mkpath(joinpath(base, "cache"))
    check_disks!(scheduler)
    scheduler.retention.evictions = 3
    scheduler.retention.resets = 2
    snapshot = scheduler_status_snapshot(scheduler)
    metrics = scheduler_metrics(snapshot; version="test")
    # Filesystems are node_exporter's to report.
    @test !occursin("sba_disk_", metrics) && !occursin("disk_paused", metrics)
    @test !haskey(snapshot["cache"], "filesystems")
    @test occursin("# TYPE sba_cache_evictions_total counter", metrics)
    @test occursin("sba_cache_evictions_total 3", metrics)
    @test occursin("sba_cache_resets_total 2", metrics)
    @test occursin("sba_cache_pools_leased 0", metrics)
    io = IOBuffer()
    SandboxedBuildkiteAgent.print_scheduler_status_human(io, Dict("installed" => true),
        nothing, "status.json", snapshot)
    text = String(take!(io))
    @test occursin("Cache retention: enabled=true", text)
    @test occursin("evictions=3 resets=2", text)
    @test !occursin("disk_paused", text)
    @test !occursin("Disks:", text) && !occursin("high_water=", text)
end

# A ZFS dataset on `disk`: what is written or deleted shows in its usage only
# once the transaction group holding it is written out, every `txg` seconds of
# `clock`.
function fake_zfs_usage(disk::FakeDisk, clock::Ref{Float64}; txg=R.zfs_txg_timeout())
    visible = Ref(disk.extra + sum(tree_bytes, disk.roots))
    synced = Ref(fld(clock[], txg))
    return function (path)
        any(root -> path_within_root(path, root), disk.roots) ||
            return FsUsage(UInt64(1), 10^12, 0, 10^12)
        if fld(clock[], txg) > synced[]
            synced[] = fld(clock[], txg)
            visible[] = disk.extra + sum(tree_bytes, disk.roots)
        end
        return FsUsage(disk.device, disk.total, visible[], disk.total - visible[],
            UInt64(R.ZFS_SUPER_MAGIC))
    end
end

@testset "cache pools: ZFS frees space late" begin
    base = mktempdir()
    brg = retention_group(base)
    scheduler, disk, clock = retention_scheduler([brg], base)
    R.EVICTION_SETTLE_SECONDS[] = 0.0
    cache = joinpath(base, "cache")
    slot(i) = Slot(brg, i).name
    # Just after a txg, so that deletions show only at the next one.
    clock[] = 5 * fld(clock[], 5) + 0.5
    now = clock[]
    slept = Float64[]
    fake_sleep = s -> (push!(slept, s); clock[] += s; nothing)
    pools = [make_pool(cache, slot(i), "p"; bytes=1000, last_used=now - i * DAY) for i in 1:4]
    disk.extra = 5000                                        # 90%
    retention = scheduler.retention
    scheduler.retention = CacheRetention(retention.config;
        fs_usage=fake_zfs_usage(disk, clock), now=() -> clock[], sleep=fake_sleep)
    fss = filesystems(scheduler.retention, [cache])
    @test R.is_zfs(only(fss).usage)
    retention_pass!(scheduler)
    # Two pools bring it to 75%; measuring before the txg would take more.
    @test !ispath(pools[4]) && !ispath(pools[3]) && ispath(pools[2]) && ispath(pools[1])
    @test scheduler.retention.evictions == 2
    @test isempty(scheduler.retention.evicting) && isempty(scheduler.retention.stuck)
    quiet = R.zfs_txg_timeout() + 1
    # Each eviction waited for its txg, then a quiet txg interval.
    @test all(==(1), slept)
    @test 2 * quiet <= length(slept) <= 2 * (quiet + R.zfs_txg_timeout() + 1)

    # Free space measured one second apart: settle! returns after a quiet txg
    # interval and a second, judging growth against the previous measurement.
    fs = only(filesystems(scheduler.retention, [cache]))
    function settle_time(available)
        n = Ref(0)
        scheduler.retention.fs_usage = path -> (n[] += 1;
            a = available[min(n[], length(available))];
            FsUsage(UInt64(7), 1000, 1000 - a, a, UInt64(R.ZFS_SUPER_MAGIC)))
        fs.usage = scheduler.retention.fs_usage(fs.probe)
        n[] = 1
        empty!(slept)
        R.settle!(scheduler.retention, fs)
        return sum(slept)
    end
    @test settle_time([100]) == quiet                               # nothing freed
    @test settle_time([100, 100, 100, 150]) == 3 + quiet            # one txg
    @test settle_time([100, 100, 150, 150, 150, 150, 200]) == 6 + quiet  # two
    # Jobs writing meanwhile: growth below the first measurement still counts.
    @test settle_time([100, 50, 50, 50, 50, 50, 60]) == 6 + quiet

    # Space that keeps arriving (a job deleting) bounds the wait.
    growing = Ref(0)
    scheduler.retention.fs_usage = path -> (growing[] += 1;
        FsUsage(UInt64(7), 10^6, 10^5 - growing[], 9 * 10^5 + growing[], UInt64(R.ZFS_SUPER_MAGIC)))
    empty!(slept)
    R.settle!(scheduler.retention, fs)
    @test sum(slept) == R.ZFS_SETTLE_INTERVALS * quiet

    # Elsewhere, the fixed settle, measured once.
    calls = Ref(0)
    scheduler.retention.fs_usage = path -> (calls[] += 1; FsUsage(UInt64(7), 100, 10, 90))
    fs.usage = FsUsage(UInt64(7), 100, 10, 90)
    empty!(slept)
    R.EVICTION_SETTLE_SECONDS[] = 2.0
    try
        R.settle!(scheduler.retention, fs)
    finally
        R.EVICTION_SETTLE_SECONDS[] = 0.0
    end
    @test slept == [2.0] && calls[] == 1
end

@testset "cache pools: ZFS frees purged trash late" begin
    for removed in (true, false)
        base = mktempdir()
        brg = retention_group(base)
        scheduler, disk, clock = retention_scheduler([brg], base)
        cache = joinpath(base, "cache")
        clock[] = 5 * fld(clock[], 5) + 0.5
        now = clock[]
        pools = [make_pool(cache, Slot(brg, i).name, "p"; bytes=1000, last_used=now - i * DAY)
                 for i in 1:4]
        # A pool deleted before a restart, 90% in all; 70% once purged.
        trash = joinpath(cache, ".sba-trash", "1-protected-0")
        mkpath(trash)
        write(joinpath(trash, "data"), zeros(UInt8, 2000))
        disk.extra = 3000
        # A partial removal (`rm` failed on something) frees space all the same.
        remove = path -> (rm(path; recursive=true); removed)
        scheduler.retention = CacheRetention(scheduler.retention.config;
            fs_usage=fake_zfs_usage(disk, clock), now=() -> clock[],
            sleep=s -> (clock[] += s; nothing), remove_tree=remove)
        retention_pass!(scheduler)
        @test all(ispath, pools)
        @test scheduler.retention.evictions == 0
        @test scheduler.retention.removal_failures == (removed ? 0 : 1)
    end
end

@testset "cache pools: roots in several datasets of one ZFS pool" begin
    base = mktempdir()
    roots = [joinpath(base, name) for name in ("cache", "shared", "tmp", "other")]
    foreach(mkpath, roots)
    datasets = Dict(UInt64(11) => "julia/cache", UInt64(12) => "julia/shared",
        UInt64(13) => "julia", UInt64(14) => "tank/other")
    zfs = UInt64(R.ZFS_SUPER_MAGIC)
    usage(device) = FsUsage(device, 1000, 100, 900, zfs)
    by_root(root) = UInt64(10 + findfirst(==(root), roots))
    retention = CacheRetention(RetentionConfig(; max_age_days=0);
        fs_usage=path -> usage(by_root(path)), zfs_dataset=device -> datasets[device])
    # Once per pool.
    @test_logs (:warn, r"several datasets of one ZFS pool") begin
        filesystems(retention, roots)
        filesystems(retention, roots)
    end
    # One dataset per pool, or not ZFS: nothing to say.
    @test_logs filesystems(retention, roots[[1, 4]])
    plain = CacheRetention(RetentionConfig(; max_age_days=0);
        fs_usage=path -> FsUsage(by_root(path), 1000, 100, 900), zfs_dataset=device -> error("not ZFS"))
    @test_logs filesystems(plain, roots)

    # Datasets by device number, from the kernel's mount table.
    mountinfo = joinpath(base, "mountinfo")
    write(mountinfo, """
        22 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw
        95 22 0:51 / /julia rw,relatime shared:50 - zfs julia rw,xattr,noacl
        96 95 0:52 / /julia/cache rw,relatime shared:51 - zfs julia/cache rw,xattr,noacl
        97 95 259:5 / /julia/persistence rw,relatime shared:52 - ext4 /dev/sdb1 rw
        98 95 0:300 / /julia/tmp rw,relatime shared:53 - zfs julia/tmp rw,xattr,noacl
        """)
    # glibc `makedev(0, 300)`.
    @test R.zfs_dataset(UInt64(300 & 0xff | (300 & 0xffffff00) << 12); mountinfo) == "julia/tmp"
    @test R.zfs_dataset(UInt64(52); mountinfo) == "julia/cache"
    @test R.zfs_dataset(UInt64(51); mountinfo) == "julia"
    # glibc `makedev(259, 5)`, ext4.
    @test R.zfs_dataset(UInt64(259 << 8 | 5); mountinfo) === nothing
    @test R.zfs_dataset(UInt64(53); mountinfo) === nothing
    @test R.zfs_dataset(UInt64(52); mountinfo=joinpath(base, "missing")) === nothing
end
