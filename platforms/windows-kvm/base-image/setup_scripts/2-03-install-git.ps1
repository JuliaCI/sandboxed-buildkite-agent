# Pinned (rather than "latest") for build reproducibility; bump deliberately.
# We were stuck on v2.30.1 for years due to sporadic
#   "fetch-pack: unexpected disconnect while reading sideband packet"
# failures with newer versions; that bug was fixed in v2.47.0(2)
# (https://github.com/git-for-windows/git/issues/5199).  Note that in CI all
# ssh traffic goes through the native Windows OpenSSH anyway (see
# core.sshCommand below and 2-10-upgrade-openssh.ps1), not git's bundled one.
$git_version = "2.54.0"
Write-Output " -> Downloading git v$git_version..."
$dlurl = "https://github.com/git-for-windows/git/releases/download/v$git_version.windows.1/Git-$git_version-64-bit.exe"

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

# Tell git to create real symlinks
& "C:\Program Files\Git\bin\git.exe" config --global core.symlinks "true"

# Tell git to use longpaths (since we enabled it previously)
& "C:\Program Files\Git\bin\git.exe" config --global core.longpaths "true"
& "C:\Program Files\Git\bin\git.exe" config --system core.longpaths "true"

# Enable ssh-agent service, so that it can be started by buildkite plugins
Set-Service -Name ssh-agent -StartupType Manual
