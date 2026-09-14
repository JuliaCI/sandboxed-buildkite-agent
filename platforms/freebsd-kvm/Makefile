ifeq (,$(filter $(ARCH),x86_64 aarch64))
$(error "Specify ARCH=x86_64 or ARCH=aarch64")
endif

.DEFAULT_GOAL := all

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/platforms/common.mk

IMAGE_SUBDIR := /$(ARCH)
BASE_TEMPLATE := freebsd.pkr.hcl
WORKER_TEMPLATE := kvm_machine.pkr.hcl

rwildcard = $(wildcard $1$2) $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2))
AGENT_HOOK_FILES := $(call rwildcard,$(REPO_ROOT)/agent/hooks/,*)
BASE_INPUTS := base-image/freebsd.pkr.hcl $(wildcard base-image/setup_scripts/*) $(wildcard base-image/http/*)
WORKER_INPUTS := buildkite-worker/kvm_machine.pkr.hcl $(wildcard buildkite-worker/setup_scripts/*)

# Packer builds do not need libvirt, and TCG trials do not need /dev/kvm.
ACCELERATOR ?= kvm
PLATFORM_PACKER_ARGS = -var arch="$(ARCH)" -var accelerator="$(ACCELERATOR)"

.PHONY: check-tools
check-tools:
	@command -v packer >/dev/null
	@command -v qemu-system-$(ARCH) >/dev/null
	@if [ "$(ACCELERATOR)" = kvm ]; then test -r /dev/kvm && test -w /dev/kvm; fi

include $(REPO_ROOT)/platforms/kvm-images.mk
