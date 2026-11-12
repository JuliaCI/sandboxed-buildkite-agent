# Install the QEMU guest agent and the balloon statistics service.
#
# The virtio *drivers* are already injected during Windows setup (Autounattend);
# all we additionally need is the QEMU guest agent (QEMU-GA), which the host
# uses to run jobs, read and write guest files, and request a graceful
# shutdown, and BalloonService (below).
#
# We deliberately do NOT run the full `virtio-win-guest-tools.exe` installer:
# under `/quiet` it re-installs every virtio driver, and that has been observed
# to hang indefinitely with no UI (a refresh on rhea sat silently at a blank
# desktop for ~1h mid driver-install).  Installing just the guest-agent MSI
# touches no drivers, so it can't hang that way -- and we wrap it in an explicit
# timeout as a backstop so a stuck installer can never wedge the build again.
#
# Locate the provisioning CD by content: stage 2 may be running from
# C:\provision (after an update-reboot resume), which only holds the setup
# scripts, while virtio-win stays on the CD.
Write-Output " -> Installing QEMU guest agent (qemu-ga)"
$cd = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' |
    Where-Object { Test-Path ($_.DeviceID + '\virtio-win\guest-agent\qemu-ga-x86_64.msi') } |
    Select-Object -First 1
if (-not $cd) {
    throw "qemu-ga-x86_64.msi not found on any CD drive"
}
$msi = $cd.DeviceID + '\virtio-win\guest-agent\qemu-ga-x86_64.msi'

$proc = Start-Process -FilePath "msiexec.exe" `
    -ArgumentList "/i", "`"$msi`"", "/qn", "/norestart" -PassThru
if (-not $proc.WaitForExit(180000)) {
    try { $proc.Kill() } catch {}
    throw "qemu-ga install timed out after 180s (msiexec still running)"
}
# 0 = success, 3010 = success but a reboot is pending; both are fine here.
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "qemu-ga install failed (msiexec exit code $($proc.ExitCode))"
}

# The guest agent service should now exist; make sure it auto-starts.
Set-Service -Name QEMU-GA -StartupType Automatic -ErrorAction Stop
Start-Service -Name QEMU-GA -ErrorAction SilentlyContinue

# The balloon driver is injected during Windows setup too, but memory statistics
# come from the user-mode BalloonService, which the scheduler reads through
# `virsh domstats --balloon` as the job's memory use. It runs from where it is
# installed, so copy it off the CD first.
Write-Output " -> Installing BalloonService (blnsvr)"
$balloonSrc = $cd.DeviceID + '\virtio-win\Balloon\2k22\amd64'
$balloonDir = 'C:\Program Files\Virtio-Win\Balloon'
New-Item -Path $balloonDir -ItemType Directory -Force | Out-Null
# A refresh runs this again on a base that already has the service running, and
# the running service locks blnsvr.exe.
if (Get-Service -Name BalloonService -ErrorAction SilentlyContinue) {
    Stop-Service -Name BalloonService -Force -ErrorAction Stop
}
Copy-Item -Path "$balloonSrc\blnsvr.exe" -Destination $balloonDir -Force -ErrorAction Stop
$proc = Start-Process -FilePath "$balloonDir\blnsvr.exe" -ArgumentList "-i" -NoNewWindow -PassThru
if (-not $proc.WaitForExit(60000)) {
    try { $proc.Kill() } catch {}
    throw "BalloonService install timed out after 60s"
}
Set-Service -Name BalloonService -StartupType Automatic -ErrorAction Stop
Start-Service -Name BalloonService -ErrorAction SilentlyContinue
