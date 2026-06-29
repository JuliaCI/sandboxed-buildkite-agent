# Install Python (and add itself to PATH)
$version="3.10.2"
Write-Output "-> Installing Python $version"

$url="https://www.python.org/ftp/python/$version/python-$version-amd64.exe"
$installer = Join-Path $env:TEMP "python-$version-amd64.exe"

Invoke-WebRequest -Uri $url -OutFile $installer -ErrorAction Stop
Start-Process -Wait -FilePath "$installer" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0"