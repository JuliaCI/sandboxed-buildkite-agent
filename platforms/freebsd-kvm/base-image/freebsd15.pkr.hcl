variable "username" {
    type = string
    default = "julia"
}

variable "password" {
    type = string
    sensitive = true
}

source "qemu" "freebsd15" {
    iso_urls = [
        "https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-amd64-disc1.iso.xz",
    ]
    iso_checksum = "7983bc92cf0e2098df8769c36ae471b235552ebe99733e0673fe7ad85c2e9950"

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
    sources = ["source.qemu.freebsd15"]

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
