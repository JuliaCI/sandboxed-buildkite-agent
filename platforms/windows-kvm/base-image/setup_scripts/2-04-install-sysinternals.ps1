# Install Sysinternals
Write-Output " -> Installing Sysinternals suite..."
$url = "https://download.sysinternals.com/files/SysinternalsSuite.zip"
$installer = Join-Path $env:TEMP 'sysinternals.zip'
Invoke-WebRequest -Uri "$url" -OutFile "$installer" -ErrorAction Stop
# Unzip directly into C:\Windows
Expand-Archive -Path $installer -DestinationPath "C:\Windows" -Force