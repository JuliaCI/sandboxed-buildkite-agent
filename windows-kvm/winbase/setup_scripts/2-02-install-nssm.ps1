Write-Output " -> Installing NSSM"
$url = "https://nssm.cc/ci/nssm-2.24-103-gdee49fc.zip"
$installer = Join-Path $env:TEMP 'nssm.zip'

Invoke-WebRequest -Uri $url -OutFile $installer -ErrorAction Stop
Expand-Archive -Path $installer -DestinationPath "$env:TEMP" -Force
Move-Item -Path (Join-Path $env:TEMP 'nssm-2.24-103-gdee49fc\win64\nssm.exe') -Destination "C:\Windows\nssm.exe" -Force -ErrorAction Stop