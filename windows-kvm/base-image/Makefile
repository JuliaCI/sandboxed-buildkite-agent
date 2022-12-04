REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/common.mk

define check_tool
ifeq ($$(shell which $(1)),)
$$(error "Must install $(1)")
endif
endef

# Check for necessary tools
$(eval $(call check_tool,7z))
$(eval $(call check_tool,packer))
$(eval $(call check_tool,mkisofs))
$(eval $(call check_tool,qemu-system-x86_64))
$(eval $(call check_tool,virsh))

# Ensure that we're in the right groups
define check_group
ifeq ($(filter $(shell groups),$(1)),)
$$(error "Must be in the $(1) group")
endif
endef
$(eval $(call check_group,kvm))
$(eval $(call check_group,libvirt))

all: build

downloads virtio-win:
	mkdir -p "$@"

downloads/virtio-win.iso: | downloads
	curl -L -o "$@" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.221-1/virtio-win.iso"

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
