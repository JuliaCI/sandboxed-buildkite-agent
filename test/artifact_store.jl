# The artifact store (src/artifact_store.jl). Included from runtests.jl, whose
# helpers (`with_http_server`, `sized_job`) it uses.

using Tar
import SandboxedBuildkiteAgent: artifact_demand, import_artifact, fill_artifact_store!,
    evict_artifact_store!, artifact_store_path, artifact_store_staging, artifact_store_sizes,
    artifact_store_bytes, check_artifact_store_paths, CacheRetention, RetentionConfig, FsUsage

const A = SandboxedBuildkiteAgent

# Its own tempdir, since the default one, the system's, holds every `mktempdir()`.
# macOS groups take the whole host by default.
store_group(name="yggy"; host=:linux, kwargs...) =
    BuildkiteRunnerGroup(name, Dict{String,Any}("queues" => "build", "max_slots" => 1,
        (host == :macos ? () : ("default" => Dict("cpus" => 1),))..., "tempdir" => mktempdir(),
        (string(k) => v for (k, v) in kwargs)...); host)

# A gzipped tarball of a small tree, with its git tree hash.
function artifact_tarball(dir)
    src = mktempdir()
    mkpath(joinpath(src, "bin"))
    write(joinpath(src, "bin", "tool"), "#!/bin/sh\necho tool\n")
    chmod(joinpath(src, "bin", "tool"), 0o755)
    write(joinpath(src, "README"), "a fixture\n")
    tar = joinpath(dir, "fixture.tar")
    Tar.create(src, tar)
    tree_hash = Tar.tree_hash(tar)
    run(`gzip -9 $(tar)`)
    tarball = tar * ".gz"
    return tarball, tree_hash
end

@testset "artifact store config" begin
    store = mktempdir()
    cache = mktempdir()
    @test store_group(; artifact_store=store, cachedir=cache).artifact_store == store
    @test store_group(; cachedir=cache).artifact_store === nothing
    @test_throws ArgumentError store_group(; artifact_store="relative/store")
    @test_throws ArgumentError store_group(; artifact_store="/")
    @test store_group(; artifact_store=store * "/", cachedir=cache).artifact_store == store
    @test store_group(; artifact_store="@scratch/", cachedir=cache).artifact_store ==
        A.get_scratch!(A, "artifact-store")
    @test_throws "does not support" store_group("win"; backend="kvm", guest="windows",
        default=Dict("cpus" => 1, "mem_gib" => 1), artifact_store=store)

    # No job may reach the store through a writable mount.
    @test check_artifact_store_paths([store_group(; artifact_store=store, cachedir=cache)]) === nothing
    for paths in ((; cachedir=joinpath(store, "pools")),
                  (; cachedir=dirname(store)),
                  (; sharedcache=joinpath(store, "shared")),
                  (; tempdir=store),
                  (; persistence_dir=joinpath(store, "persist")))
        groups = [store_group("yggy"; artifact_store=store, cachedir=cache),
                  store_group("other"; merge((; cachedir=mktempdir()), paths)...)]
        @test_throws ArgumentError check_artifact_store_paths(groups)
    end
    # The seatbelt profile also lets macOS jobs write below /private/var/folders
    # and to /Volumes/Julia*; `:` separates depots.
    mac(store) = [store_group("mac"; host=:macos, artifact_store=store, cachedir=cache)]
    @test check_artifact_store_paths(mac("/Users/julia/artifact-store")) === nothing
    for bad in ("/private/var/folders/xy/store", "/Volumes/Julia-1/store",
                "/Users/julia/volumes/julia/store", "/Users/julia/a:b")
        @test_throws ArgumentError check_artifact_store_paths(mac(bad))
    end
    # Nor through a link from what the scheduler writes or mounts, or to it.
    elsewhere = mktempdir()
    symlink(elsewhere, joinpath(cache, "link"))
    @test_throws ArgumentError check_artifact_store_paths(
        [store_group(; artifact_store=joinpath(cache, "link", "store"), cachedir=cache)])
    linked = mktempdir()
    symlink(cache, joinpath(linked, "depot"))
    @test_throws ArgumentError check_artifact_store_paths(
        [store_group(; artifact_store=linked, cachedir=cache)])
    linked = mktempdir()
    mkpath(joinpath(linked, "depot"))
    symlink(cache, joinpath(linked, "depot", "artifacts"))
    @test_throws ArgumentError check_artifact_store_paths(
        [store_group(; artifact_store=linked, cachedir=cache)])
    # Nor may stores alias or contain each other, or links lead out of one.
    alias, depot_alias = joinpath(mktempdir(), "store"), mktempdir()
    symlink(store, alias)
    symlink(joinpath(store, "depot"), joinpath(depot_alias, "depot"))
    for other in (alias, depot_alias, joinpath(store, ".sba-trash", "other"))
        @test_throws ArgumentError check_artifact_store_paths(
            [store_group("yggy"; artifact_store=store, cachedir=cache),
             store_group("other"; artifact_store=other, cachedir=mktempdir())])
    end
