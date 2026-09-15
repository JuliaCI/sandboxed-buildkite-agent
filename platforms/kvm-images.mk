# Shared image-generation lifecycle for the Windows and FreeBSD KVM backends.
# Include after defining BASE_TEMPLATE, WORKER_TEMPLATE, inputs and check-tools.
.DEFAULT_GOAL := all

# Worker disks reference the base, so generations must stay at their final path.
IMAGE_ROOT ?= $(CURDIR)
IMAGE_SUBDIR ?=
BASE_OUTPUT_ROOT := $(abspath $(IMAGE_ROOT)/base-image/images)
WORKER_OUTPUT_ROOT := $(abspath $(IMAGE_ROOT)/buildkite-worker/images)
BASE_IMAGE := $(BASE_OUTPUT_ROOT)$(IMAGE_SUBDIR)/base.qcow2
WORKER_IMAGE := $(WORKER_OUTPUT_ROOT)$(IMAGE_SUBDIR)/worker.qcow2
IMAGE_PACKER_ARGS = $(PACKER_ARGS) $(PLATFORM_PACKER_ARGS)
# buildkite-agent reports the guest's hostname, so name the guest after the host
# the worker image is built for. Windows limits this to 15 characters.
GUEST_HOSTNAME ?= $(shell hostname -s)
WORKER_PACKER_ARGS = -var source_image="$(BASE_IMAGE)" -var guest_hostname="$(GUEST_HOSTNAME)"

# Arguments: template directory, template filename, output root, extra arguments.
# Keep sockets private and short even when image generations have long paths.
define packer_build
@socket_dir=$$(mktemp -d /tmp/kvm-packer.XXXXXX) || exit 1; \
trap 'rm -rf "$$socket_dir"' EXIT HUP INT TERM; \
cd $(1) && packer build $(IMAGE_PACKER_ARGS) $(4) \
    -var qmp_socket_path="$$socket_dir/qmp" -var output_root="$(3)" $(2)
endef

# Evaluate the template without colliding with an existing output generation.
define packer_validate
@validation_root=$$(mktemp -d) || exit 1; \
trap 'rm -rf "$$validation_root"' EXIT HUP INT TERM; \
cd $(1) && packer validate $(IMAGE_PACKER_ARGS) $(3) \
    -var output_root="$$validation_root/output" $(2)
endef

.PHONY: all base worker validate clean cleanall check-packer
all: base worker
base: $(BASE_IMAGE)
worker: $(WORKER_IMAGE)

check-packer:
	@command -v packer >/dev/null

$(BASE_IMAGE): $(BASE_INPUTS) $(SECRET_VARIABLES_FILE) | check-tools $(BASE_BUILD_DEPS)
	$(call packer_build,base-image,$(BASE_TEMPLATE),$(BASE_OUTPUT_ROOT))

$(WORKER_IMAGE): $(WORKER_INPUTS) $(AGENT_HOOK_FILES) $(BASE_IMAGE) $(SECRET_VARIABLES_FILE) | check-tools
	$(call packer_build,buildkite-worker,$(WORKER_TEMPLATE),$(WORKER_OUTPUT_ROOT),$(WORKER_PACKER_ARGS))

validate: $(SECRET_VARIABLES_FILE) | check-packer $(VALIDATE_DEPS)
	$(call packer_validate,base-image,$(BASE_TEMPLATE))
	$(call packer_validate,buildkite-worker,$(WORKER_TEMPLATE),$(WORKER_PACKER_ARGS))

clean:
	rm -rf "$(BASE_OUTPUT_ROOT)$(IMAGE_SUBDIR)" "$(WORKER_OUTPUT_ROOT)$(IMAGE_SUBDIR)"

cleanall: clean
