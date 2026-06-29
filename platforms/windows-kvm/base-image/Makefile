REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
include $(REPO_ROOT)/platforms/common.mk

define check_tool
ifeq ($$(shell which $(1)),)
$$(error "Must install $(1)")
endif
endef

# Check for necessary tools
$(eval $(call check_tool,7z))
$(eval $(call check_tool,packer))
$(eval $(call check_tool,qemu-system-x86_64))
$(eval $(call check_tool,virsh))

# Packer needs an ISO creation tool for `cd_files`; it supports both xorriso
# and mkisofs, so accept either.
ifeq ($(shell which xorriso mkisofs 2>/dev/null | head -1),)
$(error "Must install xorriso (or mkisofs)")
endif

# Ensure that we're in the right groups
define check_group
ifeq ($(filter $(shell groups 2>/dev/null),$(1)),)
$$(error "Must be in the $(1) group")
endif
endef
$(eval $(call check_group,kvm))
$(eval $(call check_group,libvirt))

all: build

downloads virtio-win:
	mkdir -p "$@"

downloads/virtio-win.iso: | downloads
	curl -L -o "$@" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.229-1/virtio-win.iso"

virtio-win/virtio-win-guest-tools.exe: downloads/virtio-win.iso | virtio-win
	cd virtio-win && 7z x "../$<"
	touch -m "$@"

images/%.qcow2: %.pkr.hcl $(SECRET_VARIABLES_FILE) | virtio-win/virtio-win-guest-tools.exe
	packer build $(PACKER_ARGS) $<

build: images/windows_server_2022.qcow2

# Fast path: re-run the software/hardening stages on top of an existing base
# image (default: the published one) without reinstalling Windows + updates.
# Does not refresh the OS or the eval license; do a full `make build` for
# that (at least every ~5 months).  Output lands in `images-refresh/`;
# inspect it, then move it over `images/` and `make publish`.
refresh: $(SECRET_VARIABLES_FILE) | virtio-win/virtio-win-guest-tools.exe
	rm -rf images-refresh
	packer build $(PACKER_ARGS) $(REFRESH_ARGS) windows_server_2022_refresh.pkr.hcl

publish:
	rm -rf pub
	cp -R images pub

validate: $(SECRET_VARIABLES_FILE)
	for f in *.pkr.hcl; do \
		echo "Validating $${f}"; \
		packer validate $(PACKER_ARGS) $${f}; \
	done

clean:
	rm -rf images

cleanall:
	rm -rf images virtio-win
