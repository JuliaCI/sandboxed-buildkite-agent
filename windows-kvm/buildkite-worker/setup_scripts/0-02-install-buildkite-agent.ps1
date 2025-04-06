# If we are configured with no queues, skip buildkite-agent setup
if ($env:buildkiteAgentQueues -eq $null) {
    Write-Output " -> Skipping buildkite-agent installation..."
    return
}

Write-Output " -> Installing buildkite-agent"

# Note that our `secrets.ps1` file is supposed to set `$env:buildkiteAgentToken` first
$env:buildkiteAgentUrl = "https://github.com/buildkite/agent/releases/download/v3.82.1/buildkite-agent-windows-amd64-3.82.1.zip"
iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/buildkite/agent/main/install.ps1'))

# Create service to auto-start buildkite
& nssm install buildkite-agent "C:\Windows\System32\cmd.exe" "/C C:\buildkite-agent\bin\buildkite-agent.exe start"
& nssm set buildkite-agent AppStdout "C:\buildkite-agent\buildkite-agent.log"
& nssm set buildkite-agent AppStderr "C:\buildkite-agent\buildkite-agent.log"
& nssm set buildkite-agent ObjectName "$env:UserDomain\$env:UserName" "$env:windows_password"
& nssm set buildkite-agent AppExit "Default" "Exit"
& nssm set buildkite-agent AppRestartDelay "10000"

# Tell `nssm` to restart the computer after the service exits
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\buildkite-agent\Parameters\AppEvents\Exit"
New-Item -Path $regPath -Force
New-ItemProperty -Path $regPath -Name "Post" -PropertyType ExpandString -Value "shutdown /s /t 0 /f /d p:4:1" -Force


# Customize buildkite config
$bk_config="C:\buildkite-agent\buildkite-agent.cfg"
((Get-Content -path "$bk_config" -Raw) `
    -replace '(?m)^[# ]*name=.*$',"name=`"$env:buildkiteAgentName`"" `
) | Set-Content -Path "$bk_config"

# Use `bash` as the shell, so our plugins work everywhere
Add-Content -Path "$bk_config" -Value "shell=`"bash.exe -c`""

# Disconnect after a job, and after being idle for an hour (to prevent issues from e.g. losing the network adapter)
Add-Content -Path "$bk_config" -Value "disconnect-after-job=true"
Add-Content -Path "$bk_config" -Value "disconnect-after-idle-timeout=3600"

# Fetch git tags as well
Add-Content -Path "$bk_config" -Value "git-fetch-flags=`"-v --prune --tags`""
Add-Content -Path "$bk_config" -Value "git-clone-flags=`"-v --dissociate`""

# Enable some experimental features
Add-Content -Path "$bk_config" -Value "experiment=`"resolve-commit-after-checkout`""

# Set environment variables to point some important buildkite agent storage to our cache directory
[Environment]::SetEnvironmentVariable("BUILDKITE_PLUGIN_JULIA_CACHE_DIR", "C:\cache\julia-buildkite-plugin", [System.EnvironmentVariableTarget]::Machine)
Add-Content -Path "$bk_config" -Value "git-mirrors-path=`"C:\cache\repos`""

# Install all of our hooks
New-Item -Path "C:\buildkite-agent\hooks" -ItemType "directory"
Copy-Item -Path "$PSScriptRoot\..\hooks\*" -Destination "C:\buildkite-agent\hooks" -Recurse
