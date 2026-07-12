using Test
using SandboxedBuildkiteAgent
import SandboxedBuildkiteAgent:
    create_job_cgroup,
    remove_job_cgroup,
    scheduler_cgroup_root,
    setup_job_cgroups!

Sys.islinux() || error("this integration test requires Linux")

root = scheduler_cgroup_root()
setup_job_cgroups!(root)

effective_cpus = strip(read(joinpath(root, "cpuset.cpus.effective"), String))
cpus = String(first(split(effective_cpus, ',')))
mems = strip(read(joinpath(root, "cpuset.mems.effective"), String))

job_root = create_job_cgroup(root, "integration-test"; cpus)
try
    @test strip(read(joinpath(job_root, "cpuset.mems"), String)) == mems
    @test strip(read(joinpath(job_root, "cpuset.cpus"), String)) == cpus
finally
    remove_job_cgroup(job_root)
end

println("delegated cgroup integration test passed on Julia $(VERSION)")
