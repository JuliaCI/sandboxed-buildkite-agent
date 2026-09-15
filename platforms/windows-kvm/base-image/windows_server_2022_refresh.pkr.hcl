variable "output_root" {
    type = string
    default = "images"
}

variable "qmp_socket_path" {
    type = string
    default = ""
}

# "Refresh" tier of the base image: instead of reinstalling Windows from the
# (frozen 2021 RTM) eval ISO and sitting through ~4 years of cumulative
# updates (~an hour), boot an EXISTING base image and just re-run the
# software stages (2-*) and hardening/tuning stages (3-*).  Use this to pick
# up new tool versions or setup-script changes in minutes.
#
# Limitations:
#   - does NOT install Windows updates (use `make base` for that, or wait
#     for the slipstream flow); the refreshed image keeps the OS bits of its
#     source image
#   - does NOT reset the 180-day eval license clock: schedule a full
#     `make base` at least every ~5 months
#
# Usage: make refresh IMAGE_ROOT=/path/to/new-generation SOURCE_IMAGE=/path/to/base.qcow2

variable "password" {
    type = string
    sensitive = true
}

variable "source_image" {
    type = string
}

source "qemu" "windows_server_2022_refresh" {
    accelerator       = "kvm"

    # Match the run-time environment, including the NIC's PCI location (see
    # windows_server_2022.pkr.hcl for why that matters).
    machine_type      = "q35"

    # Boot a copy of the existing base image instead of installing from ISO.
    # WinRM is already enabled in it, so packer connects right away.
    disk_image        = true
    iso_url           = "${var.source_image}"
    iso_checksum      = "none"

    communicator      = "winrm"
    winrm_username    = "Administrator"
    winrm_password    = "${var.password}"
    winrm_timeout     = "20m"

    # Same provisioning CD as the full build
    cd_files          = [
        "setup_scripts",
        "virtio-win",
    ]

    output_directory  = var.output_root

    cpus              = 8
    memory            = 8192
    disk_size         = "100G"
    qmp_socket_path   = var.qmp_socket_path
    headless          = true
    vnc_use_password  = false

    qemuargs          = [
        ["-netdev", "user,id=user.0,hostfwd=tcp:127.0.0.1:{{ .SSHHostPort }}-:5985,hostfwd=tcp:127.0.0.1:22922-:22"],
        ["-device", "pcie-root-port,port=16,chassis=1,id=pci.1,bus=pcie.0,multifunction=on,addr=0x2"],
        ["-device", "virtio-net-pci,netdev=user.0,bus=pci.1,addr=0x0"],
    ]

    shutdown_command  = "shutdown /s /t 1 /f /d p:4:1 /c \"Packer Shutdown\""
}

build {
    source "qemu.windows_server_2022_refresh" {
        vm_name = "base.qcow2"
    }

    # Re-run stages 2..3 from the provisioning CD (located by content, the
    # drive letter depends on the device set packer assembles).
    provisioner "powershell" {
        inline = [
            "$cd = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | Where-Object { Test-Path ($_.DeviceID + '\\setup_scripts\\setup.ps1') } | Select-Object -First 1",
            "if (-not $cd) { throw 'provisioning CD not found' }",
            "& ($cd.DeviceID + '\\setup_scripts\\setup.ps1') -Stage 2",
        ]
    }

    # Flush pending file operations (e.g. Defender removal) before sealing
    provisioner "windows-restart" {}
}
