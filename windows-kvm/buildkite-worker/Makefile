all: build

build:
	@julia --project build_images.jl

up launch:
	@julia --project launch_agents.jl

down uninstall:
	@julia --project uninstall_agents.jl

clean:
	rm -rf build
	rm -rf images
