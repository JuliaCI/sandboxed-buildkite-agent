$version = "1.27.4"
Write-Output "Installing Telegraf v$version..."
$telegrafUrl = "https://dl.influxdata.com/telegraf/releases/telegraf-${version}_windows_amd64.zip"
$telegrafZip = Join-Path $env:TEMP 'telegraf.zip'
Invoke-WebRequest -Uri $telegrafUrl -OutFile $telegrafZip -ErrorAction Stop

$telegrafInstallDir = Join-Path $env:ProgramFiles 'Telegraf'
Expand-Archive -Path $telegrafZip -DestinationPath "$env:TEMP" -ErrorAction Stop -Force
Move-Item -Path (Join-Path $env:TEMP "telegraf-$version") `
    -Destination $telegrafInstallDir -ErrorAction Stop
