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
