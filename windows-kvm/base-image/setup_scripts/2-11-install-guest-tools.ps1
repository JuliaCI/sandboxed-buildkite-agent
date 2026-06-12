# Install the virtio-win guest tools.  The virtio *drivers* are already
# injected during Windows setup (Autounattend), but this adds the QEMU guest
# agent, which the host needs for `virsh domtime --sync` (clock fixup when
# restoring a VM from a saved state) and graceful shutdown/quiesce, plus
# up-to-date driver binaries.
#
# Locate the provisioning CD by content: stage 2 may be running from
# C:\provision (after an update-reboot resume), which only holds
# setup_scripts + secrets, while virtio-win stays on the CD.
Write-Output " -> Installing virtio-win guest tools"
$cd = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' |
    Where-Object { Test-Path ($_.DeviceID + '\virtio-win\virtio-win-guest-tools.exe') } |
    Select-Object -First 1
if (-not $cd) {
    throw "virtio-win-guest-tools.exe not found on any CD drive"
}
$exe = $cd.DeviceID + '\virtio-win\virtio-win-guest-tools.exe'
Start-Process -Wait -FilePath $exe -ArgumentList "/install", "/quiet", "/norestart"

# The guest agent service should now exist; make sure it auto-starts.
Set-Service -Name QEMU-GA -StartupType Automatic -ErrorAction Stop
Start-Service -Name QEMU-GA -ErrorAction SilentlyContinue
