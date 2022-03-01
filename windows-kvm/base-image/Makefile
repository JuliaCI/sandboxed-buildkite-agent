REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/common.mk

all: build

downloads virtio-win:
	mkdir -p "$@"

downloads/virtio-win.iso: | downloads
	curl -L -o "$@" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.215-2/virtio-win.iso"

virtio-win/virtio-win-guest-tools.exe: downloads/virtio-win.iso | virtio-win
	cd virtio-win && 7z x "../$<"
	touch -m "$@"

images/%.qcow2: %.pkr.hcl $(SECRET_VARIABLES_FILE) | virtio-win/virtio-win-guest-tools.exe
	packer build $(PACKER_ARGS) $<

build: images/windows_server_2022.qcow2

validate: $(SECRET_VARIABLES_FILE)
	for f in *.pkr.hcl; do \
		echo "Validating $${f}"; \
		packer validate $(PACKER_ARGS) $${f}; \
	done

clean:
	rm -rf images

cleanall:
	rm -rf images virtio-win
