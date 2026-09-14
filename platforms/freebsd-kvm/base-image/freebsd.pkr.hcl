variable "qmp_socket_path" {
    type = string
    default = ""
}

variable "output_root" {
    type = string
    default = "images"
}

variable "iso_url" {
    type = string
    default = ""
    description = "Optional local file or mirror URL; the release checksum is still verified."
}

variable "boot_wait" {
    type = string
    default = ""
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

variable "arch" {
    type = string
    description = "Architecture of the VM to build"

    validation {
        condition = var.arch == "x86_64" || var.arch == "aarch64"
        error_message = "Unrecognized arch; must be x86_64 or aarch64."
    }
}

variable "username" {
    type = string
    default = "julia"
}

variable "password" {
    type = string
    sensitive = true
}

locals {
    # Default versions used by architecture; building for a given architecture will give
    # you the listed FreeBSD version. The checksum is the SHA256 of the disc1.iso.xz artifact.
    versions = {
        "x86_64" = {
            "arch" = "amd64"
            "release" = "13.4"
            "checksum" = "e00ce3cc1b8b388dfea4f8557d490eef6d287e0bd0a64d7d5862b4b324d5f909"
        }
        "aarch64" = {
            "arch" = "arm64-aarch64"
            "release" = "14.1"
            "checksum" = "e60cf4c5e7101521562b599d2450360dd4e4c3a913b39a07eb3da6a2d805df36"
        }
    }
    version = local.versions[var.arch]
    release = local.version.release
    url_arch = local.version.arch
    iso_name = "FreeBSD-${local.release}-RELEASE-${local.url_arch}-disc1.iso.xz"
}

source "qemu" "freebsd" {
    iso_urls = var.iso_url != "" ? [var.iso_url] : [
        "https://archive.freebsd.org/old-releases/ISO-IMAGES/${local.release}/${local.iso_name}",
        "https://download.freebsd.org/ftp/releases/ISO-IMAGES/${local.release}/${local.iso_name}",
    ]
    iso_checksum = local.version.checksum

    # ARM's single-user console does not accept the USB keyboard. Use the
    # installer Shell button on the video terminal after a normal boot instead.
    boot_wait = var.boot_wait != "" ? var.boot_wait : (var.arch == "aarch64" ? "45s" : "5s")
    boot_command = concat(var.arch == "aarch64" ? [
        "<right><enter><wait5>",
    ] : [
        "<esc><wait>",
        "boot -s<enter>",
        "<wait15s>",
        "/bin/sh<enter><wait>",
        "mdmfs -s 100m md /tmp<enter><wait>",
    ], [
        "dhclient -l /tmp/dhclient.lease.vtnet0 vtnet0<enter><wait5>",
        "fetch -o /tmp/installerconfig http://{{ .HTTPIP }}:{{ .HTTPPort }}/installerconfig<enter><wait5>",
        "export PASSWORD='${var.password}'<enter>",
        "bsdinstall script /tmp/installerconfig<enter>",
    ])

    http_directory = "http"
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
    # Packer's VNC boot commands need a USB keyboard and a supported ARM display.
    # Explicit -device arguments replace Packer's list (it adds the NIC back).
    qemuargs = concat([
        ["-serial", "file:${var.output_root}/${var.arch}/serial.log"],
    ], var.arch == "aarch64" ? [
        # ARM firmware uses bootindex rather than Packer's x86 -boot once=d.
        # Prefer the OS disk after installation, falling back to the CD while blank.
        ["-boot", "strict=on"],
        ["-global", "virtio-blk-pci.bootindex=0"],
        ["-device", "qemu-xhci"],
        ["-device", "usb-kbd"],
        ["-device", "virtio-gpu-pci"],
        ["-device", "virtio-scsi-pci,id=scsi0"],
        ["-device", "scsi-cd,drive=cdrom0,bus=scsi0.0,bootindex=1"],
    ] : [])

    cpus = 2
    memory = var.memory
    disk_size = "60G"
    disk_interface = "virtio"
    net_device = "virtio-net-pci"
    cdrom_interface = var.arch == "aarch64" ? "virtio-scsi" : "ide"

    communicator = "ssh"
    ssh_username = "root"
    ssh_password = var.password

    vnc_use_password  = true
    shutdown_command  = "shutdown -p now"

    vm_name = "base.qcow2"
}

build {
    sources = ["source.qemu.freebsd"]

    provisioner "shell" {
        environment_vars = [
            "USER=${var.username}",
            "PASSWORD=${var.password}",
        ]
        execute_command = "chmod +x {{ .Path }}; env {{ .Vars }} {{ .Path }}"
        scripts = [
            "setup_scripts/pkg.sh",
            "setup_scripts/user.sh",
            "setup_scripts/system.sh",
        ]
    }
}
