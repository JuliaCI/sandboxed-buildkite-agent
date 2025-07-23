Write-Output " -> Installing cryptic secrets"
New-Item -Path "C:\secrets" -ItemType "directory"

# Only copy the secrets we need
Copy-Item -Path "$PSScriptRoot\..\secrets\agent.key" -Destination "C:\secrets"
Copy-Item -Path "$PSScriptRoot\..\secrets\agent.pub" -Destination "C:\secrets"
Copy-Item -Path "$PSScriptRoot\..\secrets\buildkite-api-token" -Destination "C:\secrets"

# Tell the cryptic environment hook how to find our secrets
[Environment]::SetEnvironmentVariable("BUILDKITE_PLUGIN_CRYPTIC_SECRETS_MOUNT_POINT", "C:\secrets", [System.EnvironmentVariableTarget]::Machine)