end

# julia-buildkite-plugin's depots in a pool, per backend.
const PLUGIN_LAYOUTS = ((:linux, joinpath("julia-buildkite-plugin", "depots")), (:macos, "depots"))

@testset "artifact store demand ($(host_os))" for (host_os, layout) in PLUGIN_LAYOUTS
    host = "testhost"
    root = mktempdir()
    store = mktempdir()
    brgs = [store_group("yggy"; host=host_os, artifact_store=store, cachedir=root),
            store_group("other"; host=host_os, cachedir=root)]
    a, b, c, d = (repeat(x, 40) for x in "abcd")
    function depot(slot, trust; pipeline="p1", name=pipeline, layout=layout)
        path = joinpath(root, "$(slot)-$(host).1", pipeline, trust, layout, name, "artifacts")
        mkpath(path)
        return path
    end
    # Pools count once, however many depots in them hold the artifact.
    for slot in ("yggy", "other"), name in (a, "not-a-hash", uppercase(c))
        mkpath(joinpath(depot(slot, "protected"), name))
    end
    mkpath(joinpath(depot("yggy", "protected"; name="extra"), a))
    mkpath(joinpath(depot("yggy", "protected"; pipeline="p2"), a))
    mkpath(joinpath(depot("yggy", "protected"; pipeline="p3"), b))
    # Untrusted pools are not demand.
    mkpath(joinpath(depot("yggy", "untrusted"), c))
    # Nor are depots in the other backend's layout.
    other_layout = only(l for (_, l) in PLUGIN_LAYOUTS if l != layout)
    mkpath(joinpath(depot("yggy", "protected"; layout=other_layout), d))
    # Nor are links anywhere below a pool.
    linked = joinpath(root, "yggy-$(host).1", "p4", "protected", layout, "p4")
    mkpath(linked)
    symlink(depot("yggy", "untrusted"), joinpath(linked, "artifacts"))
    symlink(dirname(depot("yggy", "untrusted")), joinpath(linked, "..", "linked"))
    plugin = joinpath(root, "yggy-$(host).1", "p5", "protected")
    mkpath(plugin)
    top = first(splitpath(layout))
    symlink(joinpath(root, "yggy-$(host).1", "p1", "untrusted", top), joinpath(plugin, top))
    @test artifact_demand(brgs, store; hostname=host) == Dict(a => 2, b => 1)
    @test isempty(artifact_demand(brgs, mktempdir(); hostname=host))
    # A pool a job made unreadable counts for nothing, but stops no other.
    unreadable = depot("yggy", "protected"; pipeline="p6")
    mkpath(joinpath(unreadable, b))
    chmod(dirname(unreadable), 0o000)
    try
        if !(try readdir(dirname(unreadable)); true catch; false end)  # root reads it anyway
            @test with_logger(() -> artifact_demand(brgs, store; hostname=host), NullLogger()) ==
                Dict(a => 2, b => 1)
        end
    finally
        chmod(dirname(unreadable), 0o755)
    end
end

