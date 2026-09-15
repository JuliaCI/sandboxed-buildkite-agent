variable "output_root" {
    type = string
    default = "images"
}

variable "qmp_socket_path" {
    type = string
    default = ""
}

variable "username" {
    type = string
    default = "julia"
}

variable "password" {
    type = string
    sensitive = true
}

# Default admin password and default user/password
local "windows_credentials" {
    expression = {
        "administrator_password": "${var.password}",
        # Username/password for the account we'll be using
        "username": "${var.username}",
        "password": "${var.password}",
    }
    sensitive = true
}

source "qemu" "windows_server_2022" {
    # Make sure this is accelerated by KVM
    accelerator       = "kvm"

    # Build on the SAME machine type the scheduler runs the VM under (q35;
    # see buildkite-worker/kvm_machine.xml.template), with the NIC at the same
    # PCI location: behind a PCIe root port at slot 2, where QEMU exposes it as
    # a *modern* virtio device (DEV_1041). A NIC plugged straight into the root
    # bus (Packer's default, also on q35) is *transitional* (DEV_1000) at a
    # different path. Windows binds NIC drivers per device instance, so an
    # image built with a different NIC boots at run time with a brand-new,
    # uninstalled adapter: at best it gets installed on every boot, delaying
    # DHCP by several seconds; at worst (i440fx-built images) the install fails
    # with PnP Problem Code 31 and the agent never starts.
    machine_type      = "q35"

    # Use WinRM as the communicator
    communicator      = "winrm"
    winrm_username    = "Administrator"
    winrm_password    = local.windows_credentials.administrator_password
    # WinRM is deliberately disabled until the very last setup script, so this
    # timeout covers the entire unattended install *and* the in-build Windows
    # Update pass, which alone can take an hour or more (the eval ISO is the
    # 2021 RTM build, so every rebuild installs the latest cumulative update).
    winrm_timeout     = "240m"

    # Use official 2022 ISO download from https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022
    iso_checksum      = "sha256:3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325"
    iso_urls          = [
        "https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
    ]

    # Include our setup scripts as another CD (E:/)
    cd_files          = [
        "setup_scripts",
        "virtio-win",
    ]

    # The Makefile selects the output generation.
    output_directory  = var.output_root

    # Hardware parameters.  Normally, we'd have at least 8 cores and 24GB
    # of RAM, but since we're just installing Windows, we'll only use 2 cores
    # and 8GB of RAM, which should be plenty.
    cpus              = 2
    memory            = 8196
    disk_size         = "100G"
    qmp_socket_path   = var.qmp_socket_path
    headless          = true

    # No VNC password: it only binds to localhost anyway, and a passwordless
    # connection allows screenshotting the build (e.g. with `vncdotool`) to
    # debug interactive prompts during provisioning.  (Apple VNC clients
    # refuse passwordless connections; re-enable this if you need one.)
    vnc_use_password  = false

    # Forward the guest's SSH port (sshd is installed by stage 0, long before
    # WinRM is enabled at the very end) so that a hung build can be inspected
    # with `ssh -p 22922 Administrator@127.0.0.1` from the build host instead
    # of typing into the VNC console.  Overriding -netdev replaces packer's
    # default one, so the WinRM forward must be replicated here; overriding
    # -device replaces packer's NIC with one at the run-time PCI location.
    qemuargs          = [
        ["-netdev", "user,id=user.0,hostfwd=tcp:127.0.0.1:{{ .SSHHostPort }}-:5985,hostfwd=tcp:127.0.0.1:22922-:22"],
        ["-device", "pcie-root-port,port=16,chassis=1,id=pci.1,bus=pcie.0,multifunction=on,addr=0x2"],
        ["-device", "virtio-net-pci,netdev=user.0,bus=pci.1,addr=0x0"],
    ]

    # Once we're done provisioning, use this to shut down the VM
    shutdown_command  = "shutdown /s /t 1 /f /d p:4:1 /c \"Packer Shutdown\""
}

build {
    # One build that has the full GUI
    source "qemu.windows_server_2022" {
        vm_name = "base.qcow2"
        cd_content = {
            "Autounattend.xml" = templatefile("Autounattend.xml.template", {
                "windows_credentials": local.windows_credentials,
                "windows_image_name": "Windows Server 2022 SERVERSTANDARD",
            }),
        }
    }

    # One build that is a "core" build, without the full windows GUI
    #source "qemu.windows_server_2022" {
    #    vm_name = "windows_server_2022_core.qcow2"
    #    cd_content = {
    #        "Autounattend.xml" = templatefile("Autounattend.xml.template", {
    #            "windows_credentials": local.windows_credentials,
    #            "windows_image_name": "Windows Server 2022 SERVERSTANDARDCORE",
    #        }),
    #    }
    #}
}
