# If there's tailscale info, use it to connect!
$tsInstallDir = Join-Path $env:ProgramFiles 'Tailscale'
$tsKeyFile = "$PSScriptRoot\..\secrets\tailscale.key"
If (Test-Path -Path "$tsKeyFile" ) {
    $tsLoginServer = Get-Content -Path "$PSScriptRoot\..\secrets\tailscale.server" -ErrorAction Stop
    $tsAuthKey = Get-Content -Path "$tsKeyFile" -ErrorAction Stop
    Write-Output " -> Configuring Tailscale"

    & "$tsInstallDir\tailscale.exe" login --login-server "$tsLoginServer" --auth-key "$tsAuthKey" --hostname "${env:sanitized_hostname}" --timeout "30s" --unattended
}
