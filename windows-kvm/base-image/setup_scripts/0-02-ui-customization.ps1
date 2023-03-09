# Helper function to avoid having to create root keys all the time
function RegMkPath()
{
    Param($Path)
    if (-NOT (Test-Path $Path)) {
        New-Item -Path $Path -Force
    }
    return $Path
}

# Show file extensions, show "Run" in the start menu, and show administrative tools
Write-Output " -> Setting Explorer Preferences"
$RegPath = RegMkPath -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
New-ItemProperty -Path $RegPath -Name "HideFileExt" -Value 0 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "Start_ShowRun" -Value 1 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "StartMenuAdminTools" -Value 1 -PropertyType DWORD -Force

# Enable quickedit mode in the terminal
Write-Output " -> Setting Console Preferences"
$RegPath = RegMkPath -Path "HKCU:\Console"
New-ItemProperty -Path $RegPath -Name "QuickEdit" -Value 1 -PropertyType DWORD -Force

# Disable hibernation and set the file size to zero
Write-Output " -> Setting Power Preferences"
$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power"
New-ItemProperty -Path $RegPath -Name "HibernateFileSizePercent" -Value 0 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "HibernateEnabled" -Value 0 -PropertyType DWORD -Force

# Disable "network discovery"
Write-Output " -> Disabling Network Discovery"
netsh advfirewall firewall set rule group="Network Discovery" new enable=No
$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Network"
New-ItemProperty -Path $RegPath -Name "NewNetworkWindowOff" -Value 1 -PropertyType DWORD -Force
$RegPath = RegMkPath -Path "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Network\NwCategoryWizard\"
New-ItemProperty -Path $RegPath -Name "Show" -Value 0 -PropertyType DWORD -Force

# Allow ACPI shutdown without logging in
Write-Output " -> Enabling ACPI shutdown"
$RegPath = RegMkPath -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
New-ItemProperty -Path $RegPath -Name "shutdownwithoutlogon" -Value 1 -PropertyType DWORD -Force

# For server core, we don't want SConfig launching by default
Write-Output " -> Disabling SConfig"
Set-SConfig -AutoLaunch $false

# Enable Long Paths
Write-Output " -> Enabling long paths"
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force

# Set timezone to UTC
Set-TimeZone -Id "UTC"
