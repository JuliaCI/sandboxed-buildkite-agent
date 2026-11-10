# The group/prefix/root fields drive the stale-domain sweep and are derived
# once here, so `cleanup` works on teardown paths that never set up a backend.
struct KVMBackend <: PlatformBackend
    logdir::String
    groups::Vector{String}
    domain_prefixes::Vector{String}
    scratch_roots::Vector{String}
    cache_roots::Vector{String}

    function KVMBackend(logdir::String, brgs::Vector{BuildkiteRunnerGroup}=BuildkiteRunnerGroup[])
        kvm_brgs = [brg for brg in brgs if brg.backend == BACKEND_KVM]
        groups = sort(unique(brg.name for brg in kvm_brgs))
        return new(logdir, groups, kvm_group_prefixes(groups),
            kvm_scratch_roots(kvm_brgs), kvm_cache_roots(kvm_brgs))
    end
end

const KVM_URI = "qemu:///system"
# The libvirt network the XML templates attach guests to.
const KVM_BRIDGE = "virbr0"
# FreeBSD guests answer within seconds on an idle host, but booting together
# with a dozen other guests after a scheduler start they took over 30 s (amdci6,
# 2026-11-03), which failed their jobs. A crashed guest still fails fast through
# the domain-running check in `wait_for_guest_agent`.
const KVM_AGENT_READY_TIMEOUT = 120.0
# Windows boots slower than FreeBSD, so keep its timeout the longer one.
const KVM_WINDOWS_AGENT_READY_TIMEOUT = 180.0
const KVM_WINDOWS_AGENT_STABLE_FOR = 10.0
const KVM_AGENT_POLL_INTERVAL = 2.0
const KVM_GUEST_EXEC_STATUS_GRACE = 30.0
# Allow time to flush the persistent cache before resorting to a hard power-off.
const KVM_GRACEFUL_SHUTDOWN_TIMEOUT = 180.0
const KVM_SHUTDOWN_POLL_INTERVAL = 1.0
const KVM_WINDOWS_JOB_TIMEOUT = 12 * 60 * 60.0
const KVM_WINDOWS_SERVICE_START_TIMEOUT = 5 * 60.0
const KVM_WINDOWS_EXIT_PATH = raw"C:\buildkite-agent\run-buildkite-job.exit"
const KVM_WINDOWS_LAUNCHER_LOG_PATH = raw"C:\buildkite-agent\run-buildkite-job-launcher.log"
const KVM_WINDOWS_SERVICE_WRAPPER_LOG_PATH = raw"C:\buildkite-agent\run-buildkite-job-service.log"
const KVM_WINDOWS_SERVICE_LOG_PATH = raw"C:\buildkite-agent\run-buildkite-job.log"

# What a guest costs the host beyond its RAM: QEMU's own memory and the kernel's
# (page tables, vhost). The domain cgroup's anonymous memory peaks about 50 MiB
# above guest RAM for both Windows and FreeBSD guests. Its `memory.peak` is
# larger (up to 54 GiB for a 24 GiB guest) because the cache disks' page cache
# is charged there too, but that cache is reclaimable and is not reserved.
const KVM_HOST_OVERHEAD_GIB = 2
kvm_host_overhead_gib(::Integer) = KVM_HOST_OVERHEAD_GIB
kvm_reserved_mem_gib(guest_gib::Integer) = Int(guest_gib) + kvm_host_overhead_gib(guest_gib)

#
# Job resource usage
#

# A guest as a `ResourceSource` (see resources.jl). CPU comes from the host,
# with no guest involvement, through `virsh domstats --vcpu --cpu-total`:
#
# - `vcpu.N.time`, the host CPU time of vCPU thread N. An idle vCPU halts and
#   its thread sleeps, so this is the guest's busy time on that vCPU plus exit
#   handling and halt polling. Hosts that report polling
#   (`cpu.haltpoll.*.time`) put it at about 0.5% of the busy time; it is not
#   subtracted, as libvirt omits it whenever it cannot read it, which would
#   make the busy time jump by its whole cumulative value.
# - `vcpu.N.delay`, the time the vCPU thread was runnable but waiting for a host
#   CPU: the job's wait time.
# - `cpu.time`, the whole domain cgroup; what it has beyond the vCPU threads is
#   QEMU's own work (device emulation, I/O threads), reported in the details.
#
# The details also carry QEMU's resident memory (`balloon.rss`), the VM's cost
# to the host. It only grows (Windows touches all its RAM while booting), so it
# says nothing about what the job needed.
#
# Newer hosts also report per-vCPU KVM statistics (`halt_wait_ns` and so on);
# older ones (libvirt 8.0 on Linux 5.15) do not, so only the fields above are
# used.
#
# Memory needs the guest's own view, which differs per guest OS: the source
# keeps a `WindowsBalloonMemory` or a `FreeBSDSysctlMemory` (`kvm_guest_memory`),
# each with a `sample_guest_memory!` and a `guest_memory_details` method.
#
# The record is written into the guest with the guest agent's file commands, at
# the path the `pre-exit` hook reads (`KVM_RESOURCE_RECORD_PATHS`). It lives on
# the guest's disposable OS disk, so unlike on Linux the job may be able to
# overwrite it; it can set its own meta-data anyway. If the directory does not
# exist (images built before it was added), writing fails and the sampler
# tries again after the next sample.
#
# Every virsh call of a sample runs under a deadline, the sample's time budget,
# and is killed when it runs out or when `stop_resources!` interrupts the
# sample, so a stuck libvirt or guest agent can delay neither the sampler nor
# the VM's teardown. `domstats --nowait` (libvirt 4.5+) skips the figures it
# would have to wait for another domain job for, rather than waiting.
#
# Killing virsh does not undo what the guest agent does with the command, and
# the agent keeps a file handle open until it is closed or the agent exits. So
# the last part of the budget is kept for closing the record's handle, a handle
# whose close failed is closed again at the next sample, and a handle that
# cannot be closed (or an open whose result is unknown) is counted as lost.
# Publishing stops after a few lost handles; the VM goes with the job anyway.
const KVM_RESOURCE_RECORD_PATHS = Dict(
    "windows" => raw"C:\buildkite-agent\resources\resources",
    "freebsd" => "/var/run/sandboxed-buildkite-agent/resources",
)
# Seconds a sample, publication included, may take; less than the interval.
# The last quarter of it (at most 2 s) is only for closing file handles.
const KVM_RESOURCE_SAMPLE_BUDGET = 8.0
# Bounds each guest agent call within that, on the guest agent's side.
const KVM_RESOURCE_AGENT_TIMEOUT = 5
const KVM_RESOURCE_CLOSE_ATTEMPTS = 3
const KVM_RESOURCE_MAX_LOST_HANDLES = 4

kvm_guest_memory(guest::AbstractString) =
    guest == "windows" ? WindowsBalloonMemory() :
    guest == "freebsd" ? FreeBSDSysctlMemory() : nothing

# Windows reports its memory through the virtio balloon: the guest's
# BalloonService (`blnsvr.exe`, installed in the base image) sends statistics
# every `<stats period>` seconds of the domain XML, and QEMU keeps the latest.
# What virtio-win 0.1.229 fills in, in KiB as libvirt reports them:
#
# - `available`: `GlobalMemoryStatusEx` total physical memory;
# - `unused`: its available physical memory, i.e. the standby (cached), free
#   and zeroed page lists;
# - `disk_caches`: the `Cache Bytes` counter, the file cache's working set;
# - `usable`: `unused` plus half of `disk_caches`, a guess for ballooning that
#   is not used here;
# - `swap_in`/`swap_out`: cumulative paging I/O (`Pages Input/sec`,
#   `Pages Output/sec` times the page size), which includes memory-mapped
#   files.
#
# So memory in use (Task Manager's "In use") is `available - unused`; that is
# the total, and needed is the total less the file cache. Windows does not
# report its page file use through the balloon, so there is no swap figure.
#
# Without the service (older images) the fields are missing. If it stops, QEMU
# keeps returning its last statistics, so old ones (by `last-update`, the
# host's clock) are ignored.
mutable struct WindowsBalloonMemory
    last_update::Union{Nothing,Int}
    guest_bytes::Union{Nothing,Int}
    peak_cache_bytes::Union{Nothing,Int}
    paged_first::Union{Nothing,Tuple{Int,Int}}
    paged_last::Union{Nothing,Tuple{Int,Int}}
end

WindowsBalloonMemory() = WindowsBalloonMemory(nothing, nothing, nothing, nothing, nothing)

const KVM_BALLOON_STATS_MAX_AGE = 60

function sample_guest_memory!(memory::WindowsBalloonMemory, domain, stats; now::Real=time())
    kib(key) = (v = tryparse(Int, get(stats, "balloon.$(key)", "")); v === nothing ? nothing : 1024 * v)
    total, unused, cache = kib("available"), kib("unused"), kib("disk_caches")
    updated = tryparse(Int, get(stats, "balloon.last-update", ""))
    (total === nothing || unused === nothing || updated === nothing) && return nothing
    # Old, or the statistics of the previous sample again: no new reading.
    (now - updated > KVM_BALLOON_STATS_MAX_AGE || updated == memory.last_update) && return nothing
    memory.last_update = updated
    in_use = max(total - unused, 0)
    cache = cache === nothing ? 0 : clamp(cache, 0, in_use)
    memory.guest_bytes = total
    memory.peak_cache_bytes = maxpeak(memory.peak_cache_bytes, cache)
    paged_in, paged_out = kib("swap_in"), kib("swap_out")
    if paged_in !== nothing && paged_out !== nothing
        memory.paged_first === nothing && (memory.paged_first = (paged_in, paged_out))
        memory.paged_last = (paged_in, paged_out)
    end
    return (; needed_bytes = in_use - cache, total_bytes = in_use, swap_bytes = nothing,
            memory_at = Float64(updated))
