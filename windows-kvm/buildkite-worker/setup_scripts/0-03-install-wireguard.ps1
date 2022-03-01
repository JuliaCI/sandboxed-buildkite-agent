Write-Output " -> Installing WireGuard"

$wgUrl = "https://download.wireguard.com/windows-client/wireguard-installer.exe"
$wgInstallFile = Join-Path $env:TEMP "wireguard-installer.exe"
$wgInstallDir = Join-Path $env:ProgramFiles 'WireGuard'
Invoke-WebRequest -Uri "$wgUrl" -OutFile "$wgInstallFile" -ErrorAction Stop
Start-Process -Wait -FilePath "$wgInstallFile" -ArgumentList "/quiet"

# If there is a key that matches our hostname, use it to start up a wireguard tunnel!
$wgKeyFile = "$PSScriptRoot\..\wireguard_keys\${env:sanitized_hostname}.key"
If (Test-Path -Path "$wgKeyFile" ) {
    $wgAddress = Get-Content -Path "$PSScriptRoot\..\wireguard_keys\${env:sanitized_hostname}.address" -ErrorAction Stop
    $wgKey = Get-Content -Path "$wgKeyFile" -ErrorAction Stop
    Write-Output "Installing WireGuard tunnel config"

    $WireguardConfDir = "C:\Program Files\WireGuard\Data\"
    #New-Item -Path $WireguardConfDir -ItemType "directory"
    ((Get-Content -path "$PSScriptRoot\wg0.conf" -Raw) `
        -replace "{wgAddress}","$wgAddress" `
        -replace "{wgKey}","$wgKey" `
    ) | Out-File -Encoding ASCII -FilePath "$WireguardConfDir\wg0.conf" -Force -ErrorAction Stop

    & "$wgInstallDir\wireguard.exe" /installtunnelservice "$WireguardConfDir\wg0.conf"
    & "$wgInstallDir\wireguard.exe" /uninstallmanagerservice
}