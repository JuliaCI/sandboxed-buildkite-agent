all: up

up launch:
	@../../bin/bk install --config config.toml

down uninstall:
	@../../bin/bk uninstall

clean:
	rm -rf build
	rm -rf images

distclean: clean down
