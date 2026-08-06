variable "arch" {
    type = string
    description = "Architecture of the VM to build"

    validation {
        condition = var.arch == "x86_64" || var.arch == "aarch64"
        error_message = "Unrecognized arch; must be x86_64 or aarch64"
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
            "checksum" = "c3c3c6be171359234639260cb9f19ced14dce3b053dd0a6eb3fc8a3165cef926"
        }
    }
    version = lookup(local.versions, var.arch)
    release = lookup(local.version, "release")
    url_arch = lookup(local.version, "arch")
    iso_name = "FreeBSD-${local.release}-RELEASE-${local.url_arch}-disc1.iso.xz"
}

source "qemu" "freebsd" {
    iso_urls = [
        "http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/ISO-IMAGES/${local.release}/${local.iso_name}",
        "https://download.freebsd.org/ftp/releases/ISO-IMAGES/${local.release}/${local.iso_name}",
    ]
    iso_checksum = lookup(local.version, "checksum")

    # Note, you may need to tune this if you're on a slow computer ;)
    boot_wait = "5s"
    boot_command = [
        "<esc><wait>",
        "boot -s<enter>",
        "<wait15s>",
        "/bin/sh<enter><wait>",
        "mdmfs -s 100m md /tmp<enter><wait>",
        "dhclient -l /tmp/dhclient.lease.vtnet0 vtnet0<enter><wait5>",
        "fetch -o /tmp/installerconfig http://{{ .HTTPIP }}:{{ .HTTPPort }}/installerconfig<enter><wait5>",
        "export PASSWORD='${var.password}'<enter>",
        "bsdinstall script /tmp/installerconfig<enter>",
    ]

    http_directory = "http"
    output_directory = "images"
    accelerator = "kvm"
    headless = true

    cpus = 2
    memory = 8196
    disk_size = "60G"
    disk_interface = "virtio"
    net_device = "virtio-net"

    communicator = "ssh"
    ssh_username = "root"
    ssh_password = var.password

    vnc_use_password  = true
    shutdown_command  = "shutdown -p now"

    vm_name = "base.qcow2"
}

build {
    sources = ["source.qemu.freebsd"]

    provisioner "file" {
        source = "../../../agent/secrets/ssh_keys"
        destination = "/tmp/ssh_keys"
    }

    provisioner "shell" {
        environment_vars = [
            "USER=${var.username}",
            "PASSWORD=${var.password}",
        ]
        execute_command = "chmod +x {{ .Path }}; env {{ .Vars }} {{ .Path }}"
        scripts = [
            "setup_scripts/pkg.sh",
            "setup_scripts/user.sh",
            "setup_scripts/secrets.sh",
            "setup_scripts/system.sh",
        ]
    }
}
