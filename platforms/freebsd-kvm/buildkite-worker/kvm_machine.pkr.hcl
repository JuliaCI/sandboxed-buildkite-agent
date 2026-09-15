variable "qmp_socket_path" {
    type = string
    default = ""
}

variable "output_root" {
    type = string
    default = "images"
}

variable "accelerator" {
    type = string
    default = "kvm"
    validation {
        condition = contains(["kvm", "tcg"], var.accelerator)
        error_message = "Use kvm for native builds or tcg for emulation."
    }
}

variable "firmware" {
    type = string
    default = "/usr/share/AAVMF/AAVMF_CODE.fd"
    description = "Stateless ARM UEFI ROM; ignored for x86-64."
}

variable "memory" {
    type = number
    default = 8196
}

variable "os_disk_size" {
    type = number
    default = 60
}

variable "data_disk_size" {
    type = number
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

variable "arch" {
    type = string
    validation {
        condition = contains(["x86_64", "aarch64"], var.arch)
        error_message = "Use x86_64 or aarch64."
    }
}

source "qemu" "freebsd" {
    iso_url = "file:${var.source_image}"
    iso_checksum = "none"
    disk_image = true
    use_backing_file = true

    output_directory = "${var.output_root}/${var.arch}"
    accelerator = var.accelerator
    qemu_binary = "qemu-system-${var.arch}"
    machine_type = var.arch == "aarch64" ? "virt" : "pc"
    cpu_model = var.accelerator == "kvm" ? "host" : "max"
    # A stateless ROM boots the fallback EFI loader on disk, without shared NVRAM.
    firmware = var.arch == "aarch64" ? var.firmware : ""
    use_pflash = var.arch == "aarch64"
    vga = var.arch == "aarch64" ? "none" : "std"
    qmp_socket_path = var.qmp_socket_path
    headless = true
    qemuargs = concat([
        ["-serial", "file:${var.output_root}/${var.arch}/serial.log"],
    ], var.arch == "aarch64" ? [
        ["-boot", "strict=on"],
    ] : [])

    cpus = 2
    memory = var.memory
    disk_interface = "virtio"
    net_device = "virtio-net-pci"
    disk_size = "${var.os_disk_size}G"
    disk_additional_size = ["${var.data_disk_size}G"]

    communicator = "ssh"
    ssh_username = "root"
    ssh_password = var.password

    vnc_use_password = true
    shutdown_command = "shutdown -p now"

    vm_name = "worker.qcow2"
}

build {
    sources = ["source.qemu.freebsd"]

    provisioner "file" {
        sources = [
            "../../../agent/hooks",
        ]
        destination = "/tmp/"
    }

    provisioner "shell" {
        environment_vars = [
            "BUILDKITE_AGENT_NAME=worker",
            "SANITIZED_HOSTNAME=${var.guest_hostname}",
            "USERNAME=${var.username}",
        ]
        execute_command = "chmod +x {{ .Path }}; env {{ .Vars }} {{ .Path }}"
        scripts = [
            "setup_scripts/format-data-disk.sh",
            "setup_scripts/set-hostname.sh",
            "setup_scripts/enable-ssh.sh",
            "setup_scripts/install-buildkite-agent.sh",
            "setup_scripts/install-qemu-guest-agent.sh",
            "setup_scripts/install-more-dependencies.sh",
            "setup_scripts/configure-dns-resolver.sh",
        ]
    }
}

# vi:ft=hcl sw=4
