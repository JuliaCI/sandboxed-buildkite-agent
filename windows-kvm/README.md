# windows-kvm

This folder contains the configuration needed to build and deploy a windows KVM image that contains within it a buildkite agent ready to serve builds.
The buildkite agent will disconnect after each job, then run its `agent-shutdown` hook, which will cause the machine to restart.
When the VM restarts, the systemd unit that restarts it will reset the OS drive back to its base image.
These images are built with a backing base image (the `base-image` folder) that contains the full OS and global tools, etc...
