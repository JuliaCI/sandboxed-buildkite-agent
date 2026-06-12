# Tailscale is only used for remote debugging access, and only if a preauth
# key is provided in `secrets/`.  Without one it would just sit unauthenticated
# (nagging on the console with its GUI), so don't even install it.
$tsKeyFile = "$PSScriptRoot\..\secrets\tailscale.key"
If (-NOT (Test-Path -Path "$tsKeyFile")) {
    Write-Output " -> Skipping Tailscale installation (no secrets/tailscale.key)"
    return
}

Write-Output " -> Installing Tailscale"

$tsUrl = "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe"
$tsInstallFile = Join-Path $env:TEMP "tailscale-setup-latest.exe"
Invoke-WebRequest -Uri "$tsUrl" -OutFile "$tsInstallFile" -ErrorAction Stop
Start-Process -Wait -FilePath "$tsInstallFile" -ArgumentList "/silent"

# Set `PATH` to include `tailscale.exe`
$tsInstallDir = Join-Path $env:ProgramFiles 'Tailscale'
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine) + ";" + $tsInstallDir,
    [EnvironmentVariableTarget]::Machine)
