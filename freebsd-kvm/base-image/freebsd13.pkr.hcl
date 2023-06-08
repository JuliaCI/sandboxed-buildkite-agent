variable "username" {
    type = string
    default = "julia"
}

variable "password" {
    type = string
    sensitive = true
}

source "qemu" "freebsd13" {
    iso_url = "https://download.freebsd.org/ftp/releases/amd64/amd64/ISO-IMAGES/13.2/FreeBSD-13.2-RELEASE-amd64-disc1.iso.xz"
    iso_checksum = "52a1420db86802cfab8bafa36eccaa78c8b65b59673cbdf690e4b57f9d80f01f"

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

    vm_name = "freebsd13.qcow2"
}

build {
    sources = ["source.qemu.freebsd13"]

    provisioner "file" {
        source = "../../secrets/ssh_keys"
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
