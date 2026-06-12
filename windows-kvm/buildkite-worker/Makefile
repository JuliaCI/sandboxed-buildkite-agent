all: up

up launch:
	@julia --project launch_agents.jl

down uninstall:
	@julia --project uninstall_agents.jl

clean:
	rm -rf build
	rm -rf images

distclean: clean down
	@julia --project -e 'include("common.jl"); for brg in read_configs(), idx in 0:(brg.num_agents-1); rm(agent_scratch_dir(brg, get_agent_hostname(brg, idx)); recursive=true, force=true); end'
