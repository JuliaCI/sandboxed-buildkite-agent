$version = "1.21.3"
Write-Output "Installing Telegraf v$version..."
$telegrafUrl = "https://dl.influxdata.com/telegraf/releases/telegraf-${version}_windows_amd64.zip"
$telegrafZip = Join-Path $env:TEMP 'telegraf.zip'
Invoke-WebRequest -Uri $telegrafUrl -OutFile $telegrafZip -ErrorAction Stop

$telegrafInstallDir = Join-Path $env:ProgramFiles 'Telegraf'
Expand-Archive -Path $telegrafZip -DestinationPath "$env:TEMP" -ErrorAction Stop -Force
Move-Item -Path (Join-Path $env:TEMP "telegraf-$version") `
    -Destination $telegrafInstallDir -ErrorAction Stop

# Spit out telegraf's configuration file
((Get-Content -path "$PSScriptRoot\telegraf.conf" -Raw) `
    -replace "{hostname}","$env:buildkiteAgentName" `
) | Out-File -Encoding ASCII -FilePath "$telegrafInstallDir\telegraf.conf" -Force -ErrorAction Stop

# Load telegraf config if we actually have a route using wireguard
$wgKeyFile = "$PSScriptRoot\..\wireguard_keys\${env:sanitized_hostname}.key"
If (Test-Path -Path "$wgKeyFile" ) {
    & "$telegrafInstallDir\telegraf.exe" --service install
    Start-Service telegraf
}
