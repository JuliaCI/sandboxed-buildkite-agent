# Boot- and runtime-tuning for ephemeral CI use: these VMs cold-boot for
# every job, so anything that runs at boot or churns in the background is
# pure overhead.  Patterned after actions/runner-images Configure-System.ps1
# and bento/rgl packer-windows cleanup scripts.

# Remove Windows Defender outright (Server SKUs allow this; 0-06 only
# disabled it).  MsMpEng otherwise scans every file our jobs touch and is the
# single biggest first-boot/first-job slowdown.  Takes effect after the next
# reboot (the worker-image build always ends with one).
Write-Output " -> Removing Windows Defender"
Uninstall-WindowsFeature -Name Windows-Defender -ErrorAction SilentlyContinue

# Keep WER, but never let a crash dialog block an unattended job
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"
New-ItemProperty -Path $RegPath -Name "DontShowUI" -Value 1 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "ForceQueue" -Value 1 -PropertyType DWORD -Force

Write-Output " -> Disabling background churn services"
$services = @(
    "DiagTrack",          # telemetry
    "dmwappushservice",   # WAP push telemetry
    "PcaSvc",             # program compatibility assistant
    "SysMain",            # superfetch; useless for one-shot VMs
    "DPS",                # diagnostic policy service
    "MapsBroker",         # offline maps
    "WpnService"          # push notifications
)
foreach ($service in $services) {
    Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
    Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
}
New-ItemProperty -Path (New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Force).PSPath `
                 -Name "AllowTelemetry" -Value 0 -PropertyType DWORD -Force

Write-Output " -> Disabling automatic maintenance + churn scheduled tasks"
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"
if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
New-ItemProperty -Path $RegPath -Name "MaintenanceDisabled" -Value 1 -PropertyType DWORD -Force
$taskpaths = @(
    "\Microsoft\Windows\Defrag\",
    "\Microsoft\Windows\Application Experience\",
    "\Microsoft\Windows\Customer Experience Improvement Program\",
    "\Microsoft\Windows\Chkdsk\",
    "\Microsoft\Windows\Windows Error Reporting\",
    "\Microsoft\Windows\Maintenance\"
)
foreach ($tp in $taskpaths) {
    Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
}

# Fixed-size pagefile: avoids per-boot pagefile re-creation and runtime grow
# stalls (do NOT run pageless: linkers ask for large commit).
Write-Output " -> Fixing pagefile at 8GiB"
Set-CimInstance -Query "SELECT * FROM Win32_ComputerSystem" -Property @{AutomaticManagedPagefile=$false}
$pf = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
if ($pf) {
    $pf | Set-CimInstance -Property @{InitialSize=8192; MaximumSize=8192}
} else {
    New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name="C:\pagefile.sys"; InitialSize=8192; MaximumSize=8192}
}

Write-Output " -> Power tuning"
powercfg /hibernate off
powercfg /setactive SCHEME_MIN  # High Performance

Write-Output " -> Skipping boot menu"
bcdedit /set "{default}" bootmenupolicy Standard | Out-Null
bcdedit /timeout 0 | Out-Null

# Pre-compile queued .NET assemblies now so mscorsvw doesn't burn CPU on
# every fresh worker boot, then disable the NGEN tasks.
Write-Output " -> Draining ngen queues (this can take a while)"
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\ngen.exe" executeQueuedItems /silent
& "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\ngen.exe" executeQueuedItems /silent
Get-ScheduledTask -TaskPath "\Microsoft\Windows\.NET Framework\" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
