$wdkVersion = "1.16.1"
Write-Output "Installing w64devkit v${wdkVersion}..."
$wdkUrl = "https://github.com/skeeto/w64devkit/releases/download/v${wdkVersion}/w64devkit-${wdkVersion}.zip"
$wdkZip = Join-Path $env:TEMP "wdk.zip"
Invoke-WebRequest -Uri $wdkUrl -OutFile $wdkZip -ErrorAction Stop

$wdkInstallDir = Join-Path $env:ProgramFiles "w64devkit"
Expand-Archive -Path $wdkZip -DestinationPath "$env:TEMP" -ErrorAction Stop -Force
Move-Item -Path (Join-Path $env:TEMP "w64devkit") `
    -Destination $wdkInstallDir -ErrorAction Stop

# Add the bin directory to the PATH:
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine) + ";C:\Program Files\w64devkit\bin",
    [EnvironmentVariableTarget]::Machine)
