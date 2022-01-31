Write-Output " -> Installing buildkite-agent"

# Use a dummy agent token for now; we'll fix this up later in a provisioning script
$env:buildkiteAgentToken = "xxx"
iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/buildkite/agent/main/install.ps1'))

# Create service to auto-start buildkite
& nssm install buildkite-agent "C:\buildkite-agent\bin\buildkite-agent.exe" "start"
& nssm set buildkite-agent AppStdout "C:\buildkite-agent\buildkite-agent.log"
& nssm set buildkite-agent AppStderr "C:\buildkite-agent\buildkite-agent.log"