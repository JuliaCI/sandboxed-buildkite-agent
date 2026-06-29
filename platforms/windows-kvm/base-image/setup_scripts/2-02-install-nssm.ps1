Write-Output " -> Installing NSSM"
$url = "https://nssm.cc/ci/nssm-2.24-103-gdee49fc.zip"
$installer = Join-Path $env:TEMP 'nssm.zip'

# nssm.cc is regularly flaky; retry the download a few times
$attempts = 0
while ($true) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $installer -ErrorAction Stop
        break
    } catch {
        if (++$attempts -ge 5) { throw }
        Write-Output "  download failed, retrying ($attempts/5)..."
        Start-Sleep 10
    }
}
Expand-Archive -Path $installer -DestinationPath "$env:TEMP" -Force
Move-Item -Path (Join-Path $env:TEMP 'nssm-2.24-103-gdee49fc\win64\nssm.exe') -Destination "C:\Windows\nssm.exe" -Force -ErrorAction Stop