end

function guest_memory_details(memory::WindowsBalloonMemory)
    first, last = memory.paged_first, memory.paged_last
    paged(i) = first === nothing || last === nothing ? nothing : last[i] - first[i]
    return Dict{String,Any}(
        "guest_memory_bytes" => memory.guest_bytes,
        "peak_file_cache_bytes" => memory.peak_cache_bytes,
        "paged_in_bytes" => paged(1),
        "paged_out_bytes" => paged(2),
    )
end

# FreeBSD's balloon driver does not do statistics and its guest agent has no
# memory command, so the sampler runs `sysctl` in the guest: each sample
# collects the previous sample's `guest-exec` (it takes milliseconds) and starts
# the next, so readings lag one sample behind and there is at most one pending
# in the guest agent. Pages, from the page queues:
#
# - total is active + inactive + laundry + wired, everything but free pages;
# - needed is active + laundry + wired less the ZFS ARC. The ARC is wired but
#   shrinks under pressure, and both the OS and the cache disk are ZFS, so with
#   it every job would look like it needed most of the guest's RAM. Inactive
#   pages are mostly the file cache, but anonymous memory can age into them
#   too, and the ARC does not always shrink in time (a guest with a large ARC
#   has been seen to swap and kill a job), so this is a lower bound and the
#   record says so (`peak_needed_is_lower_bound`); the queues at its peak go
#   into the details.
#
# There is no sysctl for swap in use (`vm.swap_reserved` is the overcommit
# reservation, `vm.swap_info` a binary table), so `swapctl -s` adds it. The
# images have the 2 GiB swap partition bsdinstall creates.
#
# The job runs as a user with sudo and could fake the output, so it is parsed
# by name, and anything implausible is dropped.
mutable struct FreeBSDSysctlMemory
    pending::Union{Nothing,Int}     # guest-exec pid
    pending_at::Float64             # when it was started
    failures::Int
    guest_bytes::Union{Nothing,Int}
    swap_total_bytes::Union{Nothing,Int}
    peak_needed_bytes::Union{Nothing,Int}
    at_peak::Union{Nothing,Dict{String,Int}}
    peak_arc_bytes::Union{Nothing,Int}
    paged_first::Union{Nothing,Tuple{Int,Int}}
    paged_last::Union{Nothing,Tuple{Int,Int}}
end

FreeBSDSysctlMemory() = FreeBSDSysctlMemory(nothing, 0.0, 0, nothing, nothing, nothing, nothing,
                                            nothing, nothing, nothing)

const FREEBSD_MEMORY_SYSCTLS = Dict(
    "hw.pagesize" => "page",
    "vm.stats.vm.v_page_count" => "pages",
    "vm.stats.vm.v_active_count" => "active",
    "vm.stats.vm.v_inactive_count" => "inactive",
    "vm.stats.vm.v_laundry_count" => "laundry",
    "vm.stats.vm.v_wire_count" => "wired",
    "vm.stats.vm.v_free_count" => "free",
    "kstat.zfs.misc.arcstats.size" => "arc",
    "vm.stats.vm.v_swappgsin" => "swapped_in",
    "vm.stats.vm.v_swappgsout" => "swapped_out",
    "vm.swap_total" => "swap_total",
)
# Names rather than `-n`, so a missing one (no ZFS) cannot shift the others.
const FREEBSD_MEMORY_COMMAND = string("/sbin/sysctl -i ", join(sort(collect(keys(FREEBSD_MEMORY_SYSCTLS))), " "),
                                      "; /sbin/swapctl -sk")
# Consecutive failed status queries after which a pending command is given up
# on (the guest agent restarted, or forgot it).
const FREEBSD_MEMORY_MAX_FAILURES = 3
# The real output is about 450 bytes.
const FREEBSD_MEMORY_MAX_OUTPUT = 4096

# Bytes per queue from the command's output, or `nothing`.
function parse_freebsd_memory(output::AbstractString)
    values = Dict{String,Int}()
    swap_used = nothing
    for line in eachline(IOBuffer(output))
        m = match(r"^([\w.]+): (\d{1,18})$", line)
        if m !== nothing
            key = get(FREEBSD_MEMORY_SYSCTLS, m[1], nothing)
            key === nothing || (values[key] = parse(Int, m[2]))
            continue
        end
        m = match(r"^Total:\s+\d{1,15}\s+(\d{1,15})$", line)
        m === nothing || (swap_used = 1024 * parse(Int, m[1]))
    end
    page = get(values, "page", 0)
    (ispow2(page) && 4096 <= page <= 65536) || return nothing
    pages = ("active", "inactive", "laundry", "wired", "free")
    all(k -> haskey(values, k), pages) || return nothing
    # More pages than 2^40 (4 PiB) is no reading.
    any(k -> values[k] >= 2^40, pages) && return nothing
    bytes = Dict{String,Int}(k => page * values[k] for k in pages)
    for k in ("pages", "swapped_in", "swapped_out")
        haskey(values, k) && values[k] < 2^40 && (bytes[k] = page * values[k])
    end
    used = bytes["active"] + bytes["inactive"] + bytes["laundry"] + bytes["wired"]
    bytes["arc"] = clamp(get(values, "arc", 0), 0, bytes["wired"])
    haskey(values, "swap_total") && (bytes["swap_total"] = values["swap_total"])
    swap = swap_used !== nothing ? swap_used : get(values, "swap_total", -1) == 0 ? 0 : nothing
    return (; bytes, total_bytes = used,
            needed_bytes = used - bytes["inactive"] - bytes["arc"], swap_bytes = swap)
end

function freebsd_memory_start!(memory::FreeBSDSysctlMemory, source)
    response = kvm_agent_command(source, Dict(
        "execute" => "guest-exec",
        "arguments" => Dict("path" => "/bin/sh", "arg" => ["-c", FREEBSD_MEMORY_COMMAND],
                            "capture-output" => true),
    ))
    memory.pending = Int(response["return"]["pid"])
    memory.pending_at = time()
    memory.failures = 0
    return nothing
end

# The output of the pending command once it has exited, or `nothing`.
function freebsd_memory_collect!(memory::FreeBSDSysctlMemory, source)
    status = try
        kvm_agent_command(source, Dict(
            "execute" => "guest-exec-status",
            "arguments" => Dict("pid" => memory.pending),
        ))["return"]
    catch
        memory.failures += 1
        memory.failures >= FREEBSD_MEMORY_MAX_FAILURES && (memory.pending = nothing)
        return nothing
    end
    memory.failures = 0
    get(status, "exited", false) === true || return nothing
    memory.pending = nothing
    data = get(status, "out-data", "")
    (data isa String && ncodeunits(data) <= 4 * cld(FREEBSD_MEMORY_MAX_OUTPUT, 3)) || return nothing
    return String(Base64.base64decode(data))
end

function sample_guest_memory!(memory::FreeBSDSysctlMemory, source, stats)
    observed_at = memory.pending_at
    output = memory.pending === nothing ? nothing : freebsd_memory_collect!(memory, source)
    if memory.pending === nothing
        try
            freebsd_memory_start!(memory, source)
        catch err
            @debug "Could not start sysctl in the guest" source.domain exception=err
        end
    end
    reading = output === nothing ? nothing : parse_freebsd_memory(output)
    reading === nothing && return nothing
    bytes = reading.bytes
    haskey(bytes, "pages") && (memory.guest_bytes = bytes["pages"])
    haskey(bytes, "swap_total") && (memory.swap_total_bytes = bytes["swap_total"])
    memory.peak_arc_bytes = maxpeak(memory.peak_arc_bytes, bytes["arc"])
    if memory.peak_needed_bytes === nothing || reading.needed_bytes > memory.peak_needed_bytes
        memory.peak_needed_bytes = reading.needed_bytes
        memory.at_peak = Dict(k => bytes[k] for k in ("active", "inactive", "laundry", "wired", "arc", "free"))
    end
    if haskey(bytes, "swapped_in") && haskey(bytes, "swapped_out")
        memory.paged_first === nothing && (memory.paged_first = (bytes["swapped_in"], bytes["swapped_out"]))
        memory.paged_last = (bytes["swapped_in"], bytes["swapped_out"])
    end
    return (; reading.needed_bytes, reading.total_bytes, reading.swap_bytes, memory_at = observed_at)
end

function guest_memory_details(memory::FreeBSDSysctlMemory)
    first, last = memory.paged_first, memory.paged_last
    swapped(i) = first === nothing || last === nothing ? nothing : last[i] - first[i]
    return Dict{String,Any}(
        "guest_memory_bytes" => memory.guest_bytes,
        "swap_configured_bytes" => memory.swap_total_bytes,
        "peak_arc_bytes" => memory.peak_arc_bytes,
        "at_needed_peak_bytes" => memory.at_peak,
        "swapped_in_bytes" => swapped(1),
        "swapped_out_bytes" => swapped(2),
    )
end

