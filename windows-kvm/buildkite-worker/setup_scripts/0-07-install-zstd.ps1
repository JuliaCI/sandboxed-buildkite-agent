$version = "1.5.2"
Write-Output "Installing zstd v$version..."
$zstdUrl = "https://github.com/facebook/zstd/releases/download/v${version}/zstd-v${version}-win64.zip"
$zstdZip = Join-Path $env:TEMP 'zstd.zip'
Invoke-WebRequest -Uri $telegrafUrl -OutFile $telegrafZip -ErrorAction Stop

Expand-Archive -Path $zstdZip -DestinationPath "$env:TEMP" -ErrorAction Stop -Force
Move-Item -Path (Join-Path $env:TEMP "zstd-v${version}-win64/zstd.exe") `
    -Destination "C:\Windows\System32\zstd.exe" -ErrorAction Stop