@testset "artifact store import" begin
    dir = mktempdir()
    tarball, tree_hash = artifact_tarball(dir)
    wrong_tree = repeat("1", 40)
    requests = String[]
    handler(req) = (push!(requests, req.target);
        req.target in ("/artifact/$(tree_hash)", "/artifact/$(wrong_tree)") ?
            HTTP.Response(200, read(tarball)) : HTTP.Response(404))
    with_http_server(handler) do server
        store = mktempdir()
        A.prepare_artifact_store(store)
        quietly(f) = redirect_stderr(() -> with_logger(f, NullLogger()), devnull)

        # Only a tree matching its hash is published; nothing is left in
        # staging, whatever the outcome.
        @test !quietly(() -> import_artifact(store, wrong_tree; server))
        @test !quietly(() -> import_artifact(store, repeat("2", 40); server))
        @test unique(requests) == ["/artifact/$(wrong_tree)", "/artifact/$(repeat("2", 40))"]
        @test !ispath(artifact_store_path(store, wrong_tree))
        @test isempty(readdir(artifact_store_staging(store)))
        @test import_artifact(store, tree_hash; server)
        published = artifact_store_path(store, tree_hash)
        @test read(joinpath(published, "README"), String) == "a fixture\n"
        @test Sys.isexecutable(joinpath(published, "bin", "tool"))
        @test isempty(readdir(artifact_store_staging(store)))
        @test readdir(artifact_store_sizes(store)) == [tree_hash]
        @test artifact_store_bytes(store) > 0

        # A published artifact is not downloaded again.
        @test import_artifact(store, tree_hash; server, command=(args...) -> error("downloaded again"))

        # A download that takes too long is killed before staging is removed.
        pidfile = tempname()
        stuck(args...) = `/bin/sh -c "echo \$\$ > $(pidfile); exec sleep 60"`
        elapsed = @elapsed @test !quietly(() ->
            import_artifact(store, wrong_tree; server, command=stuck, timeout=1))
        @test elapsed < 30
        @test !success(pipeline(`kill -0 $(strip(read(pidfile, String)))`; stderr=devnull))
        @test isempty(readdir(artifact_store_staging(store)))
    end
end

@testset "artifact store filling" begin
    store = mktempdir()
    A.prepare_artifact_store(store)
    a, b, c, d, e = (repeat(x, 40) for x in "abcde")
    used = Ref(50)
    scheduler = (; retention=CacheRetention(RetentionConfig();
        fs_usage=path -> FsUsage(UInt64(3), 100, used[], 100 - used[])))
    imported = String[]
    statuses = []
    function fake_import(store, hash)
        push!(imported, hash)
        push!(statuses, A.ARTIFACT_STORE_STATUS[store])
        hash == e && return false
        mkpath(artifact_store_path(store, hash))
        write(joinpath(artifact_store_sizes(store), hash), "10")
        return true
    end
    fill(demand; budget=100, kwargs...) = with_logger(NullLogger()) do
        fill_artifact_store!(scheduler, store, demand; import_artifact=fake_import, budget, kwargs...)
    end
    # Only what is in 3 or more pools and missing is imported, most demanded first.
    mkpath(artifact_store_path(store, a))
    fill(Dict(a => 9, b => 3, c => 5, d => 2))
    @test imported == [c, b]
    # The status is up to date during a pass, not only after it.
    @test statuses == [(; bytes=0, not_promoted=2), (; bytes=10, not_promoted=1)]
    @test A.ARTIFACT_STORE_STATUS[store] == (; bytes=20, not_promoted=0)

    # A failed import is not retried within the day.
    empty!(imported)
    fill(Dict(e => 3))
    fill(Dict(e => 3))
    @test imported == [e]
    @test A.ARTIFACT_STORE_STATUS[store].not_promoted == 1

    # Nothing is imported over the budget or above the high-water mark (85%).
    empty!(imported)
    fill(Dict(d => 3); budget=20)
    @test isempty(imported)
    used[] = 90
    fill(Dict(d => 3))
    @test isempty(imported)
    @test A.ARTIFACT_STORE_STATUS[store] == (; bytes=20, not_promoted=1)
    metrics = A.scheduler_metrics(Dict("pool" => Dict("total_cpus" => 1, "free_cpus" => 1,
            "total_mem_gib" => 1, "free_mem_gib" => 1, "memory_braked" => false, "groups" => Dict()),
        "slots" => [], "artifact_stores" => Dict(store => Dict("bytes" => 20, "not_promoted" => 1))))
    @test occursin("sba_artifact_store_not_promoted{store=\"$(store)\"} 1", metrics)
end

