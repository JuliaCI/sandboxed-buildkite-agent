mutable struct KVMBackend <: PlatformBackend
    logdir::String
    groups::Vector{String}
    domain_prefixes::Vector{String}

    KVMBackend(logdir::String, brgs::Vector{BuildkiteRunnerGroup}=BuildkiteRunnerGroup[]) =
        new(logdir, sort(unique(brg.name for brg in brgs)), String[])
end

backend_name(::KVMBackend) = BACKEND_KVM

const KVM_URI = "qemu:///system"
const KVM_AGENT_READY_TIMEOUT = 30.0
const KVM_WINDOWS_AGENT_READY_TIMEOUT = 60.0
const KVM_WINDOWS_AGENT_STABLE_FOR = 10.0
const KVM_AGENT_POLL_INTERVAL = 2.0
const KVM_SHUTDOWN_TIMEOUT = 2 * 60.0
const KVM_SHUTDOWN_POLL_INTERVAL = 2.0
const KVM_GUEST_EXEC_STATUS_GRACE = 30.0
const KVM_WINDOWS_JOB_TIMEOUT = 6 * 60 * 60.0
const KVM_WINDOWS_SERVICE_START_TIMEOUT = 5 * 60.0
const KVM_WINDOWS_EXIT_PATH = raw"C:\buildkite-agent\run-buildkite-job.exit"
const KVM_WINDOWS_LAUNCHER_LOG_PATH = raw"C:\buildkite-agent\run-buildkite-job-launcher.log"
const KVM_WINDOWS_SERVICE_WRAPPER_LOG_PATH = raw"C:\buildkite-agent\run-buildkite-job-service.log"
const KVM_WINDOWS_SERVICE_LOG_PATH = raw"C:\buildkite-agent\run-buildkite-job.log"
const KVM_MEMORY_KIB_PER_CPU = 4 * 1024 * 1024

struct KVMHandle
    backend::KVMBackend
    slot::Slot
    job::Job
    plan::CachePlan
    domain::String
    xml_path::String
    os_overlay::String
    cache_overlay::String
    log_path::String
end

function kvm_group_prefix(group::AbstractString)
    return string(group, "-", get_short_hostname(), ".")
end

function kvm_group_prefixes(groups)
    return sort(unique(kvm_group_prefix(group) for group in groups))
end

function setup_backend!(backend::KVMBackend, slots)
    groups = isempty(backend.groups) ? sort(unique(slot.brg.name for slot in slots)) : backend.groups
    backend.domain_prefixes = kvm_group_prefixes(groups)
    return nothing
end

function kvm_guest(brg::BuildkiteRunnerGroup)
    brg.kvm.guest === nothing && error("KVM runner group '$(brg.name)' must set `guest`")
    return brg.kvm.guest
end

function kvm_image_dir(brg::BuildkiteRunnerGroup)
    return repo_path("platforms", "$(kvm_guest(brg))-kvm", "buildkite-worker", "images")
end

function kvm_pristine_os_image(brg::BuildkiteRunnerGroup)
    return joinpath(kvm_image_dir(brg), "worker.qcow2")
end

function kvm_pristine_cache_image(brg::BuildkiteRunnerGroup)
    return string(kvm_pristine_os_image(brg), "-1")
end

function kvm_xml_template(brg::BuildkiteRunnerGroup)
    return repo_path("platforms", "$(kvm_guest(brg))-kvm", "buildkite-worker", "kvm_machine.xml.template")
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

function kvm_memory_kib(brg::BuildkiteRunnerGroup)
    return brg.num_cpus * KVM_MEMORY_KIB_PER_CPU
end

function kvm_capacity_requirements(brgs::Vector{BuildkiteRunnerGroup})
    vcpus = sum(brg.num_agents * brg.num_cpus for brg in brgs)
    memory_kib = sum(brg.num_agents * kvm_memory_kib(brg) for brg in brgs)
    return (vcpus=vcpus, memory_kib=memory_kib)
end

function format_kib_as_gib(kib::Integer)
    return round(kib / 1024^2; digits=1)
end