# Cumulative CPU figures of a domain, in nanoseconds. `delay` is `nothing`
# where the host does not report it.
struct KVMCPUReading
    vcpus::Int
    vcpu_time::Int
    delay::Union{Nothing,Int}
    domain_time::Union{Nothing,Int}
end

mutable struct KVMResourceSource <: ResourceSource
    domain::String
    guest::String
    record_path::String
    memory::Union{Nothing,WindowsBalloonMemory,FreeBSDSysctlMemory}
    first::Union{Nothing,KVMCPUReading}
    last::Union{Nothing,KVMCPUReading}
    qemu_rss_bytes::Union{Nothing,Int}
    # The time budget of a sample, and the current sample's deadlines: for its
    # work, and the later one for closing file handles.
    budget::Float64
    deadline::Float64
    cleanup_deadline::Float64
    commands::SampleCommands
    # Record file handles whose close failed, with the attempts so far, and
    # handles given up on.
    stale_handles::Dict{Int,Int}
    lost_handles::Int
    # The domain's whole cgroup on the host (QEMU, its I/O and vhost threads,
    # the vCPUs), once found through `proc_root` and `cgroup_root`; and its
    # sampled peaks.
    proc_root::String
    cgroup_root::String
    scope::Union{Nothing,String}
    # Lookups of `scope` so far, and when the next may be (each scans /proc).
    scope_lookups::Int
    scope_next_lookup::Float64
    scope_peaks::CgroupPeaks
    # The RAM the domain was configured with, for comparing with its peak.
    guest_ram_bytes::Union{Nothing,Int}
end

KVMResourceSource(domain::AbstractString, guest::AbstractString;
                  memory=kvm_guest_memory(guest),
                  record_path::AbstractString=KVM_RESOURCE_RECORD_PATHS[guest],
                  budget::Real=KVM_RESOURCE_SAMPLE_BUDGET,
                  proc_root::AbstractString="/proc",
                  cgroup_root::AbstractString="/sys/fs/cgroup",
                  guest_ram_bytes::Union{Nothing,Integer}=nothing) =
    KVMResourceSource(String(domain), String(guest), String(record_path), memory, nothing, nothing,
                      nothing, Float64(budget), 0.0, 0.0, SampleCommands(), Dict{Int,Int}(), 0,
                      String(proc_root), String(cgroup_root), nothing, 0, 0.0, CgroupPeaks(), guest_ram_bytes)

# A domain whose cgroup is not found is looked for again at most this often,
# this many times per job.
const KVM_DOMAIN_CGROUP_RETRY_SECONDS = 60.0
const KVM_DOMAIN_CGROUP_LOOKUPS = 5

# The domain's own cgroup, from its QEMU process: the one whose `-name` option
# is `guest=<domain>` (commas in it doubled), and that process's cgroup less
# libvirt's `libvirt/emulator` (or `emulator`) below it. That is the domain's
# systemd scope (`machine.slice/machine-qemu\x2d<id>\x2d<name>.scope`, the
# name shortened in ways that differ between libvirt versions) or, without
# systemd, libvirt's `machine/qemu-<id>-<name>.libvirt-qemu`. libvirt's pid
# file is root's, but a process's command line and cgroup are readable.
# `nothing` if there is no such process, or more than one.
function kvm_domain_cgroup(domain::AbstractString; proc_root::AbstractString="/proc",
                           cgroup_root::AbstractString="/sys/fs/cgroup")
    found = nothing
    for entry in readdir(proc_root)
        all(isdigit, entry) && kvm_runs_domain(proc_root, entry, domain) || continue
        found === nothing || return nothing
        found = entry
    end
    found === nothing && return nothing
    cgroup = nothing
    for line in eachline(joinpath(proc_root, found, "cgroup"))
        startswith(line, "0::") && (cgroup = line[4:end])
    end
    # The pid may have been reused between the scan and the read.
    (cgroup === nothing || !kvm_runs_domain(proc_root, found, domain)) && return nothing
    parts = split(strip(cgroup, '/'), '/')
    while !isempty(parts) && last(parts) in ("emulator", "libvirt")
        pop!(parts)
    end
    isempty(parts) && return nothing
    path = joinpath(cgroup_root, parts...)
    return isdir(path) ? path : nothing
end

# Whether process `pid` is a QEMU running `domain`.
function kvm_runs_domain(proc_root::AbstractString, pid::AbstractString, domain::AbstractString)
    args = try_read(() -> split(read(joinpath(proc_root, pid, "cmdline"), String), '\0'), String[])
    (isempty(args) || !startswith(basename(first(args)), "qemu")) && return false
    i = findfirst(==("-name"), args)
    (i === nothing || i == length(args)) && return false
    return kvm_qemu_guest_name(args[i+1]) == domain
end

# The `guest=` value of QEMU's `-name` option, with `,,` read as a comma.
function kvm_qemu_guest_name(option::AbstractString)
    startswith(option, "guest=") || return nothing
    name = IOBuffer()
    chars = collect(option[ncodeunits("guest=")+1:end])
    k = 1
    while k <= length(chars)
        if chars[k] == ','
            (k < length(chars) && chars[k+1] == ',') || break
            k += 1
        end
        print(name, chars[k])
        k += 1
    end
    return String(take!(name))
end

function kvm_start_sample!(source::KVMResourceSource; now::Float64=time())
    source.cleanup_deadline = now + source.budget
    source.deadline = source.cleanup_deadline - min(2.0, source.budget / 4)
    return nothing
end

kvm_resource_read(source::KVMResourceSource, cmd::Cmd; deadline::Float64=source.deadline) =
    read_sample_command(source.commands, cmd, deadline)

interrupt_resources(source::KVMResourceSource) = interrupt!(source.commands)

kvm_agent_command(source::KVMResourceSource, payload::Dict; deadline::Float64=source.deadline) =
    qga_command_json(source.domain, payload; timeout=KVM_RESOURCE_AGENT_TIMEOUT,
                     reader=cmd -> kvm_resource_read(source, cmd; deadline),
                     max_bytes=qga_max_command_bytes(source.guest))

# The `name=value` lines of a single domain's `virsh domstats` output.
function parse_domstats(output::AbstractString)
    stats = Dict{String,String}()
    for line in eachline(IOBuffer(output))
        m = match(r"^\s*([\w.-]+)=(.*)$", line)
        m === nothing || (stats[m[1]] = strip(m[2]))
    end
    return stats
end

function kvm_cpu_reading(stats::AbstractDict)
    vcpus, vcpu_time, delay = 0, 0, 0
    has_delay = false
    for (key, value) in stats
        m = match(r"^vcpu\.\d+\.(time|delay)$", key)
        m === nothing && continue
        ns = tryparse(Int, value)
        ns === nothing && continue
        if m[1] == "time"
            vcpus += 1
            vcpu_time += ns
        else
            has_delay = true
            delay += ns
        end
    end
    vcpus == 0 && return nothing
    return KVMCPUReading(vcpus, vcpu_time, has_delay ? delay : nothing,
                         tryparse(Int, get(stats, "cpu.time", "")))
end

resource_platform(source::KVMResourceSource) = string(source.guest, "-kvm")
resource_needed_lower_bound(source::KVMResourceSource) = source.guest == "freebsd"

function sample_resources(source::KVMResourceSource)
    kvm_start_sample!(source)
    stats = try
        parse_domstats(kvm_resource_read(source,
            virsh("domstats", "--nowait", "--vcpu", "--cpu-total", "--balloon", source.domain)))
    catch
        return nothing      # the domain is gone, or libvirt is stuck
    end
    cpu = kvm_cpu_reading(stats)
    if cpu !== nothing
        source.first === nothing && (source.first = cpu)
        source.last = cpu
    end
    try
        if source.scope === nothing && source.scope_lookups < KVM_DOMAIN_CGROUP_LOOKUPS &&
                time() >= source.scope_next_lookup
            source.scope_lookups += 1
            source.scope_next_lookup = time() + KVM_DOMAIN_CGROUP_RETRY_SECONDS
            source.scope = kvm_domain_cgroup(source.domain; source.proc_root, source.cgroup_root)
        end
        source.scope === nothing || sample_cgroup_peaks!(source.scope_peaks, source.scope)
    catch err
        @debug "Could not read the domain's cgroup" domain=source.domain exception=err
    end
    rss = tryparse(Int, get(stats, "balloon.rss", ""))
    rss === nothing || (source.qemu_rss_bytes = 1024 * rss)
    memory = try
        source.memory === nothing ? nothing : sample_guest_memory!(source.memory, source, stats)
    catch err
        @debug "Could not read the guest's memory" domain=source.domain exception=err
        nothing
    end
    cpu === nothing && memory === nothing && return nothing
    return ResourceSample(;
        cpu_seconds = cpu === nothing ? nothing : cpu.vcpu_time / 1e9,
        wait_seconds = cpu === nothing || cpu.delay === nothing ? nothing : cpu.delay / 1e9,
        needed_bytes = memory === nothing ? nothing : memory.needed_bytes,
        total_bytes = memory === nothing ? nothing : memory.total_bytes,
        swap_bytes = memory === nothing ? nothing : memory.swap_bytes,
        memory_at = memory === nothing ? nothing : memory.memory_at)
end

