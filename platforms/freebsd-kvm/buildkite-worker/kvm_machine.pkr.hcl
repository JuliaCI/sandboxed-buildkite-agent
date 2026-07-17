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

source "qemu" "freebsd15" {
    iso_url = "file:${var.source_image}"
    iso_checksum = "none"
    disk_image = true
    use_backing_file = true

    output_directory = "images"
    accelerator = "kvm"
    headless = true

    cpus = 2
    memory = 8196
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
    sources = ["source.qemu.freebsd15"]

    provisioner "file" {
        sources = [
            "../../../agent/hooks",
        ]
        destination = "/tmp/"
    }

    provisioner "shell" {
        environment_vars = [
            "BUILDKITE_AGENT_NAME=worker",
            "SANITIZED_HOSTNAME=worker",
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
