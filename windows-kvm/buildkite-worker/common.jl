using Scratch

include("../../common/common.jl")

function get_agent_hostname(brg::BuildkiteRunnerGroup, agent_idx::Int)
    return "$(brg.name)-$(gethostname()).$(agent_idx)"
end


# Helpers for file paths
function agent_pristine_disk_path(agent_hostname::String)
    return joinpath(@__DIR__, "images", agent_hostname, "$(agent_hostname).qcow2")
end

function agent_scratch_dir(agent_hostname::String)
    return joinpath(@get_scratch!("agent_build"), agent_hostname)
end

function agent_scratch_disk_path(agent_hostname::String)
    return joinpath(agent_scratch_dir(agent_hostname), "$(agent_hostname).qcow2")
end

function agent_scratch_xml_path(agent_hostname::String)
    return joinpath(agent_scratch_dir(agent_hostname), "$(agent_hostname).xml")
end


function agent_mac_address(agent_hostname::String)
    hostname_bytes = reinterpret(UInt8, [Base._crc32c(agent_hostname)])
    return join(string.([0x52, 0x54, 0x00, hostname_bytes[1:3]...]; pad=2, base=16), ":")
end


function build_packer_images(brgs::Vector{BuildkiteRunnerGroup})
    build_dir = joinpath(@__DIR__, "build")
    repo_root = dirname(dirname(@__DIR__))
    buildkite_agent_token_path = joinpath(repo_root, "secrets", "buildkite-agent-token")
    if !isfile(buildkite_agent_token_path)
        error("Must fill out $(buildkite_agent_token_path)")
    end
    buildkite_agent_token = strip(String(read(buildkite_agent_token_path)))

    packer_secrets_file = joinpath(repo_root, "secrets", "windows-credentials.pkrvars.hcl")
    if !isfile(packer_secrets_file)
        error("Must fill out $(packer_secrets_file)")
    end

    packer_builds = Base.Process[]

    agent_idx = 0
    brgs = sort(brgs, by=brg -> brg.name)
    for brg in brgs
        # Ensure that we have a `source_image` type set
        local source_image
        if brg.source_image == "standard"
            source_image = joinpath(dirname(@__DIR__), "base-image", "images", "windows_server_2022.qcow2")
        elseif brg.source_image == "core"
            source_image = joinpath(dirname(@__DIR__), "base-image", "images", "windows_server_2022_core.qcow2")
        else
            error("Runner group $(brg.name) must define a valid source image type!")
        end

        # Ensure that we have `os` set to `windows`
        if brg.tags["os"] != "windows"
            error("Refusing to start up a windows KVM runner that does not self-identify through tags!")
        end

        tags_with_queues = ["$tag=$value" for (tag, value) in brg.tags]
        append!(tags_with_queues, ["queue=$(queue)" for queue in brg.queues])

        for _ in 1:brg.num_agents
            agent_hostname = get_agent_hostname(brg, agent_idx)

            # First, generate .pkr.hcl file in `build`
            mkpath(build_dir)
            packer_file = joinpath(build_dir, "$(agent_hostname).pkr.hcl")
            open(packer_file, write=true) do io
                data = String(read(joinpath(@__DIR__, "buildkite_agent.pkr.hcl.template")))
                data = replace(data, "\${buildkite_agent_token}" => buildkite_agent_token)
                data = replace(data, "\${agent_hostname}" => agent_hostname)
                data = replace(data, "\${sanitized_agent_hostname}" => replace(agent_hostname, "." => "-"))
                data = replace(data, "\${buildkite_tags}" => join(tags_with_queues, ","))
                data = replace(data, "\${source_image}" => source_image)
                write(io, data)
            end

            # Do the actual packer build, but only if the image doesn't exist:
            qcow2_path = agent_pristine_disk_path(agent_hostname)
            if !isfile(qcow2_path)
                @info("Running packer build", agent_hostname)
                packer_cmd = `packer build -var-file=$(packer_secrets_file) $(packer_file)`
                push!(packer_builds, run(pipeline(packer_cmd; stdout, stderr); wait=false))
            end

            agent_idx += 1
        end
    end

    wait.(packer_builds)
end

function check_configs(brgs::Vector{BuildkiteRunnerGroup})
    for brg in brgs
        if brg.num_cpus == 0
            error("Must set `num_cpus` to a nonzero number!")
        end
    end
end


const systemd_unit_name_stem = "buildkite-kvm-"