# Seconds between the first and the last reading, or `nothing`.
function kvm_cpu_delta(f, source::KVMResourceSource)
    first, last = source.first, source.last
    (first === nothing || last === nothing) && return nothing
    a, b = f(first), f(last)
    (a === nothing || b === nothing) && return nothing
    return round((b - a) / 1e9; digits=1)
end

function resource_details(source::KVMResourceSource)
    details = Dict{String,Any}(
        "vcpus" => source.last === nothing ? nothing : source.last.vcpus,
        "qemu_rss_bytes" => source.qemu_rss_bytes,
        "emulator_cpu_seconds" => kvm_cpu_delta(source) do r
            r.domain_time === nothing ? nothing : r.domain_time - r.vcpu_time
        end,
    )
    source.memory === nothing || merge!(details, guest_memory_details(source.memory))
    if source.scope !== nothing
        usage = try_read(() -> cgroup_usage(source.scope, source.scope_peaks), Dict{String,Any}())
        # The configured RAM, not what the guest touched or reports
        # (`guest_memory_bytes`): peak less this is QEMU's overhead only for
        # guests that touch all their RAM, which is for the analysis to judge.
        isempty(usage) || source.guest_ram_bytes === nothing ||
            (usage["guest_ram_bytes"] = source.guest_ram_bytes)
        isempty(usage) || (details["domain_cgroup"] = usage)
    end
    return details
end

function publish_resources(source::KVMResourceSource, content::AbstractString)
    for (handle, attempts) in collect(source.stale_handles)
        kvm_close_guest_file!(source, handle, attempts)
    end
    source.lost_handles < KVM_RESOURCE_MAX_LOST_HANDLES ||
        error("Lost $(source.lost_handles) guest file handles in $(source.domain); not publishing any more")
    handle = try
        kvm_agent_command(source, Dict(
            "execute" => "guest-file-open",
            "arguments" => Dict("path" => source.record_path, "mode" => "w"),
        ))["return"]
    catch err
        kvm_open_may_have_succeeded(err) && (source.lost_handles += 1)
        rethrow()
    end
    try
        for chunk in Iterators.partition(codeunits(content), QGA_WRITE_CHUNK)
            written = kvm_agent_command(source, Dict(
                "execute" => "guest-file-write",
                "arguments" => Dict("handle" => handle, "buf-b64" => Base64.base64encode(chunk)),
            ))["return"]["count"]
            written == length(chunk) ||
                error("Wrote $(written) of $(length(chunk)) bytes to $(source.record_path) in $(source.domain)")
        end
    finally
        kvm_close_guest_file!(source, handle, 0)
    end
    return nothing
end

# Whether a `guest-file-open` that threw may have left the file open, under a
# handle nobody knows. Only a command that was never sent, or the guest agent's
# own refusal (e.g. no such directory, on images without it), rules that out;
# a killed virsh, a lost connection or a guest agent timeout do not.
kvm_open_may_have_succeeded(err) =
    !(err isa SampleCommandNotRun ||
      err isa ErrorException && startswith(err.msg, "Guest agent command") ||   # over `max_bytes`
      err isa SampleCommandFailed && occursin("unable to execute QEMU agent command", err.stderr))

function kvm_close_guest_file!(source::KVMResourceSource, handle::Integer, attempts::Integer)
    try
        kvm_agent_command(source, Dict(
            "execute" => "guest-file-close",
            "arguments" => Dict("handle" => handle),
        ); deadline=source.cleanup_deadline)
        delete!(source.stale_handles, handle)
    catch err
        if attempts + 1 >= KVM_RESOURCE_CLOSE_ATTEMPTS
            delete!(source.stale_handles, handle)
            source.lost_handles += 1
        else
            source.stale_handles[handle] = attempts + 1
        end
    end
    return nothing
end

struct KVMHandle
    backend::KVMBackend
    slot::Slot
    job::Job
    plan::CachePlan
    alloc::Allocation
    domain::String
    xml_path::String
    os_overlay::String
    cache_overlay::String
    log_path::String
    launch::LaunchGate
    resources::ResourceSampler{KVMResourceSource}
end

function KVMHandle(backend::KVMBackend, slot::Slot, job::Job, plan::CachePlan,
                   alloc::Allocation, domain::String, xml_path::String, os_overlay::String,
                   cache_overlay::String, log_path::String)
    guest = kvm_guest(slot.brg)
    source = KVMResourceSource(domain, guest; guest_ram_bytes=gib_bytes(alloc.mem_limit_gib))
    sampler = ResourceSampler(source; context=job_resource_context(; job, slot=slot.name,
        group=slot.brg.name, queue=job_queue(slot.brg, job), alloc))
    return KVMHandle(backend, slot, job, plan, alloc, domain, xml_path, os_overlay,
        cache_overlay, log_path, LaunchGate(), sampler)
end

KVMHandle(backend, slot, job, plan, alloc, domain, xml_path, os_overlay, cache_overlay, log_path) =
    KVMHandle(backend, slot, job, plan, alloc, domain, xml_path, os_overlay, cache_overlay,
        log_path, LaunchGate())

function kvm_group_prefix(group::AbstractString)
    return string(group, "-", get_short_hostname(), ".")
end

function kvm_group_prefixes(groups)
    return sort(unique(kvm_group_prefix(group) for group in groups))
end

function kvm_scratch_root(brg::BuildkiteRunnerGroup)
    return joinpath(tempdir(brg), "kvm-agent-scratch")
end

function kvm_scratch_roots(brgs)
    return sort(unique(kvm_scratch_root(brg) for brg in brgs))
end

function kvm_cache_roots(brgs)
    return sort(unique(cachedir(brg) for brg in brgs))
end

function kvm_guest(brg::BuildkiteRunnerGroup)
    brg.guest === nothing && error("KVM runner group '$(brg.name)' must set `guest`")
    return brg.guest
end

function kvm_image_dir(brg::BuildkiteRunnerGroup)
    return repo_path("platforms", "$(kvm_guest(brg))-kvm", "buildkite-worker", "images")
end

function kvm_pristine_os_image(brg::BuildkiteRunnerGroup, image_dir::AbstractString=kvm_image_dir(brg))
    if brg.guest == "freebsd"
        return joinpath(image_dir, brg.tags["arch"], "worker.qcow2")
    end
    return joinpath(image_dir, "worker.qcow2")
end

function kvm_pristine_cache_image(brg::BuildkiteRunnerGroup)
    return string(kvm_pristine_os_image(brg), "-1")
end

function kvm_xml_template(brg::BuildkiteRunnerGroup)
    name = "kvm_machine.xml.template"
    if kvm_guest(brg) == "freebsd"
        arch = brg.tags["arch"]
        arch in ("x86_64", "aarch64") || error("Unsupported FreeBSD guest architecture: $(arch)")
        arch == "aarch64" && (name = "kvm_machine.aarch64.xml.template")
    end
    return repo_path("platforms", "$(kvm_guest(brg))-kvm", "buildkite-worker", name)
end

function kvm_scratch_dir(slot::Slot)
    return joinpath(tempdir(slot.brg), "kvm-agent-scratch", slot.name)
end

function kvm_os_overlay_path(slot::Slot)
    return joinpath(kvm_scratch_dir(slot), "$(slot.name).qcow2")
end

function kvm_xml_path(slot::Slot)
    return joinpath(kvm_scratch_dir(slot), "$(slot.name).xml")
end

function kvm_cache_overlay_path(plan::CachePlan)
    return joinpath(plan.cache_pool, "cache.qcow2-1")
end

function agent_mac_address(agent_hostname::String)
    hostname_bytes = reinterpret(UInt8, [Base._crc32c(agent_hostname)])
    return join(string.([0x52, 0x54, 0x00, hostname_bytes[1:3]...]; pad=2, base=16), ":")
end

function qemu_img_create_overlay(path::AbstractString, backing::AbstractString)
    mkpath(dirname(path))
    rm(path; force=true)
    run(`qemu-img create -f qcow2 -F qcow2 -b $(backing) $(path)`)
    return string(path)
end

function kvm_cache_overlay_stamp_path(path::AbstractString)
    return string(path, ".backing")
end

function kvm_backing_identity(backing::AbstractString)
    statinfo = stat(backing)
    return join([
        abspath(backing),
        string(statinfo.device),
        string(statinfo.inode),
        string(statinfo.size),
        string(statinfo.mtime),
    ], "\n")
end

function ensure_kvm_cache_overlay(path::AbstractString, backing::AbstractString)
    mkpath(dirname(path))
    stamp_path = kvm_cache_overlay_stamp_path(path)
    identity = kvm_backing_identity(backing)
    if !isfile(path) || !isfile(stamp_path) || read(stamp_path, String) != identity
        rm(path; force=true)
        run(`qemu-img create -f qcow2 -F qcow2 -b $(backing) $(path)`)
        write(stamp_path, identity)
    end
    return string(path)
end

function kvm_aarch64_firmware()
    # Ubuntu's qemu-efi-aarch64 and Arch's edk2-aarch64 packages, respectively.
    paths = ("/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/edk2/aarch64/QEMU_EFI.fd")
    return paths[something(findfirst(isfile, paths), 1)]
end

