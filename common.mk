# By convention, the default target is `all`
all:

# Users need to provide a buildkite agent token file
BUILDKITE_AGENT_TOKEN_FILE=$(REPO_ROOT)/secrets/buildkite-agent-token
$(BUILDKITE_AGENT_TOKEN_FILE):
	@echo "You must add a $(BUILDKITE_AGENT_TOKEN_FILE) file and populate it!"
	@exit 1


# Users need to provide packer with windows credentials
SECRET_VARIABLES_FILE=$(REPO_ROOT)/secrets/windows-credentials.pkrvars.hcl
$(SECRET_VARIABLES_FILE):
	@echo "You must create a $(SECRET_VARIABLES_FILE) file and populate it like so:"
	@echo
	@echo "    # Windows Administrator and main user account password"
	@echo "    password = \"foo\""
	@echo
	@exit 1

# Default packer args are to include the secret variables file
PACKER_ARGS := -var-file="$(SECRET_VARIABLES_FILE)"



# Literal values that are hard to use in Makefiles otherwise:
define newline # a literal \n


endef
COMMA:=,
SPACE:=$(eval) $(eval)

# Makefile debugging trick:
# call print-VARIABLE to see the runtime value of any variable
# (hardened against any special characters appearing in the output)
print-%:
	@echo '$*=$(subst ','\'',$(subst $(newline),\n,$($*)))'