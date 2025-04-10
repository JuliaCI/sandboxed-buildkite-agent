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

$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv"
New-ItemProperty -Path $RegPath -Name "Start" -Value 4 -PropertyType DWORD -Force
$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
New-ItemProperty -Path $RegPath -Name "Start" -Value 4 -PropertyType DWORD -Force