function kvm_template_vars(handle::KVMHandle)
    alloc = handle.alloc
    vars = Dict(
        "agent_hostname" => handle.domain,
        "num_cpus" => string(alloc.cpus_limit),
        "memory_kb" => string(gib_bytes(alloc.mem_limit_gib) ÷ 1024),
        # libvirt writes this as the domain's cpu.weight on cgroup v2, matching
        # the Linux backend's 100 per requested CPU.
        "cpu_shares" => string(job_cpu_weight(alloc.cpus)),
        "agent_scratch_dir" => kvm_scratch_dir(handle.slot),
        "os_disk_path" => handle.os_overlay,
        "cache_disk_path" => handle.cache_overlay,
        "log_path" => kvm_serial_log_path(handle.log_path),
        "agent_mac_address" => agent_mac_address(handle.domain),
    )
    if handle.slot.brg.guest == "freebsd" && handle.slot.brg.tags["arch"] == "aarch64"
        vars["firmware"] = kvm_aarch64_firmware()
    end
    return vars
end

function render_template(template::AbstractString, vars::Dict{String,String})
    data = read(template, String)
    for (key, value) in vars
        data = replace(data, "\${$(key)}" => value)
    end
    unresolved = match(r"\$\{[^}]+\}", data)
    unresolved === nothing || error("Unresolved KVM template variable $(unresolved.match) in $(template)")
    return data
end

function render_kvm_xml(handle::KVMHandle)
    template = kvm_xml_template(handle.slot.brg)
    isfile(template) || error("KVM XML template does not exist: $(template)")
    mkpath(dirname(handle.xml_path))
    write(handle.xml_path, render_template(template, kvm_template_vars(handle)))
    return handle.xml_path
end

function prepare_kvm_log_file(path::AbstractString)
    mkpath(dirname(path))
    try
        open(path, "a") do _
        end
    catch err
        if err isa SystemError
            rm(path; force=true)
            open(path, "a") do _
            end
        else
            rethrow()
        end
    end
    chmod(path, 0o666)
    return string(path)
end

function kvm_serial_log_path(log_path::AbstractString)
    return string(splitext(log_path)[1], ".serial", splitext(log_path)[2])
end

function kvm_buildkite_agent_env(handle::KVMHandle, agent_token::AbstractString)
    brg = handle.slot.brg
    return [
        "BUILDKITE_AGENT_TOKEN=$(agent_token)",
        "BUILDKITE_AGENT_NAME=$(handle.domain)",
        "BUILDKITE_AGENT_TAGS=$(buildkite_agent_tags(brg, handle.job))",
        # `--reflect-exit-status` (see `buildkite_agent_start_command`) for the
        # agent the guest image starts.
        "BUILDKITE_AGENT_REFLECT_EXIT_STATUS=true",
        # `--plugins-always-clone-fresh`, idem.
        "BUILDKITE_PLUGINS_ALWAYS_CLONE_FRESH=true",
        "BUILDKITE_PLUGIN_JULIA_ARCH=$(brg.tags["arch"])",
        "XDG_CACHE_HOME=$(kvm_guest_cache_dir(kvm_guest(brg)))",
        ("$(name)=$(value)" for (name, value) in allocation_env(handle.alloc))...,
    ]
end

# Where the guest mounts the cache disk, exported as `XDG_CACHE_HOME` (see
# "Cache isolation" in the README). FreeBSD's launcher hands the agent its whole
# environment; Windows images built from this revision on forward it to the
# agent service.
kvm_guest_cache_dir(guest::AbstractString) = guest == "windows" ? raw"C:\cache" : "/cache"

function check_config(::KVMBackend, brgs::Vector{BuildkiteRunnerGroup})
    require_libvirt_access()
    Sys.which("qemu-img") !== nothing || error("KVM backend requires `qemu-img` on PATH")

    for brg in brgs
        kvm_guest(brg) in KVM_GUESTS ||
            error("KVM runner group '$(brg.name)' has invalid guest '$(brg.guest)'")
        brg.tags["os"] == kvm_guest(brg) ||
            error("KVM runner group '$(brg.name)' must advertise os=$(kvm_guest(brg))")

        if kvm_guest(brg) == "freebsd"
            brg.tags["arch"] == string(Sys.ARCH) ||
                error("FreeBSD KVM guest architecture must match the host architecture $(Sys.ARCH)")
            if brg.tags["arch"] == "aarch64"
                isfile(kvm_aarch64_firmware()) ||
                    error("FreeBSD ARM KVM requires the qemu-efi-aarch64 or edk2-aarch64 firmware package")
            end
        end
        os_image = kvm_pristine_os_image(brg)
        cache_image = kvm_pristine_cache_image(brg)
        isfile(os_image) || error("KVM runner group '$(brg.name)' is missing OS image $(os_image)")
        isfile(cache_image) || error("KVM runner group '$(brg.name)' is missing cache image $(cache_image)")
        isfile(kvm_xml_template(brg)) ||
            error("KVM runner group '$(brg.name)' is missing XML template $(kvm_xml_template(brg))")
    end
    return nothing
end

function backend_available(::KVMBackend, brg::BuildkiteRunnerGroup)
    return isfile(kvm_pristine_os_image(brg)) &&
        isfile(kvm_pristine_cache_image(brg)) &&
        isfile(kvm_xml_template(brg))
end

function setup_config!(backend::KVMBackend, brgs::Vector{BuildkiteRunnerGroup})
    check_config(backend, brgs)
    if !isempty(brgs)
        if kvm_bridge_stp_enabled()
            @warn("STP is enabled on the KVM bridge, so each new guest's traffic is dropped for its first seconds; run `admin/kvm-network.sh --apply` as root to disable it",
                bridge=KVM_BRIDGE)
        end
    end
    return nothing
end

# STP delays forwarding on each new guest tap. Our NAT bridge has no redundant
# paths, so admin/kvm-network.sh can disable it without restarting the network.
function kvm_bridge_stp_enabled(bridge::AbstractString=KVM_BRIDGE;
                                sysfs::AbstractString="/sys/class/net")
    path = joinpath(sysfs, bridge, "bridge", "stp_state")
    isfile(path) || return false
    return strip(read(path, String)) != "0"
end

function require_libvirt_access()
    if Sys.which("virsh") === nothing
        error("KVM backend requires `virsh` on PATH")
    end
    run(pipeline(`virsh -c $(KVM_URI) list --name`; stdout=devnull))
    return nothing
end

function virsh(args::AbstractString...)
    return Cmd(String["virsh", "-c", KVM_URI, args...])
end

function running_kvm_domains()
    Sys.which("virsh") === nothing && return String[]
    output = read(virsh("list", "--name"), String)
    return filter(!isempty, chomp.(split(output, '\n')))
end

function kvm_domain_running(domain::AbstractString)
    return domain in running_kvm_domains()
end

function matching_kvm_domains(backend::KVMBackend)
    prefixes = backend.domain_prefixes
    isempty(prefixes) && isempty(backend.scratch_roots) && isempty(backend.cache_roots) && return String[]
    return [domain for domain in running_kvm_domains()
        if any(prefix -> startswith(domain, prefix), prefixes) ||
           kvm_domain_uses_scheduler_disks(backend, domain)]
end

function kvm_domain_disk_paths(domain::AbstractString)
    output = read(virsh("domblklist", domain, "--details"), String)
    paths = String[]
    for line in split(output, '\n')
        fields = split(strip(line))
        length(fields) >= 4 || continue
        source = fields[end]
        source == "-" && continue
        isabspath(source) && push!(paths, source)
    end
    return paths
end

slot_scratch_roots(::KVMBackend, brg::BuildkiteRunnerGroup) = [(kvm_scratch_root(brg), "")]

# Every disk of every running domain, so that no cache disk or scratch a guest
# uses is deleted; `nothing` if libvirt cannot tell.
function attached_disks(::KVMBackend; domains::Function=running_kvm_domains,
                        disk_paths::Function=kvm_domain_disk_paths)
    disks = Set{String}()
    try
        for domain in domains()
            union!(disks, normpath.(disk_paths(domain)))
        end
    catch err
        @warn("Unable to list the disks of running KVM domains",
            exception=(err, catch_backtrace()))
        return nothing
    end
    return disks
end

function kvm_domain_uses_scheduler_disks(backend::KVMBackend, domain::AbstractString)
    isempty(backend.scratch_roots) && isempty(backend.cache_roots) && return false
    paths = try
        kvm_domain_disk_paths(domain)
    catch err
        @warn("Unable to inspect KVM domain disks", domain, exception=(err, catch_backtrace()))
        return false
    end
    for path in paths
        any(root -> path_within_root(path, root), backend.scratch_roots) && return true
        basename(path) == "cache.qcow2-1" || continue
        any(root -> path_within_root(path, root), backend.cache_roots) && return true
    end
    return false
end

# Ask the guest to power off cleanly and wait for the domain to disappear.
# Returns `true` when the domain stopped on its own and `false` when the
# request failed or the guest was still running after `timeout` seconds.
function shutdown_kvm_domain(domain::AbstractString;
                             timeout::Float64=KVM_GRACEFUL_SHUTDOWN_TIMEOUT,
                             poll_interval::Float64=KVM_SHUTDOWN_POLL_INTERVAL)
    # Allow either guest-agent or ACPI shutdown; libvirt chooses the order.
    request = pipeline(virsh("shutdown", domain, "--mode", "agent,acpi"); stdout=devnull, stderr=devnull)
    success(request) || return false
    start = time()
    while kvm_domain_running(domain)
        time() - start >= timeout && return false
        sleep(poll_interval)
    end
    return true
end

# How long a destroyed domain may take to disappear from `virsh list`.
const KVM_DESTROY_TIMEOUT = 30.0

