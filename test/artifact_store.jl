# The artifact store (src/artifact_store.jl). Included from runtests.jl, whose
# helpers (`with_http_server`, `sized_job`) it uses.

using Tar
import SandboxedBuildkiteAgent: artifact_demand, import_artifact, fill_artifact_store!,
    artifact_store_path, artifact_store_staging, artifact_store_sizes, artifact_store_bytes,
    check_artifact_store_paths, CacheRetention, RetentionConfig, FsUsage

const A = SandboxedBuildkiteAgent

# Its own tempdir, since the default one, the system's, holds every `mktempdir()`.
store_group(name="yggy"; host=:linux, kwargs...) =
    BuildkiteRunnerGroup(name, Dict{String,Any}("queues" => "build", "max_slots" => 1,
        "default" => Dict("cpus" => 1), "tempdir" => mktempdir(),
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
    @test_throws ArgumentError store_group("mac"; host=:macos, artifact_store=store)

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
end

@testset "artifact store demand" begin
    host = "testhost"
    root = mktempdir()
    store = mktempdir()
    brgs = [store_group("yggy"; artifact_store=store, cachedir=root),
            store_group("other"; cachedir=root)]
    a, b, c = repeat("a", 40), repeat("b", 40), repeat("c", 40)
    function depot(slot, trust; pipeline="p1", name=pipeline)
        path = joinpath(root, "$(slot)-$(host).1", pipeline, trust,
                        "julia-buildkite-plugin", "depots", name, "artifacts")
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
    # Nor are links anywhere below a pool.
    linked = joinpath(root, "yggy-$(host).1", "p4", "protected", "julia-buildkite-plugin", "depots", "p4")
    mkpath(linked)
    symlink(depot("yggy", "untrusted"), joinpath(linked, "artifacts"))
    symlink(dirname(depot("yggy", "untrusted")), joinpath(linked, "..", "linked"))
    plugin = joinpath(root, "yggy-$(host).1", "p5", "protected")
    mkpath(plugin)
    symlink(dirname(dirname(dirname(depot("yggy", "untrusted")))), joinpath(plugin, "julia-buildkite-plugin"))
    @test artifact_demand(brgs, store; hostname=host) == Dict(a => 2, b => 1)
    @test isempty(artifact_demand(brgs, mktempdir(); hostname=host))
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
    fill(demand; kwargs...) = with_logger(NullLogger()) do
        fill_artifact_store!(scheduler, store, demand; import_artifact=fake_import, kwargs...)
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

@testset "artifact store worker" begin
    # At start, only downloads left behind are removed from staging.
    store = mktempdir()
    mkpath(joinpath(artifact_store_staging(store), "import-stale", "depot"))
    mkpath(joinpath(artifact_store_staging(store), "other"))
    worker = @async A.artifact_store_forever!((; retention=nothing, brgs=BuildkiteRunnerGroup[]),
        [store]; interval=3600)
    @test timedwait(() -> !ispath(joinpath(artifact_store_staging(store), "import-stale")), 30.0) === :ok
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