function generate_systemd_script(io::IO, brg::BuildkiteRunnerGroup;
                                 agent_hostname::String=string(brg.name, "-%i"),
                                 kwargs...)
    start_pre_hooks = SystemdTarget[
        SystemdBashTarget("mkdir -p $(agent_scratch_dir(agent_hostname))"),
        
        # Copy our pristine image to our scratchspace, overwiting the one that already exists
        SystemdBashTarget("cp $(agent_pristine_disk_path(agent_hostname)) $(agent_scratch_dir(agent_hostname))/"),

        # Copy our cache image, but only if we've done an update and should clear the cache.
        SystemdBashTarget("cp -u $(agent_pristine_disk_path(agent_hostname))-1 $(agent_scratch_dir(agent_hostname))/", [:IgnoreExitCode]),

        # Template out our `.xml` configuration file
        SystemdBashTarget(template_kvm_config_command(agent_hostname; num_cpus=brg.num_cpus)),

        # Start up the virsh domain
        SystemdBashTarget("virsh create $(agent_scratch_xml_path(agent_hostname))"),
    ]

    stop_post_hooks = SystemdTarget[
        # Wait 60s for the machine to shutdown; if it doesn't, then destroy it
        SystemdBashTarget("while [[ `virsh domstate $(agent_hostname)` == running ]]; do sleep 1; done")
    ]

    systemd_config = SystemdConfig(;
        description="KVM-hosted buildkite agent $(agent_hostname)",
        working_dir="~",
        restart=SystemdRestartConfig(),
        start_timeout="1min",
        env=Dict("LIBVIRT_DEFAULT_URI" => "qemu:///system"),

        start_pre_hooks,
        exec_start=SystemdBashTarget("trap 'virsh destroy $(agent_hostname)' SIGUSR1; while [[ \$\$(virsh domstate $(agent_hostname) 2>/dev/null) == running ]]; do sleep 1; done"),
        exec_stop=SystemdTarget[
            # First, try to gracefully shutdown the agentvirsh
            SystemdBashTarget("virsh shutdown $(agent_hostname)"),
            # Wait up to 30 seconds for that to take effect
            SystemdBashTarget("END_TIME=\$\$(date -d '30 seconds' +%%s); while [ \$\$(date +%%s) -lt \$\$END_TIME ]; do if [[ \$\$(virsh domstate $(agent_hostname) 2>/dev/null) != running ]]; then break; fi; sleep 1; done"),
        ],
        kill_signal="SIGUSR1",
        stop_post_hooks,
    )
    write(io, systemd_config)

    # We only have to do an apparmor check for backing images, for some reason
    #apparmor_check(agent_scratch_dir(agent_hostname))
    #apparmor_check(joinpath(@__DIR__, "images"))
    apparmor_check(joinpath(dirname(@__DIR__), "base-image", "images"))
end

function template_kvm_config_command(agent_hostname::String;
                                     num_cpus::Int = 8,
                                     memory_kb::Int = num_cpus*3*1024*1024)
    template = joinpath(@__DIR__, "kvm_machine.xml.template")
    target = agent_scratch_xml_path(agent_hostname)

    mappings = Dict(
        "agent_hostname" => agent_hostname,
        "num_cpus" => num_cpus,
        "memory_kb" => memory_kb,
        "agent_scratch_dir" => agent_scratch_dir(agent_hostname),
        # Use the `h` variable defined as part of the command below
        "agent_mac_address" => "52:54:00:\$\${h:0:2}:\$\${h:2:2}:\$\${h:4:2}",
    )
    env_definitions = join(["$(k)=$(v)" for (k,v) in mappings], " ")
    env_names = join(["\$\${$(k)}" for (k, v) in mappings], " ")
    return "h=\$\$(shasum <<<\"$(agent_hostname)\"); $(env_definitions) envsubst '$(env_names)' <$(template) >$(target)"
end

function apparmor_check(prefix::String)
    rules_file = "/etc/apparmor.d/local/abstractions/libvirt-qemu"
    if isfile(rules_file)
        # Parse out the rules, search for a line starting with `prefix``
        rules = String(read(rules_file))
        prefix_lines = filter(l -> !isempty(l) && startswith(prefix, first(split(l, "/**"))), split(rules, "\n"))
        if isempty(prefix_lines)
            line = "$(prefix)/** rk,"
            @warn("AppArmor detected; try adding the following line to the following filename:", filename=rules_file, line)
        end
    end
end
