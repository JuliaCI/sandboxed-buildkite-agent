# If we are configured with no queues, skip buildkite-agent setup
if ($env:buildkiteAgentQueues -eq $null) {
    Write-Output " -> Skipping buildkite-agent installation..."
    return
}

Write-Output " -> Installing buildkite-agent"

# Note that our `secrets.ps1` file is supposed to set `$env:buildkiteAgentToken` first
iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/buildkite/agent/main/install.ps1'))

# Create service to auto-start buildkite
& nssm install buildkite-agent "C:\buildkite-agent\bin\buildkite-agent.exe" "start" "--disconnect-after-job"
& nssm set buildkite-agent AppStdout "C:\buildkite-agent\buildkite-agent.log"
& nssm set buildkite-agent AppStderr "C:\buildkite-agent\buildkite-agent.log"
& nssm set buildkite-agent ObjectName "$env:UserDomain\$env:UserName" "$env:windows_password"

# Customize buildkite config
$bk_config="C:\buildkite-agent\buildkite-agent.cfg"
((Get-Content -path "$bk_config" -Raw) `
    -replace '(?m)^[# ]*name=.*$',"name=`"$env:buildkiteAgentName`"" `
) | Set-Content -Path "$bk_config"

Add-Content -Path "$bk_config" -Value "shell=`"bash.exe -c`""

# Fetch git tags as well
Add-Content -Path "$bk_config" -Value "git-fetch-flags=`"-v --prune --tags`""

# Set environment variables to point some important buildkite agent storage to Z:
New-Item -Path "Z:\" -Name "cache" -ItemType "directory"
[Environment]::SetEnvironmentVariable("BUILDKITE_PLUGIN_JULIA_CACHE_DIR", "Z:\cache", [System.EnvironmentVariableTarget]::Machine)

# Install all of our hooks
New-Item -Path "C:\buildkite-agent\hooks" -ItemType "directory"
Copy-Item -Path "$PSScriptRoot\..\hooks\*" -Destination "C:\buildkite-agent\hooks" -Recurse
