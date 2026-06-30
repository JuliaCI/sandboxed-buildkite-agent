variable "os_disk_size" {
    type = number
    # Use 100G by default; this should match the base-image
    default = 100
}
variable "data_disk_size" {
    type = number
    # Use 100G by default, for mucho caching
    default = 100
}

variable "username" {
    type = string
    default = "julia"
}
variable "password" {
    type = string
    sensitive = true
}

variable "source_image" {
    type = string
}

variable "buildkite_queues" {
    type = string
}

variable "buildkite_tags" {
    type = string
}

variable "buildkite_agent_token" {
    type = string
    default = "placeholder-token"
    sensitive = true
}

source "qemu" "windows_server_2022" {
    # Make sure this is accelerated by KVM
    accelerator       = "kvm"

    # Use WinRM as the communicator
    communicator      = "winrm"
    winrm_username    = "Administrator"
    winrm_password    = var.password
    winrm_timeout     = "120m"

    # Use the base image built previously
    iso_checksum      = "none"
    disk_image        = true
    use_backing_file  = true

    # Include our setup scripts as another CD (E:/)
    cd_files          = [
        "setup_scripts",
        "../../../agent/secrets",
        "../../../agent/hooks",
    ]

    # Spit this out into `images`
    output_directory  = "images"

    # Hardware/execution parameters
    cpus                 = 2
    memory               = 8196
    disk_size            = "${var.os_disk_size}G"
    disk_additional_size = ["${var.data_disk_size}G"]
    headless             = true

    # Turn on VNC password so that Apple VNC clients can connect
    vnc_use_password  = true

    # Once we're done provisioning, use this to shut down the VM
    shutdown_command  = "shutdown /s /t 1 /f /d p:4:1 /c \"Packer Shutdown\""
}

build {
    source "qemu.windows_server_2022" {
        vm_name = "worker.qcow2"
        iso_url = "file:${var.source_image}"
    }

    provisioner "powershell" {
        environment_vars = [
            "WINDOWS_PASSWORD=${var.password}",
            "sanitized_hostname=worker",

            # These get auto-populated (see https://raw.githubusercontent.com/buildkite/agent/main/install.ps1)
            "buildkiteAgentToken=${var.buildkite_agent_token}",
            "buildkiteAgentTags=${var.buildkite_tags}",
            "buildkiteAgentQueues=${var.buildkite_queues}",

            # These don't currently get auto-replaced, but someday they might!
            "buildkiteAgentName=worker",
        ]
        inline = [". D:\\setup_scripts\\setup.ps1"]
        elevated_user = var.username
        elevated_password = var.password
    }

    # Add a restart at the end, to try and get rid of any pending restarts
    # that the image might have due to installed files.
    provisioner "windows-restart" {}
}