function check_kvm_host_capacity(brgs::Vector{BuildkiteRunnerGroup};
                                 cpu_threads::Integer=Sys.CPU_THREADS,
                                 memory_kib::Integer=Sys.total_memory() ÷ 1024)
    requirements = kvm_capacity_requirements(brgs)
    if requirements.vcpus > cpu_threads
        error("KVM runner groups request $(requirements.vcpus) vCPUs, but this host has only $(cpu_threads) CPU threads")
    end
    if requirements.memory_kib > memory_kib
        requested_gib = format_kib_as_gib(requirements.memory_kib)
        host_gib = format_kib_as_gib(memory_kib)
        error("KVM runner groups request $(requested_gib) GiB of guest memory, but this host has only $(host_gib) GiB")
    end
    return nothing
end

function kvm_template_vars(handle::KVMHandle)
    brg = handle.slot.brg
    return Dict(
        "agent_hostname" => handle.domain,
        "num_cpus" => string(brg.num_cpus),
        "memory_kb" => string(kvm_memory_kib(brg)),
        "agent_scratch_dir" => kvm_scratch_dir(handle.slot),
        "os_disk_path" => handle.os_overlay,
        "cache_disk_path" => handle.cache_overlay,
        "log_path" => kvm_serial_log_path(handle.log_path),
        "agent_mac_address" => agent_mac_address(handle.domain),
    )
end

function render_template(template::AbstractString, vars::Dict{String,String})
    data = read(template, String)
    for (key, value) in vars
        data = replace(data, "\${$(key)}" => value)
    end
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

function kvm_agent_token(brg::BuildkiteRunnerGroup)
    token_path = joinpath(secrets_dir(brg), "buildkite-agent-token")
    return chomp(read(token_path, String))
end

function kvm_buildkite_agent_env(handle::KVMHandle)
    brg = handle.slot.brg
    return [
        "BUILDKITE_AGENT_TOKEN=$(kvm_agent_token(brg))",
        "BUILDKITE_AGENT_NAME=$(handle.domain)",
        "BUILDKITE_AGENT_TAGS=$(buildkite_agent_tags(brg))",
        "BUILDKITE_PLUGIN_JULIA_ARCH=$(brg.tags["arch"])",
    ]
end

function check_config(::KVMBackend, brgs::Vector{BuildkiteRunnerGroup})
    require_libvirt_access()
    Sys.which("qemu-img") !== nothing || error("KVM backend requires `qemu-img` on PATH")

    for brg in brgs
        if brg.num_cpus == 0
            error("KVM runner group '$(brg.name)' must set `num_cpus` to a nonzero number")
        end
        kvm_guest(brg) in KVM_GUESTS ||
            error("KVM runner group '$(brg.name)' has invalid guest '$(brg.kvm.guest)'")
        brg.tags["os"] == kvm_guest(brg) ||
            error("KVM runner group '$(brg.name)' must advertise os=$(kvm_guest(brg))")

        os_image = kvm_pristine_os_image(brg)
        cache_image = kvm_pristine_cache_image(brg)
        isfile(os_image) || error("KVM runner group '$(brg.name)' is missing OS image $(os_image)")
        isfile(cache_image) || error("KVM runner group '$(brg.name)' is missing cache image $(cache_image)")
        isfile(kvm_xml_template(brg)) ||
            error("KVM runner group '$(brg.name)' is missing XML template $(kvm_xml_template(brg))")
    end
    check_kvm_host_capacity(brgs)
    return nothing
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

function shutdown_kvm_domain(domain::AbstractString;
                             timeout::Real=KVM_SHUTDOWN_TIMEOUT,
                             poll_interval::Real=KVM_SHUTDOWN_POLL_INTERVAL,
                             run_fn=run,
                             running_fn=kvm_domain_running,
                             sleep_fn=sleep,
                             time_fn=time)
    running_fn(domain) || return :not_running

    run_fn(ignorestatus(virsh("shutdown", domain)))
    deadline = time_fn() + Float64(timeout)
    while running_fn(domain)
        if time_fn() >= deadline
            run_fn(ignorestatus(virsh("destroy", domain)))
            return :destroyed
        end
        sleep_for = min(Float64(poll_interval), max(deadline - time_fn(), 0.0))
        sleep_fn(sleep_for)
    end
    return :shutdown
end

function matching_kvm_domains(backend::KVMBackend)
    prefixes = backend.domain_prefixes
    isempty(prefixes) && (prefixes = kvm_group_prefixes(backend.groups))
    isempty(prefixes) && return String[]
    return [domain for domain in running_kvm_domains()
        if any(prefix -> startswith(domain, prefix), prefixes)]
