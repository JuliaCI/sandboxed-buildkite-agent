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
        "../../../agent/secrets",
    ]

    # Spit this out into `images`
    output_directory  = "images"

    # Hardware parameters.  Normally, we'd have at least 8 cores and 24GB
    # of RAM, but since we're just installing Windows, we'll only use 2 cores
    # and 8GB of RAM, which should be plenty.
    cpus              = 2
    memory            = 8196
    disk_size         = "100G"
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
    # default one, so the WinRM forward must be replicated here.
    qemuargs          = [
        ["-netdev", "user,id=user.0,hostfwd=tcp:127.0.0.1:{{ .SSHHostPort }}-:5985,hostfwd=tcp:127.0.0.1:22922-:22"],
        ["-device", "virtio-net,netdev=user.0"],
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