@testset "artifact store pruning ($(host_os))" for (host_os, layout) in PLUGIN_LAYOUTS
    base = mktempdir()
    cache = joinpath(base, "cache")
    store = mktempdir()
    yggy = store_group("yggy"; host=host_os, artifact_store=store, cachedir=cache)
    other = store_group("other"; host=host_os, cachedir=cache)
    stored, kept = repeat("a", 40), repeat("b", 40)
    mkpath(artifact_store_path(store, stored))
    function artifacts(brg, pipeline, trust="protected")
        dir = joinpath(cache, Slot(brg, 1).name, pipeline, trust, layout, pipeline, "artifacts")
        mkpath.(joinpath.(dir, (stored, kept)))
        write(joinpath(dir, "Overrides.toml"), "")
        return dir
    end
    protected, untrusted = artifacts(yggy, "p1"), artifacts(yggy, "p1", "untrusted")
    untouched = [artifacts(other, "p1"), artifacts(yggy, "leased")]
    # A linked depot is not followed; a link named like a stored hash goes,
    # without its target.
    linked = joinpath(cache, Slot(yggy, 1).name, "p2", "protected", layout, "p2")
    mkpath(linked)
    symlink(untouched[1], joinpath(linked, "artifacts"))
    target = mktempdir()
    link = artifacts(yggy, "p3")
    rm(joinpath(link, stored))
    symlink(target, joinpath(link, stored))
    pruned(dir) = !ispath(joinpath(dir, stored)) && isdir(joinpath(dir, kept)) &&
        isfile(joinpath(dir, "Overrides.toml"))
    sweep(retention) = with_logger(NullLogger()) do
        scheduler, _, _ = retention_scheduler([yggy, other], base; retention)
        scheduler.retention.leased[joinpath(cache, Slot(yggy, 1).name, "leased", "protected")] = 1
        retention_pass!(scheduler; force_sweep=true)
        return scheduler.retention
    end
    # Nothing with cache retention off.
    @test sweep(RetentionConfig(; enabled=false)).pruned == 0
    @test !any(pruned, [protected, untrusted])
    retention = sweep(RetentionConfig(; max_age_days=0))
    @test retention.pruned == 3
    @test pruned(protected) && pruned(untrusted) && pruned(link)
    @test all(dir -> isdir(joinpath(dir, stored)) && isdir(joinpath(dir, kept)), untouched)
    @test isdir(target)
    @test isempty(readdir(joinpath(cache, ".sba-trash")))
    # Julia finds the pruned artifact in the store, behind the pool's depot.
    depots = join([dirname(protected), A.artifact_store_depot(store)], ":")
    found = read(addenv(`$(Base.julia_cmd()) --startup-file=no -e
        'using Artifacts; print(artifact_path(Base.SHA1(ARGS[1])))' $(stored)`,
        "JULIA_DEPOT_PATH" => depots, "JULIA_LOAD_PATH" => "@stdlib"), String)
    @test found == artifact_store_path(store, stored)
end

@testset "artifact store eviction" begin
    base = mktempdir()
    cache = joinpath(base, "cache")
    store = mktempdir()
    yggy, ygg2 = (store_group(name; artifact_store=store, cachedir=cache) for name in ("yggy", "ygg2"))
    other = store_group("other"; cachedir=cache)
    scheduler, _, _ = retention_scheduler([yggy, ygg2, other], base)
    retention = scheduler.retention
    A.prepare_artifact_store(store)
    # Imported newest first, so that age and name order differ.
    hashes = [repeat(x, 40) for x in "abcde"]
    for (i, hash) in enumerate(hashes)
        mkpath(artifact_store_path(store, hash))
        write(joinpath(artifact_store_sizes(store), hash), "10")
        run(`touch -t 20260101000$(6 - i) $(joinpath(artifact_store_sizes(store), hash))`)
    end
    evict(budget; demand=Dict{String,Int}()) = length(with_logger(NullLogger()) do
        evict_artifact_store!(scheduler, store, demand; budget)
    end)
    pool(brg) = joinpath(cache, Slot(brg, 1).name, "p1", "protected")
    @test evict(50) == 0
    # A job of either group using the store holds off eviction; other jobs do not.
    acquire_pool!(retention, pool(other); shared=false)
    acquire_pool!(retention, joinpath(base, "shared", "p1", "protected"); shared=true)
    for brg in (yggy, ygg2)
        acquire_pool!(retention, pool(brg); shared=false)
        @test evict(40) == 0
        release_pool!(retention, pool(brg); shared=false)
    end
    @test artifact_store_bytes(store) == 50
    # Down to 80% of the budget (31.2 of 39), oldest first; what was evicted
    # before a failure counts.
    renames = Ref(0)
    retention.rename = (src, dst) -> (renames[] += 1) == 2 ? error("injected") : rename_exact(src, dst)
    @test_throws ErrorException evict(39)
    @test A.ARTIFACT_STORE_EVICTIONS[store] == 1
    retention.rename = rename_exact
    mkpath(joinpath(store, ".sba-trash", "stale"))
    @test evict(39) == 1
    @test all(hash -> !ispath(artifact_store_path(store, hash)), hashes[4:5])
    @test all(hash -> ispath(artifact_store_path(store, hash)), hashes[1:3])
    @test sort(readdir(artifact_store_sizes(store))) == hashes[1:3]
    @test artifact_store_bytes(store) == 30
    @test isempty(readdir(joinpath(store, ".sba-trash")))
    @test A.ARTIFACT_STORE_EVICTIONS[store] == 2
    fill_artifact_store!(scheduler, store, Dict{String,Int}(); budget=39)
    metrics = scheduler_metrics(scheduler_status_snapshot(scheduler))
    @test occursin("sba_artifact_store_evictions_total{store=\"$(store)\"} 2", metrics)

    # Entries out of demand go first: b, not c, which is older but in 3 pools.
    a, b, c, d = hashes
    @test with_logger(() -> evict_artifact_store!(scheduler, store, Dict(b => 2, c => 3);
        budget=25), NullLogger()) == [b]
    # When demand exceeds the budget, the oldest in demand goes too, with a
    # warning, and is not imported again in the same pass.
    for i in 1:3, hash in (a, c, d)
        mkpath(joinpath(cache, "yggy-$(A.get_short_hostname()).$(i)", "p1", "protected",
                        "julia-buildkite-plugin", "depots", "p1", "artifacts", hash))
    end
    imported = String[]
    function fake_import(store, hash)
        push!(imported, hash)
        mkpath(artifact_store_path(store, hash))
        write(joinpath(artifact_store_sizes(store), hash), "10")
        return true
    end
    @test_logs (:warn, r"removed artifacts in demand") match_mode=:any A.artifact_store_pass!(
        scheduler, store; budget=15, import_artifact=fake_import)
    @test !ispath(artifact_store_path(store, c))
    @test imported == [d]
    @test A.ARTIFACT_STORE_STATUS[store].not_promoted == 1
