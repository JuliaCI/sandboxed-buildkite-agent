Write-Output " -> Downloading git v2.30.2..."

#$git_release_url="https://api.github.com/repos/git-for-windows/git/releases/latest"
#foreach ($asset in (Invoke-RestMethod $git_release_url).assets) {
#    if ($asset.name -match 'Git-[\d*\.]+-64-bit\.exe') {
#        $dlurl = $asset.browser_download_url
#    }
#}

# We explicitly do NOT take the latest `git`, as it has issues with the
# bundled SSH on windows, in particular we get sporadic failures of
#   "fetch-pack: unexpected disconnect while reading sideband packet"
# To work around this, we roll back to an older version that works for us.
$dlurl = "https://github.com/git-for-windows/git/releases/download/v2.30.1.windows.1/Git-2.30.1-64-bit.exe"

Remove-Item -Force $env:TEMP\git-stable.exe -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri $dlurl -OutFile $env:TEMP\git-stable.exe
Start-Process -Wait $env:TEMP\git-stable.exe -ArgumentList /silent

# Set `PATH` to include `git.exe`
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine) + ";C:\Program Files\Git\bin",
    [EnvironmentVariableTarget]::Machine)

# Tell git to use native windows SSH
& "C:\Program Files\Git\bin\git.exe" config --global core.sshCommand "'C:\Windows\System32\OpenSSH\ssh.exe'"

# Enable ssh-agent service, so that it can be started by buildkite plugins
Set-Service -Name ssh-agent -StartupType Manual