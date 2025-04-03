all: up

up launch:
	@julia --project launch_agents.jl

down uninstall:
	@julia --project uninstall_agents.jl

clean:
	rm -rf build
	rm -rf images

distclean: clean down
	rm -rf ~/.julia/scratchspaces/a66863c6-20e8-4ff4-8a62-49f30b1f605e/agent_build/win2k22*