end

@testset "artifact store worker" begin
    # At start, only downloads left behind are removed from staging, and
    # evicted entries from the trash.
    store = mktempdir()
    mkpath(joinpath(artifact_store_staging(store), "import-stale", "depot"))
    mkpath(joinpath(artifact_store_staging(store), "other"))
    mkpath(joinpath(store, ".sba-trash", "stale"))
    worker = @async A.artifact_store_forever!(
        (; retention=CacheRetention(RetentionConfig()), brgs=BuildkiteRunnerGroup[]),
        [store]; interval=3600)
    @test timedwait(() -> !ispath(joinpath(artifact_store_staging(store), "import-stale")), 30.0) === :ok
    @test timedwait(() -> !ispath(joinpath(store, ".sba-trash", "stale")), 30.0) === :ok
    @test isdir(joinpath(artifact_store_staging(store), "other"))
    @test isdir(joinpath(store, "depot", "artifacts"))
    @test !istaskdone(worker)
    schedule(worker, InterruptException(); error=true)
end

@testset "artifact store in Linux jobs" begin
    if Sys.islinux()
        store = mktempdir()
        brg = store_group(; artifact_store=store, cachedir=mktempdir())
        config = Sandbox.SandboxConfig(brg; agent_name=Slot(brg, 1).name,
            cache_path=mktempdir(), shared_cache_path=nothing, temp_path=mktempdir(),
            rootfs_dir=mktempdir())
        @test config.mounts["/artifact-store"].host_path == joinpath(store, "depot")
        @test config.mounts["/artifact-store"].type == Sandbox.MountType.ReadOnly
        @test config.env["JULIA_DEPOT_PATH"] == "/artifact-store"
        # Groups without a store see none, and keep Julia's default depots.
        plain = store_group(; cachedir=mktempdir())
        config = Sandbox.SandboxConfig(plain; agent_name=Slot(plain, 1).name,
            cache_path=mktempdir(), shared_cache_path=nothing, temp_path=mktempdir(),
            rootfs_dir=mktempdir())
        @test !haskey(config.mounts, "/artifact-store")
        @test !haskey(config.env, "JULIA_DEPOT_PATH")
    end
end

