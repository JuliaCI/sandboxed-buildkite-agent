all: up

up:
	julia --project -e 'import Pkg; Pkg.instantiate()'
	julia --project launch_agents.jl

down:
	julia --project uninstall_agents.jl