# Hard power-off can lose cached writes even when filesystem metadata survives.
# Guest launchers detach the cache on normal completion, but cancellation and
# error paths also reach here while the cache may still be mounted.
# Returns whether the domain is confirmed gone.
function stop_kvm_domain(domain::AbstractString;
                         cache_detached::Bool=false,
                         shutdown_timeout::Float64=KVM_GRACEFUL_SHUTDOWN_TIMEOUT,
                         destroy_timeout::Float64=KVM_DESTROY_TIMEOUT,
                         poll_interval::Float64=KVM_SHUTDOWN_POLL_INTERVAL)
    kvm_domain_running(domain) || return true
    if !cache_detached
        if shutdown_timeout > 0 && shutdown_kvm_domain(domain; timeout=shutdown_timeout)
            return true
        end
        @warn("KVM domain did not shut down cleanly; destroying it", domain)
    end
    destroyed = success(pipeline(virsh("destroy", domain); stdout=devnull))
    deadline = time() + destroy_timeout
    while kvm_domain_running(domain)
        if time() >= deadline
            @error("KVM domain survived `virsh destroy`", domain, destroy_succeeded=destroyed)
            return false
        end
        sleep(poll_interval)
    end
    return true
end

function cleanup(backend::KVMBackend)
    domains = matching_kvm_domains(backend)
    # Share the shutdown window across guests to fit within the service stop
    # timeout even when several guests are unresponsive.
    @sync for domain in domains
        @async begin
            @warn("Stopping stale KVM domain", domain)
            try
                stop_kvm_domain(domain)
            catch err
                @error("Unable to stop stale KVM domain", domain, exception=(err, catch_backtrace()))
            end
        end
    end
    survivors = matching_kvm_domains(backend)
    isempty(survivors) || error("Refusing to launch KVM jobs; stale domains survived cleanup: $(join(survivors, ", "))")
    return nothing
end

function prepare(backend::KVMBackend, slot::Slot, job::Job, plan::CachePlan,
                 alloc::Allocation)
    plan.ccache_pool === nothing ||
        error("KVM backend does not support shared ccache pools")

    mkpath(plan.cache_pool)
    scratch = kvm_scratch_dir(slot)
    mkpath(scratch)

    domain = slot.name
    xml_path = kvm_xml_path(slot)
    os_overlay = ""
    handle = nothing

    try
        os_overlay = qemu_img_create_overlay(kvm_os_overlay_path(slot), kvm_pristine_os_image(slot.brg))
        cache_overlay = ensure_kvm_cache_overlay(kvm_cache_overlay_path(plan), kvm_pristine_cache_image(slot.brg))
        log_path = job_log_path(backend.logdir, domain, job)
        prepare_kvm_log_file(log_path)
        prepare_kvm_log_file(kvm_serial_log_path(log_path))

        handle = KVMHandle(backend, slot, job, plan, alloc, domain, xml_path, os_overlay, cache_overlay, log_path)
        render_kvm_xml(handle)
        return handle
    catch
        if handle !== nothing
            reap(handle)
        else
            for path in (os_overlay, xml_path)
                isempty(path) && continue
                try
                    rm(path; force=true)
                catch err
                    @warn("Unable to remove KVM scratch path after prepare failure",
                        path, exception=(err, catch_backtrace()))
                end
            end
        end
        rethrow()
    end
end

# FreeBSD exposes the guest agent's virtio port as a tty, which qemu-ga leaves
# in canonical mode at 9600 baud. Its input queue holds 9600/5 = 1920 bytes; a
# longer line loses its newline, never completes, and the agent reads nothing
# more until it is restarted in the guest. libvirt sends our (already compact)
# JSON plus a newline, so commands must stay at 1919 bytes. Replies are not
# limited. Measured on FreeBSD 13.4/qemu-ga 10.2.2 and 15.1/11.0.2. Windows
# reads the port as a device and has no such limit.
const QGA_MAX_COMMAND_BYTES = 1919

qga_max_command_bytes(guest::AbstractString) = guest == "freebsd" ? QGA_MAX_COMMAND_BYTES : nothing

# How long a `virsh` may outlive the deadline it was given before it is killed.
const KVM_RPC_KILL_GRACE = 2.0

# The output of `cmd`, which is killed if it is still running shortly after
# `deadline`.
function read_bounded(cmd, deadline::Float64)
    proc = open(cmd, "r")
    timer = Timer(max(deadline - time(), 0.0) + KVM_RPC_KILL_GRACE) do _
        process_running(proc) && kill(proc, Base.SIGKILL)
    end
    try
        output = read(proc, String)
        wait(proc)
        success(proc) || error("$(cmd) failed (exit code $(proc.exitcode), signal $(proc.termsignal))")
        return output
    finally
        close(timer)
    end
end

# With a `deadline`, the guest agent is given what is left of it, and `virsh`
# is killed if it outlives it. `timeout` bounds the guest agent's side on its
# own. Commands longer than `max_bytes` are refused rather than sent. `reader`
# runs the virsh command and returns its output, in place of the above.
function qga_command(domain::AbstractString, payload::Dict; quiet::Bool=false,
                     deadline::Union{Nothing,Float64}=nothing,
                     timeout::Union{Nothing,Integer}=nothing, reader=nothing,
                     max_bytes::Union{Nothing,Integer}=nothing)
    json = JSON.json(payload)
    max_bytes === nothing || ncodeunits(json) <= max_bytes ||
        error("Guest agent command $(payload["execute"]) for $(domain) is $(ncodeunits(json)) bytes, ",
              "over the $(max_bytes) its guest agent can receive")
    args = String["qemu-agent-command", domain, json]
    if deadline !== nothing
        remaining = deadline - time()
        remaining > 0 || error("Deadline passed before qemu guest agent command in $(domain)")
        left = max(1, floor(Int, remaining))
        timeout = timeout === nothing ? left : min(timeout, left)
    end
    timeout === nothing || append!(args, ["--timeout", string(timeout)])
    cmd = virsh(args...)
    reader === nothing || return reader(cmd)
    quiet && (cmd = pipeline(cmd; stderr=devnull))
    return deadline === nothing ? read(cmd, String) : read_bounded(cmd, deadline)
end

function qga_command_json(domain::AbstractString, payload::Dict; quiet::Bool=false,
                          deadline::Union{Nothing,Float64}=nothing,
                          timeout::Union{Nothing,Integer}=nothing, reader=nothing,
                          max_bytes::Union{Nothing,Integer}=nothing)
    return JSON.parse(qga_command(domain, payload; quiet, deadline, timeout, reader, max_bytes))
end

function wait_for_guest_agent(domain::AbstractString;
        timeout::Float64=KVM_AGENT_READY_TIMEOUT,
        stable_for::Float64=0.0,
        deadline::Union{Nothing,Float64}=nothing)
    start = time()
    context = "waiting for qemu guest agent in $(domain)"
    stable_start = nothing
    while true
        check_assignment_deadline!(deadline, context)
        try
            qga_command_json(domain, Dict("execute" => "guest-ping"))
            stable_start === nothing && (stable_start = time())
            if time() - stable_start >= stable_for
                return nothing
            end
        catch err
            stable_start = nothing
            elapsed = time() - start
            # A crashed/destroyed guest never answers guest-ping; fail fast
            # instead of waiting out the whole ready timeout, matching
            # `wait_for_windows_guest_job`'s domain-stopped check.
            if !kvm_domain_running(domain)
                elapsed_s = round(elapsed; digits=1)
                error("KVM domain $(domain) stopped after $(elapsed_s)s before the qemu guest agent became ready: $(err)")
            end
            if elapsed > timeout
                elapsed_s = round(elapsed; digits=1)
                timeout_s = round(timeout; digits=1)
                error("Timed out after $(elapsed_s)s waiting for qemu guest agent in $(domain) (timeout $(timeout_s)s): $(err)")
            end
        end
        sleep_until_deadline(KVM_AGENT_POLL_INTERVAL, deadline, context)
    end
end

function guest_agent_ready_timeout(handle::KVMHandle)
    kvm_guest(handle.slot.brg) == "windows" && return KVM_WINDOWS_AGENT_READY_TIMEOUT
    return KVM_AGENT_READY_TIMEOUT
end

function guest_agent_stable_for(handle::KVMHandle)
    kvm_guest(handle.slot.brg) == "windows" && return KVM_WINDOWS_AGENT_STABLE_FOR
    return 0.0
end

function freebsd_guest_exec(handle::KVMHandle, agent_token::AbstractString)
    payload = Dict(
        "execute" => "guest-exec",
        "arguments" => Dict(
            "path" => "/usr/local/bin/run-buildkite-job.sh",
            "arg" => [handle.job.id],
            "env" => kvm_buildkite_agent_env(handle, agent_token),
            "capture-output" => false,
        ),
    )
    # The admission line is only for the job log: rather drop it than have the
    # command refused for its length.
    ncodeunits(JSON.json(payload)) <= QGA_MAX_COMMAND_BYTES ||
        filter!(!startswith("SBA_ADMISSION="), payload["arguments"]["env"])
    return payload
end

