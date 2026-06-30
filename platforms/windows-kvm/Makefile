REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
include $(REPO_ROOT)/platforms/common.mk

QUEUES ?= default
TAGS ?= os=windows,arch=x86_64

BASE_IMAGE := base-image/images/base.qcow2
WORKER_IMAGE := buildkite-worker/images/worker.qcow2
VIRTIO_WIN_TOOLS := base-image/virtio-win/virtio-win-guest-tools.exe

rwildcard = $(wildcard $1$2) $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2))
AGENT_HOOK_FILES := $(call rwildcard,$(REPO_ROOT)/agent/hooks/,*)
AGENT_SECRET_FILES := $(call rwildcard,$(REPO_ROOT)/agent/secrets/,*)
BASE_INPUTS := base-image/windows_server_2022.pkr.hcl base-image/Autounattend.xml.template $(wildcard base-image/setup_scripts/*) $(AGENT_SECRET_FILES)
WORKER_INPUTS := buildkite-worker/kvm_machine.pkr.hcl $(wildcard buildkite-worker/setup_scripts/*) $(AGENT_SECRET_FILES)

define check_tool
ifeq ($$(shell which $(1)),)
$$(error "Must install $(1)")
endif
endef

$(eval $(call check_tool,7z))
$(eval $(call check_tool,packer))
$(eval $(call check_tool,qemu-system-x86_64))
$(eval $(call check_tool,virsh))

ifeq ($(shell which xorriso mkisofs 2>/dev/null | head -1),)
$(error "Must install xorriso (or mkisofs)")
endif

define check_group
ifeq ($(filter $(shell groups 2>/dev/null),$(1)),)
$$(error "Must be in the $(1) group")
endif
endef
$(eval $(call check_group,kvm))
$(eval $(call check_group,libvirt))

.PHONY: all base worker validate refresh publish clean cleanall

all: base worker

base: $(BASE_IMAGE)

worker: $(WORKER_IMAGE)

base-image/downloads base-image/virtio-win:
	mkdir -p "$@"

base-image/downloads/virtio-win.iso: | base-image/downloads
	curl -L -o "$@" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.229-1/virtio-win.iso"

$(VIRTIO_WIN_TOOLS): base-image/downloads/virtio-win.iso | base-image/virtio-win
	cd base-image/virtio-win && 7z x "../downloads/virtio-win.iso"
	touch -m "$@"

$(BASE_IMAGE): $(BASE_INPUTS) $(SECRET_VARIABLES_FILE) | $(VIRTIO_WIN_TOOLS)
	cd base-image && packer build -force $(PACKER_ARGS) windows_server_2022.pkr.hcl

$(WORKER_IMAGE): $(WORKER_INPUTS) $(AGENT_HOOK_FILES) $(BASE_IMAGE) $(SECRET_VARIABLES_FILE)
	cd buildkite-worker && packer build -force $(PACKER_ARGS) \
		-var source_image="$(abspath $(BASE_IMAGE))" \
		-var buildkite_queues="$(QUEUES)" \
		-var buildkite_tags="$(TAGS)" \
		kvm_machine.pkr.hcl

validate: $(SECRET_VARIABLES_FILE) | $(VIRTIO_WIN_TOOLS)
	cd base-image && packer validate $(PACKER_ARGS) windows_server_2022.pkr.hcl
	cd buildkite-worker && packer validate $(PACKER_ARGS) \
		-var source_image="$(abspath $(BASE_IMAGE))" \
		-var buildkite_queues="$(QUEUES)" \
		-var buildkite_tags="$(TAGS)" \
		kvm_machine.pkr.hcl

refresh: $(SECRET_VARIABLES_FILE) | $(VIRTIO_WIN_TOOLS)
	cd base-image && rm -rf images-refresh && packer build $(PACKER_ARGS) $(REFRESH_ARGS) windows_server_2022_refresh.pkr.hcl

publish:
	rm -rf base-image/pub
	cp -R base-image/images base-image/pub

clean:
	rm -rf base-image/images base-image/images-refresh buildkite-worker/images buildkite-worker/build

cleanall: clean
	rm -rf base-image/virtio-win
