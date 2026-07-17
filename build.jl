#!/usr/bin/env julia

# Run a local Julia checkout in a throwaway FreeBSD KVM worker.  The source is
# mounted read-only through 9p and cloned to the worker's persistent cache,
# so only committed changes are picked up and incremental builds stay available.

include(joinpath(@__DIR__, "src", "SandboxedBuildkiteAgent.jl"))
using .SandboxedBuildkiteAgent

const SOURCE_DIR = "/home/tim/Julia/src/julia"
const CACHE_DIR = "/tmp/julia-buildkite-smoke/cache-bsd"
const TEMP_DIR = "/tmp/julia-buildkite-smoke/tmp-bsd"

function usage()
    println("usage: julia --project build.jl [--probe | --build | --test] [source-dir] [jobs]")
end

function parse_args(args)
    action = :build
    source_dir = SOURCE_DIR
    jobs = 8
    for arg in args
        if arg == "--probe"
            action = :probe
        elseif arg == "--build"
            action = :build
        elseif arg == "--test"
            action = :test
        elseif startswith(arg, "-")
            usage()
            error("unknown option: $(arg)")
        elseif isdir(arg)
            source_dir = abspath(arg)
        else
            parsed = tryparse(Int, arg)
            parsed === nothing && error("expected a source directory or job count, got: $(arg)")
            parsed > 0 || error("job count must be positive")
            jobs = parsed
        end
    end
    isdir(source_dir) || error("Julia source directory does not exist: $(source_dir)")
    return (; action, source_dir, jobs)
end

function qga_exec(handle, command; capture_output=false)
    payload = Dict(
        "execute" => "guest-exec",
        "arguments" => Dict(
            "path" => "/bin/sh",
            "arg" => ["-c", command],
            "env" => ["PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"],
            "capture-output" => capture_output,
        ),
    )
    response = SandboxedBuildkiteAgent.qga_command_json(handle.domain, payload)
    return response["return"]["pid"]
end

function wait_for_qga_exec(handle, pid)
    while true
        status = SandboxedBuildkiteAgent.guest_exec_status(handle.domain, pid)
        get(status, "exited", false) && return Int(get(status, "exitcode", 1))
        sleep(2)
    end
end

function guest_command(action, jobs)
    build_command = action == :probe ? "" : action == :build ?
        "gmake -j$(jobs)" : "gmake -j$(jobs) testall JULIA=./usr/bin/julia"
    return """
set -eu
serial=/dev/ttyu0
[ -e \"\$serial\" ] || serial=/dev/console
exec >> \"\$serial\" 2>&1

source=/mnt/julia-source
mounted=false
cleanup() {
    if [ \"\$mounted\" = true ]; then
        umount \"\$source\" || true
    fi
    cd /
    zpool export cache || true
}
trap cleanup EXIT INT TERM

mkdir -p \"\$source\"
kldload virtio_p9fs 2>/dev/null || true
mount -t p9fs host-source \"\$source\"
mounted=true
test -f \"\$source/VERSION\"
git -c safe.directory=\"\$source\" -C \"\$source\" rev-parse HEAD

if [ \"$(action)\" = probe ]; then
    exit 0
fi

work=/cache/julia-local
commit=\$(git -c safe.directory=\"\$source\" -C \"\$source\" rev-parse HEAD)
if [ -d \"\$work/.git\" ]; then
    git -c safe.directory=\"\$source\" -C \"\$work\" fetch --no-tags \"\$source\" \"\$commit\"
    git -C \"\$work\" reset --hard FETCH_HEAD
else
    rm -rf \"\$work\"
    git -c safe.directory=\"\$source\" clone --no-local \"\$source\" \"\$work\"
    git -C \"\$work\" checkout --force \"\$commit\"
fi

cd \"\$work\"
$(build_command)
"""
end

function main(args)
    options = parse_args(args)
    brg = BuildkiteRunnerGroup("freebsd15-local", Dict{String,Any}(
        "backend" => SandboxedBuildkiteAgent.BACKEND_KVM,
        "guest" => "freebsd",
        "queues" => "build",
        "job_cpus" => options.jobs,
        "max_jobs" => 1,
        "cachedir" => CACHE_DIR,
        "tempdir" => TEMP_DIR,
        "source_dir" => options.source_dir,
        "tags" => Dict{String,String}("os" => "freebsd", "arch" => "x86_64"),
    ); host=:linux, total_cpus=options.jobs)
    backend = KVMBackend(joinpath(TEMP_DIR, "logs"), [brg]; total_cpus=options.jobs)
    SandboxedBuildkiteAgent.check_config(backend, [brg])

    job = Job("local-$(time_ns())", "local-julia-build", ["queue=build"])
    slot = Slot(brg, 1)
    plan = SandboxedBuildkiteAgent.cache_plan(slot, job, :trusted)
    allocation = SandboxedBuildkiteAgent.Allocation(options.jobs, join(0:options.jobs-1, ","))
    handle = SandboxedBuildkiteAgent.prepare(backend, slot, job, plan, allocation)
    println("FreeBSD worker serial log: ", SandboxedBuildkiteAgent.kvm_serial_log_path(handle.log_path))

    try
        run(SandboxedBuildkiteAgent.virsh("create", handle.xml_path))
        SandboxedBuildkiteAgent.wait_for_guest_agent(handle.domain)
        pid = qga_exec(handle, guest_command(options.action, options.jobs))
        status = wait_for_qga_exec(handle, pid)
        status == 0 || error("FreeBSD worker $(options.action) failed with exit code $(status)")
    finally
        SandboxedBuildkiteAgent.reap(handle)
    end
end

main(ARGS)