# The guest agent starts the launcher with only the variables guest-exec passes,
# not on top of its own environment. Without these Windows defaults, PowerShell
# runs without `SystemRoot` and with `PATHEXT=.CPL`; it then starts `nssm.exe`
# like a document, without waiting for it, and the agent service can start
# before nssm has written the job's token into its environment.
const WINDOWS_GUEST_BASE_ENV = [
    raw"SystemRoot=C:\Windows",
    raw"windir=C:\Windows",
    "SystemDrive=C:",
    raw"ComSpec=C:\Windows\system32\cmd.exe",
    raw"PATH=C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0",
    "PATHEXT=.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC",
    raw"TEMP=C:\Windows\TEMP",
    raw"TMP=C:\Windows\TEMP",
]

function windows_guest_exec(handle::KVMHandle, agent_token::AbstractString)
    return Dict(
        "execute" => "guest-exec",
        "arguments" => Dict(
            "path" => raw"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            "arg" => [
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                raw"C:\buildkite-agent\run-buildkite-job.ps1",
                handle.job.id,
            ],
            "env" => [WINDOWS_GUEST_BASE_ENV; kvm_buildkite_agent_env(handle, agent_token)],
            "capture-output" => false,
        ),
    )
end

function guest_exec_payload(handle::KVMHandle, agent_token::AbstractString)
    guest = kvm_guest(handle.slot.brg)
    guest == "freebsd" && return freebsd_guest_exec(handle, agent_token)
    guest == "windows" && return windows_guest_exec(handle, agent_token)
    error("Unsupported KVM guest $(guest)")
end

function guest_exec(handle::KVMHandle, agent_token::AbstractString)
    # The command holds the token, so a failing `virsh` must not be quoted.
    reader = cmd -> read_with_secret(cmd, "Starting the Buildkite agent in $(handle.domain)")
    response = qga_command_json(handle.domain, guest_exec_payload(handle, agent_token);
                                max_bytes=qga_max_command_bytes(kvm_guest(handle.slot.brg)),
                                reader)
    return response["return"]["pid"]
end

function guest_exec_status(domain::AbstractString, pid;
                           deadline::Union{Nothing,Float64}=nothing)
    return qga_command_json(domain, Dict(
        "execute" => "guest-exec-status",
        "arguments" => Dict("pid" => pid),
    ); deadline)["return"]
end

function guest_file_read(domain::AbstractString, path::AbstractString; quiet::Bool=false)
    handle = qga_command_json(domain, Dict(
        "execute" => "guest-file-open",
        "arguments" => Dict("path" => path, "mode" => "r"),
    ); quiet)["return"]
    try
        chunks = String[]
        while true
            response = qga_command_json(domain, Dict(
                "execute" => "guest-file-read",
                "arguments" => Dict("handle" => handle, "count" => 4096),
            ); quiet)["return"]
            data = get(response, "buf-b64", "")
            isempty(data) || push!(chunks, String(Base64.base64decode(data)))
            get(response, "eof", false) && return join(chunks)
        end
    finally
        try
            qga_command_json(domain, Dict(
                "execute" => "guest-file-close",
                "arguments" => Dict("handle" => handle),
            ); quiet)
        catch err
            @warn("Unable to close qemu guest file handle", domain, path, exception=(err, catch_backtrace()))
        end
    end
end

# Base64 and the command around it must fit in `QGA_MAX_COMMAND_BYTES`;
# up to 1380 bytes would.
const QGA_WRITE_CHUNK = 1024

function wait_for_guest_exec(domain::AbstractString, pid;
                             deadline::Union{Nothing,Float64}=nothing)
    last_status_at = time()
    context = "waiting for qemu guest-exec in $(domain)"
    while true
        check_assignment_deadline!(deadline, context)
        status = try
            guest_exec_status(domain, pid)
        catch err
            elapsed = time() - last_status_at
            if elapsed > KVM_GUEST_EXEC_STATUS_GRACE
                elapsed_s = round(elapsed; digits=1)
                error("Timed out after $(elapsed_s)s waiting for qemu guest-exec status in $(domain): $(err)")
            end
            sleep_until_deadline(KVM_AGENT_POLL_INTERVAL, deadline, context)
            continue
        end
        last_status_at = time()
        if get(status, "exited", false)
            return Int(get(status, "exitcode", 1))
        end
        sleep_until_deadline(KVM_AGENT_POLL_INTERVAL, deadline, context)
    end
end

function wait_for_windows_guest_job(handle::KVMHandle;
                                    deadline::Union{Nothing,Float64}=nothing)
    start = time()
    context = "waiting for Windows Buildkite job in $(handle.domain)"
    service_started = false
    last_exit_error = nothing
    last_service_log_error = nothing
    while true
        check_assignment_deadline!(deadline, context)
        try
            output = strip(guest_file_read(handle.domain, KVM_WINDOWS_EXIT_PATH; quiet=true))
            if occursin(r"^-?\d+$", output)
                code = parse(Int, output)
                # Cache detach can fail even when the agent exits successfully.
                append_windows_guest_logs(handle)
                return code
            end
        catch err
            last_exit_error = err
        end

        if !service_started
            try
                service_log = strip(guest_file_read(handle.domain, KVM_WINDOWS_SERVICE_LOG_PATH; quiet=true))
                service_started = !isempty(service_log)
            catch err
                last_service_log_error = err
            end
        end

        if !service_started
            elapsed = time() - start
            if !kvm_domain_running(handle.domain)
                elapsed_s = round(elapsed; digits=1)
                error("Windows KVM domain $(handle.domain) stopped after $(elapsed_s)s before starting the Buildkite service or writing $(KVM_WINDOWS_EXIT_PATH): $(last_service_log_error)")
            end
            if elapsed > KVM_WINDOWS_SERVICE_START_TIMEOUT
                append_windows_guest_logs(handle)
                elapsed_s = round(elapsed; digits=1)
                timeout_s = round(KVM_WINDOWS_SERVICE_START_TIMEOUT; digits=1)
                error("Timed out after $(elapsed_s)s waiting for Windows Buildkite service log in $(handle.domain) (timeout $(timeout_s)s); last exit-file error: $(last_exit_error); last service-log error: $(last_service_log_error)")
            end
        else
            elapsed = time() - start
            if !kvm_domain_running(handle.domain)
                elapsed_s = round(elapsed; digits=1)
                error("Windows KVM domain $(handle.domain) stopped after $(elapsed_s)s before writing $(KVM_WINDOWS_EXIT_PATH): $(last_exit_error)")
            end
            if elapsed > KVM_WINDOWS_JOB_TIMEOUT
                elapsed_s = round(elapsed; digits=1)
                error("Timed out after $(elapsed_s)s waiting for Windows Buildkite job exit file in $(handle.domain): $(last_exit_error)")
            end
        end
        sleep_until_deadline(KVM_AGENT_POLL_INTERVAL, deadline, context)
    end
end

function append_windows_guest_log(handle::KVMHandle, guest_path::AbstractString)
    contents = try
        strip(guest_file_read(handle.domain, guest_path; quiet=true))
    catch err
        open(handle.log_path, "a") do log
            println(log, "")
            println(log, "Unable to read $(guest_path): $(err)")
        end
        return nothing
    end
    isempty(contents) && return nothing
    open(handle.log_path, "a") do log
        println(log, "")
        println(log, "----- $(guest_path) -----")
        println(log, contents)
        println(log, "----- end $(guest_path) -----")
    end
    return nothing
end

function append_windows_guest_logs(handle::KVMHandle)
    for path in (KVM_WINDOWS_LAUNCHER_LOG_PATH,
                 KVM_WINDOWS_SERVICE_WRAPPER_LOG_PATH,
                 KVM_WINDOWS_SERVICE_LOG_PATH)
        append_windows_guest_log(handle, path)
    end
    return nothing
end

function run_job(handle::KVMHandle, deadline::Union{Nothing,Float64}, job_token::Function)
    open(handle.log_path, "a") do log
        println(log, job_start_banner(handle.job, handle.plan))
    end
    lock(() -> handle.launch.closed && throw(StoppedBeforeLaunch()), handle.launch.lock)
    run(virsh("create", handle.xml_path))
    wait_for_guest_agent(handle.domain;
        timeout=guest_agent_ready_timeout(handle),
        stable_for=guest_agent_stable_for(handle),
        deadline)
    # Minted only now, so a slow boot does not spend the token's lifetime.
    agent_token = job_token()
    commit_launch!(handle.launch)
    pid = guest_exec(handle, agent_token)
    # From here the guest is up; the record covers the job's start-up too.
    # Every sample costs several virsh and guest agent calls, so VMs skip the
    # fast first phase; their jobs take minutes anyway.
    sampler = start_resource_sampler(handle.resources; fast_samples=0)
    try
        kvm_guest(handle.slot.brg) == "windows" && return wait_for_windows_guest_job(handle; deadline)
        return wait_for_guest_exec(handle.domain, pid; deadline)
    finally
        close(sampler)
    end
end

# How long stopping a guest's agent may take before the guest is shut down as
# before; the scripts below finish well within it.
const KVM_AGENT_STOP_TIMEOUT = 10.0

# The scripts below exit 0 once the agent has exited, 3 when no agent was
# running (the job has not started yet, or is over), and otherwise non-zero.
# On Windows the job's launcher then still detaches the cache and writes the
# agent's exit status, which the job's runner waits for as after any job.