end

function cleanup(backend::KVMBackend)
    domains = matching_kvm_domains(backend)
    for domain in domains
        @warn("Stopping stale KVM domain", domain)
        result = shutdown_kvm_domain(domain)
        if result == :destroyed
            @warn("Destroyed stale KVM domain after graceful shutdown timed out",
                domain, timeout=KVM_SHUTDOWN_TIMEOUT)
        end
    end
    survivors = matching_kvm_domains(backend)
    isempty(survivors) || error("Refusing to launch KVM jobs; stale domains survived cleanup: $(join(survivors, ", "))")
    return nothing
end

function prepare(backend::KVMBackend, slot::Slot, job::Job, plan::CachePlan)
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
        log_path = joinpath(backend.logdir, domain, "$(safe_path_component(job.id, "unknown-job")).log")
        prepare_kvm_log_file(log_path)
        prepare_kvm_log_file(kvm_serial_log_path(log_path))

        handle = KVMHandle(backend, slot, job, plan, domain, xml_path, os_overlay, cache_overlay, log_path)
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

function qga_command(domain::AbstractString, payload::Dict; quiet::Bool=false)
    json = JSON.json(payload)
    cmd = virsh("qemu-agent-command", domain, json)
    return quiet ? read(pipeline(cmd; stderr=devnull), String) : read(cmd, String)
end

function qga_command_json(domain::AbstractString, payload::Dict; quiet::Bool=false)
    return JSON.parse(qga_command(domain, payload; quiet))
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

function freebsd_guest_exec(handle::KVMHandle)
    return Dict(
        "execute" => "guest-exec",
        "arguments" => Dict(
            "path" => "/usr/local/bin/run-buildkite-job.sh",
            "arg" => [handle.job.id],
            "env" => kvm_buildkite_agent_env(handle),
            "capture-output" => false,
        ),
    )
end

function windows_guest_exec(handle::KVMHandle)
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
            "env" => kvm_buildkite_agent_env(handle),
            "capture-output" => false,
        ),
    )
end

function guest_exec_payload(handle::KVMHandle)
    guest = kvm_guest(handle.slot.brg)
    guest == "freebsd" && return freebsd_guest_exec(handle)
    guest == "windows" && return windows_guest_exec(handle)
    error("Unsupported KVM guest $(guest)")
end

function guest_exec(handle::KVMHandle)
    response = qga_command_json(handle.domain, guest_exec_payload(handle))
    return response["return"]["pid"]
end

function guest_exec_status(domain::AbstractString, pid)
    return qga_command_json(domain, Dict(
        "execute" => "guest-exec-status",
        "arguments" => Dict("pid" => pid),
    ))["return"]
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
                if code != 0
                    append_windows_guest_logs(handle)
                end
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

function run_job(handle::KVMHandle, deadline::Union{Nothing,Float64}=nothing)
    open(handle.log_path, "a") do log
        println(log, "Starting KVM Buildkite job $(handle.job.id) in $(handle.plan.pipeline)/$(handle.plan.trust)")
    end
    run(virsh("create", handle.xml_path))
    wait_for_guest_agent(handle.domain;
        timeout=guest_agent_ready_timeout(handle),
        stable_for=guest_agent_stable_for(handle),
        deadline)
    pid = guest_exec(handle)
    kvm_guest(handle.slot.brg) == "windows" && return wait_for_windows_guest_job(handle; deadline)
    return wait_for_guest_exec(handle.domain, pid; deadline)
end

function reap(handle::KVMHandle)
    try
        result = shutdown_kvm_domain(handle.domain)
        if result == :destroyed
            @warn("Destroyed KVM domain after graceful shutdown timed out",
                domain=handle.domain,
                timeout=KVM_SHUTDOWN_TIMEOUT)
        end
    catch err
        @warn("Unable to stop KVM domain", domain=handle.domain, exception=(err, catch_backtrace()))
    end

    for path in (handle.os_overlay, handle.xml_path)
        try
            rm(path; force=true)
        catch err
            @warn("Unable to remove KVM scratch path", path, exception=(err, catch_backtrace()))
        end
    end
    return nothing
end
