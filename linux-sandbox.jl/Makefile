all: up

up:
	julia --project=.. -e 'import Pkg; Pkg.instantiate()'
	../bin/bk install --config config.toml

down:
	../bin/bk uninstall