@testset "artifact store in macOS jobs" begin
    if Sys.isapple() && Sys.which("sandbox-exec") !== nothing
        # Not in the default temporary directory, which jobs can write.
        mktempdir("/private/tmp") do root
            store = joinpath(root, "store")
            brg = store_group("mac"; host=:macos, artifact_store=store,
                cachedir=joinpath(root, "cache"), tempdir=joinpath(root, "tmp"))
            entry = artifact_store_path(store, repeat("a", 40))
            script = """
                cat $(entry)/file
                cat $(store)/sizes/x 2>/dev/null && echo leaked
                touch $(entry)/new 2>/dev/null && echo created
                echo changed > $(entry)/file 2>/dev/null && echo changed
                mv $(entry) $(entry).moved 2>/dev/null && echo moved
                rm -rf $(entry) 2>/dev/null && echo removed
                ln $(entry)/file \$HOME/link 2>/dev/null && echo linked
                echo \$JULIA_DEPOT_PATH
                """
            output = seatbelt_setup(brg; backend=MacSeatbeltBackend(joinpath(root, "logs");
                    idle_cleanup=nothing), agent_name=Slot(brg, 1).name,
                    cache_path=joinpath(root, "cache", "pool"), temp_path=joinpath(root, "tmp", "slot"),
                    alloc=Allocation(1)) do sb_path, env, _
                # The job's depot exists before the store task created it.
                @test isdir(A.artifact_store_depot(store))
                mkpath.((entry, joinpath(store, "sizes")))
                write(joinpath(entry, "file"), "stored\n")
                write(joinpath(store, "sizes", "x"), "10")
                read(setenv(`sandbox-exec -f $(sb_path) /bin/sh -c $(script)`, env), String)
            end
            @test split(strip(output), '\n') == ["stored", ":" * A.artifact_store_depot(store)]
            @test readdir(entry) == ["file"]
            @test read(joinpath(entry, "file"), String) == "stored\n"
        end
    end
end

# Needs the same delegated cgroup as "Linux job cgroups (delegated)".
@testset "artifact store in Linux jobs (delegated)" begin
    if Sys.islinux() && get(ENV, "SANDBOXED_BUILDKITE_AGENT_TEST_CGROUPS", "") == "1"
        root = scheduler_cgroup_root()
        cpus = A.setup_job_cgroups!(root)
        secrets = mktempdir()
        Base.write(joinpath(secrets, "buildkite-agent-token"), "secret-token\n")
        store = mktempdir()
        brg = BuildkiteRunnerGroup("store", Dict{String,Any}(
            "queues" => "build", "max_slots" => 1, "cachedir" => mktempdir(),
            "tempdir" => mktempdir(), "secrets_dir" => secrets, "artifact_store" => store,
            "tags" => Dict{String,String}("os" => "linux", "arch" => "x86_64",
                "sandbox_capable" => "true"),
        ); host=:linux)
        backend = LinuxSandboxBackend(mktempdir())
        backend.root = root
        backend.cpus = cpus
        slot = Slot(brg, 1)
        job = sized_job("store-probe"; queue="build", tags=["sched_cpus=1", "sched_mem_gib=1"])
        handle = prepare(backend, slot, job, cache_plan(slot, job, :untrusted),
            Allocation(1, 1, 1, 1, 0))
        hash = repeat("a", 40)
        try
            # An artifact published while the job runs shows up in it; the job
            # can change nothing in the store, not even by remounting it. The
            # job's /tmp is a host directory, through which it says when it has
            # seen the artifact missing.
            script = """
                [ -e /artifact-store/artifacts/$(hash) ] || touch /tmp/missing
                for i in \$(seq 600); do
                    [ -e /artifact-store/artifacts/$(hash)/file ] && break
                    sleep 0.1
                done
                cat /artifact-store/artifacts/$(hash)/file
                touch /artifact-store/artifacts/new 2>/dev/null && echo created
                echo changed > /artifact-store/artifacts/$(hash)/file 2>/dev/null && echo changed
                mount -o remount,rw,bind /artifact-store 2>&1 |
                    grep -qi -e "permission denied" -e "not permitted" || echo "remount not refused"
                echo \$JULIA_DEPOT_PATH
                """
            output = Ref("")
            reader = @async output[] = read(A.sandbox_command(handle; cmd=`/bin/sh -c $(script)`), String)
            marker = joinpath(handle.config.mounts["/tmp"].host_path, "missing")
            @test timedwait(() -> isfile(marker), 60.0) === :ok
            mkpath(artifact_store_staging(store))
            staged = mktempdir(artifact_store_staging(store))
            write(joinpath(staged, "file"), "published\n")
            mkpath(dirname(artifact_store_path(store, hash)))
            A.rename_exact(staged, artifact_store_path(store, hash))
            @test timedwait(() -> istaskdone(reader), 120.0) === :ok
            @test split(strip(output[]), '\n') == ["published", "/artifact-store"]
            @test read(joinpath(artifact_store_path(store, hash), "file"), String) == "published\n"
        finally
            @test reap(handle) === true
        end
    end
end
