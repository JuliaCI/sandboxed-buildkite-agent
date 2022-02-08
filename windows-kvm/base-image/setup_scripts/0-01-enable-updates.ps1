# Temporarily stop Windows Update
Stop-Service -Name "wuauserv"

# Record windows updates opt in in the registry
Write-Output " -> Enabling Microsoft Update"
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"
if (-NOT (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force
}
New-ItemProperty -Path $RegPath -Name "EnableFeatuedSoftware" -Value 1 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "IncludeRecommendedUpdates" -Value 1 -PropertyType DWORD -Force

# Enable Microsoft Update for other software as well
(New-Object -ComObject Microsoft.Update.ServiceManager).AddService2("7971f918-a847-4430-9279-4a52d1efe18d",7,"")

# Start up Windows Update again
Start-Service -Name "wuauserv"