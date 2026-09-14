REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/platforms/common.mk

BASE_TEMPLATE := windows_server_2022.pkr.hcl
WORKER_TEMPLATE := kvm_machine.pkr.hcl
REFRESH_TEMPLATE := windows_server_2022_refresh.pkr.hcl
BASE_BUILD_DEPS = $(VIRTIO_WIN_TOOLS)
VALIDATE_DEPS = $(VIRTIO_WIN_DIR)
VIRTIO_WIN_DIR := base-image/virtio-win
VIRTIO_WIN_TOOLS := base-image/virtio-win/virtio-win-guest-tools.exe

rwildcard = $(wildcard $1$2) $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2))
AGENT_HOOK_FILES := $(call rwildcard,$(REPO_ROOT)/agent/hooks/,*)
BASE_INPUTS := base-image/windows_server_2022.pkr.hcl base-image/Autounattend.xml.template $(wildcard base-image/setup_scripts/*)
WORKER_INPUTS := buildkite-worker/kvm_machine.pkr.hcl $(wildcard buildkite-worker/setup_scripts/*)

.PHONY: check-tools refresh validate-refresh check-refresh-source
check-tools: check-packer
	@command -v 7z >/dev/null
	@command -v qemu-system-x86_64 >/dev/null
	@command -v xorriso >/dev/null || command -v mkisofs >/dev/null
	@test -r /dev/kvm && test -w /dev/kvm

base-image/downloads $(VIRTIO_WIN_DIR):
	mkdir -p "$@"

base-image/downloads/virtio-win.iso: | base-image/downloads
	curl -L -o "$@" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.229-1/virtio-win.iso"

$(VIRTIO_WIN_TOOLS): base-image/downloads/virtio-win.iso | $(VIRTIO_WIN_DIR)
	cd base-image/virtio-win && 7z x "../downloads/virtio-win.iso"
	touch -m "$@"

include $(REPO_ROOT)/platforms/kvm-images.mk

# Refresh produces the normal base output in a NEW generation, ready for worker.
check-refresh-source:
	@test -n "$(SOURCE_IMAGE)" && test -f "$(SOURCE_IMAGE)" || \
	    { echo 'Set SOURCE_IMAGE to an existing Windows base image' >&2; exit 1; }

refresh: $(SECRET_VARIABLES_FILE) | check-refresh-source check-tools $(VIRTIO_WIN_TOOLS)
	$(call packer_build,base-image,$(REFRESH_TEMPLATE),$(BASE_OUTPUT_ROOT),$(REFRESH_ARGS) -var source_image="$(abspath $(SOURCE_IMAGE))")

validate-refresh: $(SECRET_VARIABLES_FILE) | check-refresh-source check-packer $(VIRTIO_WIN_DIR)
	$(call packer_validate,base-image,$(REFRESH_TEMPLATE),$(REFRESH_ARGS) -var source_image="$(abspath $(SOURCE_IMAGE))")

cleanall:
	rm -rf base-image/virtio-win
