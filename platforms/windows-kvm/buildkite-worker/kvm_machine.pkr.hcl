variable "output_root" {
    type = string
    default = "images"
}

variable "qmp_socket_path" {
    type = string
    default = ""
}

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

variable "guest_hostname" {
    type = string
    description = "Hostname the guest reports to Buildkite; normally the build host's short name plus -vm."
    validation {
        condition = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$", var.guest_hostname))
        error_message = "Use 1-15 letters, digits or hyphens; Windows rejects anything longer."
    }
}

variable "windows_build" {
    type = string
    description = "The Windows build (CurrentBuildNumber) the images are made of; set by the Makefile."
}

variable "windows_iso_ubr" {
    type = number
    description = "The update revision (UBR) of the install ISO; images must be past it. Set by the Makefile."
}

source "qemu" "windows_server" {
    # Make sure this is accelerated by KVM
    cpu_model         = "host"
    accelerator       = "kvm"

    # Match kvm_machine.xml.template, including the NIC's PCI location, so
    # Windows reuses the installed adapter on each fresh job overlay.
    machine_type      = "q35"

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
        "../../../agent/hooks",
    ]

    # The Makefile selects the output generation.
    output_directory  = var.output_root

    # Hardware/execution parameters
    cpus                 = 2
    memory               = 8196
    disk_size            = "${var.os_disk_size}G"
    disk_additional_size = ["${var.data_disk_size}G"]
    qmp_socket_path   = var.qmp_socket_path
    headless             = true

    # Turn on VNC password so that Apple VNC clients can connect
    vnc_use_password  = true

    # Explicit -device arguments replace Packer's own NIC (Packer keeps its
    # user-mode -netdev, which the WinRM connection relies on).
    qemuargs          = [
        ["-device", "pcie-root-port,port=16,chassis=1,id=pci.1,bus=pcie.0,multifunction=on,addr=0x2"],
        ["-device", "virtio-net-pci,netdev=user.0,bus=pci.1,addr=0x0"],
    ]

    # Once we're done provisioning, use this to shut down the VM
    shutdown_command  = "shutdown /s /t 1 /f /d p:4:1 /c \"Packer Shutdown\""
    shutdown_timeout  = "10m"
}

build {
    source "qemu.windows_server" {
        vm_name = "worker.qcow2"
        iso_url = "file:${var.source_image}"
    }

    provisioner "powershell" {
        inline = [
            "$v = Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'",
            "if ($v.CurrentBuildNumber -ne '${var.windows_build}') { throw \"the base image is Windows build $($v.CurrentBuildNumber), expected ${var.windows_build}\" }",
            "if ([int]$v.UBR -le ${var.windows_iso_ubr}) { throw \"the base image has no cumulative update (UBR $($v.UBR))\" }",
        ]
    }

    provisioner "powershell" {
        environment_vars = [
            "WINDOWS_PASSWORD=${var.password}",
            "sanitized_hostname=${var.guest_hostname}",
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