# Stops a FreeBSD guest's agent like the Linux backend does: SIGQUIT (the
# agent cancels its job and reports `agent_stop`), then, unless the agent has
# exited by then, two seconds later SIGKILL every other process of the agent's
# user, except the agents and the processes above them, so the agent reports
# at once instead of after its cancel grace period. The agent's user, not its
# process tree: job processes that daemonize leave the tree, and in the guest
# that user runs nothing but the job. Who the agents and their user are is
# looked up before signalling, since they may be gone right after. Kept
# short: FreeBSD's qemu-ga wedges on long commands.
const FREEBSD_AGENT_STOP_SCRIPT = raw"""
a=; for p in $(pgrep -x buildkite-agent); do ps -o args= -p $p | grep -q 'buildkite-agent start' && a="$a $p"; done
[ -n "$a" ] || exit 3
set -- $a; u=$(ps -o user= -p $1 | tr -d ' ')
k=' '; for p in $a; do while [ -n "$p" ] && [ "$p" -gt 1 ]; do k="$k$p "; p=$(ps -o ppid= -p $p | tr -d ' '); done; done
alive() { for p in $a; do kill -0 $p 2>/dev/null && return 0; done; return 1; }
kill -QUIT $a; sleep 2
alive || exit 0
[ -n "$u" ] && [ "$u" != root ] || exit 5
for p in $(pgrep -U "$u"); do case "$k" in *" $p "*) ;; *) kill -KILL $p;; esac; done
i=0; while alive; do [ $i -lt 10 ] || exit 4; sleep 0.5; i=$((i+1)); done
"""

# The same for a Windows guest, whose agent runs below an nssm service with a
# console of its own: two console interrupts (the first asks the agent to stop
# after its job, the second to cancel the job, `agent_stop`), then the job's
# bootstrap process tree is killed, and the agent's exit awaited. The
# interrupts reach every process on the console; the launcher (images since
# 2026-11) ignores them so it outlives the agent and reports its status.
#
# The agent reports the bootstrap's exit code as the job's exit status, and a
# Windows exit code is never negative, so killing the bootstrap like
# `taskkill /F` does (exit code 1) made stopped jobs fail with status 1 where
# a Unix agent reports the SIGKILL as -1. The bootstrap is killed with exit
# code 125 instead, which agents since v3.121.1 report as -1 (it is what a
# bootstrap that fails to set up exits with), still with `agent_stop`. Its
# children, listed first since the bootstrap's death orphans them, are killed
# after it, so that it cannot exit with its own status once they are gone.
const WINDOWS_AGENT_STOP_SCRIPT = raw"""
$p = @(Get-CimInstance Win32_Process -Filter "Name = 'buildkite-agent.exe'")
$agents = @($p | Where-Object { $_.CommandLine -match ' start ' })
if ($agents.Count -eq 0) { exit 3 }
Add-Type -Name C -Namespace K -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint p);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool a);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);
[DllImport("kernel32.dll")] public static extern System.IntPtr OpenProcess(uint a, bool i, uint p);
[DllImport("kernel32.dll")] public static extern bool TerminateProcess(System.IntPtr h, uint c);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);'
foreach ($a in $agents) {
    [K.C]::FreeConsole() | Out-Null
    if ([K.C]::AttachConsole($a.ProcessId)) {
        [K.C]::SetConsoleCtrlHandler([System.IntPtr]::Zero, $true) | Out-Null
        [K.C]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
        Start-Sleep -Milliseconds 500
        [K.C]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
        [K.C]::FreeConsole() | Out-Null
    }
}
Start-Sleep -Seconds 2
$all = @(Get-CimInstance Win32_Process)
foreach ($b in ($all | Where-Object { $_.Name -eq 'buildkite-agent.exe' -and $_.CommandLine -match ' bootstrap' })) {
    $kids = @($all | Where-Object { $_.ParentProcessId -eq $b.ProcessId -and $_.CreationDate -ge $b.CreationDate })
    $h = [K.C]::OpenProcess(1, $false, $b.ProcessId)
    if ($h -ne [System.IntPtr]::Zero) {
        [K.C]::TerminateProcess($h, 125) | Out-Null
        [K.C]::CloseHandle($h) | Out-Null
    }
    foreach ($k in $kids) { & taskkill.exe /F /T /PID $k.ProcessId | Out-Null }
}
$ids = @($agents | ForEach-Object { $_.ProcessId })
for ($i = 0; $i -lt 6; $i++) {
    if (-not (Get-Process -Id $ids -ErrorAction SilentlyContinue)) { exit 0 }
    Start-Sleep -Milliseconds 500
}
exit 4
"""

function agent_stop_payload(guest::AbstractString)
    if guest == "freebsd"
        path, args = "/bin/sh", ["-c", FREEBSD_AGENT_STOP_SCRIPT]
    elseif guest == "windows"
        encoded = Base64.base64encode(reinterpret(UInt8, htol.(transcode(UInt16, WINDOWS_AGENT_STOP_SCRIPT))))
        path = raw"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-EncodedCommand", encoded]
    else
        error("Unsupported KVM guest $(guest)")
    end
    return Dict("execute" => "guest-exec",
        "arguments" => Dict("path" => path, "arg" => args, "capture-output" => false))
end

"""
    stop_guest_agent(handle; deadline)

Run the guest's agent-stop script and wait, until `deadline`, for its result:
`:stopped`, `:no_agent` (the script found none), `:failed` (the deadline had
passed before it could be sent), or `:unconfirmed` when it may have run but did
not report success in time. Once started, the script may have stopped the agent whatever the host
learns afterwards; the job's runner may even have destroyed the guest by then.
"""
function stop_guest_agent(handle::KVMHandle; deadline::Float64)
    time() < deadline || return :failed
    # Once `virsh` runs, the guest may run the script even if the host never
    # hears back (a timeout, a lost response, a killed `virsh`).
    pid = try
        qga_command_json(handle.domain, agent_stop_payload(kvm_guest(handle.slot.brg));
            deadline)["return"]["pid"]
    catch err
        @warn("Unable to tell whether the guest's Buildkite agent was sent a stop",
            domain=handle.domain, exception=(err, catch_backtrace()))
        return :unconfirmed
    end
    try
        while time() < deadline
            status = guest_exec_status(handle.domain, pid; deadline)
            if get(status, "exited", false)
                code = get(status, "exitcode", nothing)
                code == 0 && return :stopped
                code == 3 && return :no_agent
                @warn("The guest's Buildkite agent was not stopped", domain=handle.domain,
                    exit_code=code)
                return :unconfirmed
            end
            sleep(min(0.5, max(deadline - time(), 0.0)))
        end
        @warn("Stopping the guest's Buildkite agent timed out", domain=handle.domain)
    catch err
        @warn("Lost track of stopping the guest's Buildkite agent", domain=handle.domain,
            exception=(err, catch_backtrace()))
    end
    return :unconfirmed
end

# Without `force`, stop the guest's agent so Buildkite records `agent_stop`
# instead of waiting until it considers the agent lost; the job's runner then
# sees the job end as after any other. Unless that is confirmed within
# `timeout`, the guest is then shut down (cleanly, to keep the cache disk
# intact) as before. Buildkite records the job's end with `agent_stop` before
# the agent exits, for Windows and FreeBSD guests alike.
function stop_job(handle::KVMHandle; force::Bool=false, timeout::Real=KVM_AGENT_STOP_TIMEOUT,
                  shutdown_timeout::Float64=KVM_GRACEFUL_SHUTDOWN_TIMEOUT,
                  destroy_timeout::Float64=KVM_DESTROY_TIMEOUT)
    committed = close_launch_gate!(handle.launch)
    if force
        kvm_domain_running(handle.domain) || return :ended
        # A guest that survived its shutdown and `virsh destroy` may still
        # have been stopped inside.
        return stop_kvm_domain(handle.domain; shutdown_timeout, destroy_timeout) ?
            :stopped : :unconfirmed
    end
    committed || return :not_acquired
    return stop_guest_agent(handle; deadline=time() + Float64(timeout))
end

# The marker lives on the disposable OS disk and identifies the job whose cache
# was detached. Missing markers (including older images) require clean shutdown.
function kvm_cache_detached(handle::KVMHandle)
    path = kvm_guest(handle.slot.brg) == "windows" ?
        raw"C:\buildkite-agent\cache-detached" : "/var/run/buildkite-cache-detached"
    try
        return strip(guest_file_read(handle.domain, path; quiet=true)) == handle.job.id
    catch
        return false
    end
end

# Returns `false` while the guest may still run; its disks and the slot's
# resources then stay with it until a later call confirms it is gone.
function reap(handle::KVMHandle; shutdown_timeout::Float64=KVM_GRACEFUL_SHUTDOWN_TIMEOUT,
              destroy_timeout::Float64=KVM_DESTROY_TIMEOUT)
    # First, on every attempt: kills a sample's virsh call in progress rather
    # than waiting for it, and a late sample would only fail against the
    # stopping guest.
    stop_resources!(handle.resources)
    stopped = try
        !kvm_domain_running(handle.domain) ||
            stop_kvm_domain(handle.domain; cache_detached=kvm_cache_detached(handle),
                shutdown_timeout, destroy_timeout)
    catch err
        @error("Unable to stop KVM domain", domain=handle.domain, exception=(err, catch_backtrace()))
        false
    end
    stopped || return false

    for path in (handle.os_overlay, handle.xml_path)
        try
            rm(path; force=true)
        catch err
            @warn("Unable to remove KVM scratch path", path, exception=(err, catch_backtrace()))
        end
    end
    return true
end
