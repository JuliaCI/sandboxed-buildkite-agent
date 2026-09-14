ifeq (,$(filter $(ARCH),x86_64 aarch64))
$(error "Specify ARCH=x86_64 or ARCH=aarch64")
endif

.DEFAULT_GOAL := all

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/platforms/common.mk

BASE_IMAGE := base-image/images/$(ARCH)/base.qcow2
WORKER_IMAGE := buildkite-worker/images/$(ARCH)/worker.qcow2

rwildcard = $(wildcard $1$2) $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2))
AGENT_HOOK_FILES := $(call rwildcard,$(REPO_ROOT)/agent/hooks/,*)
BASE_INPUTS := base-image/freebsd.pkr.hcl $(wildcard base-image/setup_scripts/*) $(wildcard base-image/http/*)
WORKER_INPUTS := buildkite-worker/kvm_machine.pkr.hcl $(wildcard buildkite-worker/setup_scripts/*)

# Packer builds do not need libvirt, and TCG trials do not need /dev/kvm.
ACCELERATOR ?= kvm
FREEBSD_PACKER_ARGS = $(PACKER_ARGS) -var arch="$(ARCH)" -var accelerator="$(ACCELERATOR)"

.PHONY: check-tools
check-tools:
	@command -v packer >/dev/null
	@command -v qemu-system-$(ARCH) >/dev/null
	@if [ "$(ACCELERATOR)" = kvm ]; then test -r /dev/kvm && test -w /dev/kvm; fi

.PHONY: all base worker validate clean cleanall

all: base worker

base: $(BASE_IMAGE)

worker: $(WORKER_IMAGE)

$(BASE_IMAGE): $(BASE_INPUTS) $(SECRET_VARIABLES_FILE) | check-tools
	cd base-image && packer build -force $(FREEBSD_PACKER_ARGS) freebsd.pkr.hcl

$(WORKER_IMAGE): $(WORKER_INPUTS) $(AGENT_HOOK_FILES) $(BASE_IMAGE) $(SECRET_VARIABLES_FILE) | check-tools
	cd buildkite-worker && packer build -force $(FREEBSD_PACKER_ARGS) \
		-var source_image="$(abspath $(BASE_IMAGE))" \
		kvm_machine.pkr.hcl

# Validation must also work after a build, when the normal output directories exist.
validate: $(SECRET_VARIABLES_FILE) | check-tools
	@validation_root=$$(mktemp -d) || exit 1; trap 'rm -rf "$$validation_root"' EXIT HUP INT TERM; \
	(cd base-image && packer validate $(FREEBSD_PACKER_ARGS) \
		-var output_root="$$validation_root" freebsd.pkr.hcl) && \
	(cd buildkite-worker && packer validate $(FREEBSD_PACKER_ARGS) \
		-var output_root="$$validation_root" -var source_image="$(abspath $(BASE_IMAGE))" \
		kvm_machine.pkr.hcl)

clean:
	rm -rf base-image/images/$(ARCH) buildkite-worker/images/$(ARCH)

cleanall: clean
