# Spit out telegraf's configuration file
$telegrafInstallDir = Join-Path $env:ProgramFiles 'Telegraf'
$telegrafConfFile = "$PSScriptRoot\..\telegraf.conf"
If (Test-Path -Path "$telegrafConfFile" ) {
    ((Get-Content -path "$PSScriptRoot\telegraf.conf" -Raw) `
        -replace "{hostname}","$env:buildkiteAgentName" `
    ) | Out-File -Encoding ASCII -FilePath "$telegrafInstallDir\telegraf.conf" -Force -ErrorAction Stop
}

# Load telegraf config if we actually have a route using wireguard
#$wgKeyFile = "$PSScriptRoot\..\wireguard_keys\${env:sanitized_hostname}.key"
#If (Test-Path -Path "$wgKeyFile" ) {
#    & "$telegrafInstallDir\telegraf.exe" --service install
#    Start-Service telegraf
#}
