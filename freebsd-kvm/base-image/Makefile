REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/common.mk

define check_tool
ifeq ($$(shell which $(1)),)
$$(error "Must install $(1)")
endif
endef

# Check for necessary tools
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

images/%.qcow2: %.pkr.hcl $(SECRET_VARIABLES_FILE)
	packer build $(PACKER_ARGS) $<

build: images/freebsd12.qcow2

validate: $(SECRET_VARIABLES_FILE)
	for f in *.pkr.hcl; do \
		echo "Validating $${f}"; \
		packer validate $(PACKER_ARGS) $${f}; \
	done

clean:
	rm -rf images

cleanall: clean
