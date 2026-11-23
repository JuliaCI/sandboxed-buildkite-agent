REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

# Windows Server 2025. The templates check that the images they build or
# build on are of this build and have a cumulative update past the ISO's
# update revision (UBR): Windows Update does not report it as an error when
# it installs none.
WINDOWS_BUILD := 26100
WINDOWS_ISO_UBR := 1742
PLATFORM_PACKER_ARGS := -var windows_build=$(WINDOWS_BUILD) -var windows_iso_ubr=$(WINDOWS_ISO_UBR)
BASE_TEMPLATE := windows_server.pkr.hcl
WORKER_TEMPLATE := kvm_machine.pkr.hcl
REFRESH_TEMPLATE := windows_server_refresh.pkr.hcl
BASE_BUILD_DEPS = $(VIRTIO_WIN_STAMP)
VALIDATE_DEPS = $(VIRTIO_WIN_DIR)
# The drivers and guest agent come from this virtio-win release; the stamp makes
# a version change re-extract them.
VIRTIO_WIN_VERSION := 0.1.302
VIRTIO_WIN_SHA256 := 303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d
VIRTIO_WIN_ISO := base-image/downloads/virtio-win-$(VIRTIO_WIN_VERSION).iso
VIRTIO_WIN_DIR := base-image/virtio-win
VIRTIO_WIN_STAMP := $(VIRTIO_WIN_DIR)/.extracted-$(VIRTIO_WIN_VERSION)

BASE_INPUTS := base-image/windows_server.pkr.hcl base-image/Autounattend.xml.template $(wildcard base-image/setup_scripts/*)
WORKER_INPUTS := buildkite-worker/kvm_machine.pkr.hcl $(wildcard buildkite-worker/setup_scripts/*)

.PHONY: check-tools refresh validate-refresh check-refresh-source
check-tools: check-packer
	@command -v 7z >/dev/null
	@command -v qemu-system-x86_64 >/dev/null
	@command -v xorriso >/dev/null || command -v mkisofs >/dev/null
	@test -r /dev/kvm && test -w /dev/kvm

base-image/downloads $(VIRTIO_WIN_DIR):
	mkdir -p "$@"

$(VIRTIO_WIN_ISO): | base-image/downloads
	curl -fsSL -o "$@.part" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$(VIRTIO_WIN_VERSION)-1/virtio-win-$(VIRTIO_WIN_VERSION).iso"
	echo "$(VIRTIO_WIN_SHA256)  $@.part" | sha256sum -c -
	mv "$@.part" "$@"

$(VIRTIO_WIN_STAMP): $(VIRTIO_WIN_ISO)
	echo "$(VIRTIO_WIN_SHA256)  $<" | sha256sum -c -
	rm -rf "$(VIRTIO_WIN_DIR)"
	mkdir -p "$(VIRTIO_WIN_DIR)"
	cd "$(VIRTIO_WIN_DIR)" && 7z x -y "../downloads/virtio-win-$(VIRTIO_WIN_VERSION).iso" >/dev/null
	touch "$@"

include $(REPO_ROOT)/platforms/kvm-images.mk

# Refresh produces the normal base output in a NEW generation, ready for worker.
check-refresh-source:
	@test -n "$(SOURCE_IMAGE)" && test -f "$(SOURCE_IMAGE)" || \
	    { echo 'Set SOURCE_IMAGE to an existing Windows base image' >&2; exit 1; }

refresh: $(SECRET_VARIABLES_FILE) | check-refresh-source check-tools $(VIRTIO_WIN_STAMP)
	$(call packer_build,base-image,$(REFRESH_TEMPLATE),$(BASE_OUTPUT_ROOT),$(REFRESH_ARGS) -var source_image="$(abspath $(SOURCE_IMAGE))")

validate-refresh: $(SECRET_VARIABLES_FILE) | check-refresh-source check-packer $(VIRTIO_WIN_DIR)
	$(call packer_validate,base-image,$(REFRESH_TEMPLATE),$(REFRESH_ARGS) -var source_image="$(abspath $(SOURCE_IMAGE))")

cleanall:
	rm -rf base-image/virtio-win
