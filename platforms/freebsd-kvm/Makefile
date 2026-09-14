ifeq (,$(filter $(ARCH),x86_64 aarch64))
$(error "Specify ARCH=x86_64 or ARCH=aarch64")
endif

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/platforms/common.mk

BASE_IMAGE := base-image/images/$(ARCH)/base.qcow2
WORKER_IMAGE := buildkite-worker/images/$(ARCH)/worker.qcow2

rwildcard = $(wildcard $1$2) $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2))
AGENT_HOOK_FILES := $(call rwildcard,$(REPO_ROOT)/agent/hooks/,*)
BASE_INPUTS := base-image/freebsd.pkr.hcl $(wildcard base-image/setup_scripts/*) $(wildcard base-image/http/*)
WORKER_INPUTS := buildkite-worker/kvm_machine.pkr.hcl $(wildcard buildkite-worker/setup_scripts/*)

define check_tool
ifeq ($$(shell which $(1)),)
$$(error "Must install $(1)")
endif
endef

$(eval $(call check_tool,packer))
$(eval $(call check_tool,mkisofs))
$(eval $(call check_tool,qemu-system-$(ARCH)))
$(eval $(call check_tool,virsh))

define check_group
ifeq ($(filter $(shell groups),$(1)),)
$$(error "Must be in the $(1) group")
endif
endef
$(eval $(call check_group,kvm))
$(eval $(call check_group,libvirt))

.PHONY: all base worker validate clean cleanall

all: base worker

base: $(BASE_IMAGE)

worker: $(WORKER_IMAGE)

$(BASE_IMAGE): $(BASE_INPUTS) $(SECRET_VARIABLES_FILE)
	cd base-image && packer build -force $(PACKER_ARGS) -var arch="$(ARCH)" freebsd.pkr.hcl

$(WORKER_IMAGE): $(WORKER_INPUTS) $(AGENT_HOOK_FILES) $(BASE_IMAGE) $(SECRET_VARIABLES_FILE)
	cd buildkite-worker && packer build -force $(PACKER_ARGS) \
		-var source_image="$(abspath $(BASE_IMAGE))" -var arch="$(ARCH)" \
		kvm_machine.pkr.hcl

validate: $(SECRET_VARIABLES_FILE)
	cd base-image && packer validate $(PACKER_ARGS) -var arch="$(ARCH)" freebsd.pkr.hcl
	cd buildkite-worker && packer validate $(PACKER_ARGS) \
		-var source_image="$(abspath $(BASE_IMAGE))" -var arch="$(ARCH)" \
		kvm_machine.pkr.hcl

clean:
	rm -rf base-image/images/$(ARCH) buildkite-worker/images/$(ARCH)

cleanall: clean
