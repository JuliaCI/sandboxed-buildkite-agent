# We don't want our downstream images to be installing windows updates, EVER.
# So we set the Windows Update server to localhost, which breaks it nicely.

# Helper function to avoid having to create root keys all the time
function RegMkPath()
{
    Param($Path)
    if (-NOT (Test-Path $Path)) {
        New-Item -Path $Path -Force
    }
    return $Path
}

Write-Output " -> Disabling Windows Update..."
$RegPath = RegMkPath -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
New-ItemProperty -Path $RegPath -Name "WUServer" -Value "http://127.0.0.1" -PropertyType STRING -Force
New-ItemProperty -Path $RegPath -Name "WUStatusServer" -Value "http://127.0.0.1" -PropertyType STRING -Force

$RegPath = RegMkPath -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-ItemProperty -Path $RegPath -Name "UseWUServer" -Value 1 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "NoAutoUpdate" -Value 1 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "AUOptions" -Value 1 -PropertyType DWORD -Force

$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv"
New-ItemProperty -Path $RegPath -Name "Start" -Value 4 -PropertyType DWORD -Force
$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
New-ItemProperty -Path $RegPath -Name "Start" -Value 4 -PropertyType DWORD -Force

$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"
Set-ItemProperty -Path $RegPath -Name "SearchOrderConfig" -Value 0 -PropertyType DWORD -Force

# Disable Windows Update Services
$services = @(
    "wuauserv",        # Windows Update
    "bits",            # Background Intelligent Transfer Service
    "dosvc",           # Delivery Optimization
    "WaaSMedicSvc",    # Windows Update Medic Service
    "UsoSvc",          # Update Orchestrator Service
    "sedsvc"           # (Sometimes present on older systems)
)

foreach ($service in $services) {
    Write-Host "Disabling service: $service"
    Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
    Set-Service -Name $service -StartupType Disabled
}

# Disable all Windows Update-related scheduled tasks
Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsUpdate\'  | Disable-ScheduledTask
Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\'  | Disable-ScheduledTask


# In addition to the changes above we also execute the script from
# https://github.com/Aetherinox/pause-windows-updates. The changes above are not
# sufficient but in combination with this script we see no restarts. (It is
# unclear whether this script alone would do the trick, but let's not touch
# something that works...).
$RegFilePath = Join-Path -Path $PSScriptRoot -ChildPath "windows-updates-pause.reg"
Start-Process -FilePath "regedit.exe" -ArgumentList "/s", "`"$RegFilePath`"" -Wait -Verb RunAs
