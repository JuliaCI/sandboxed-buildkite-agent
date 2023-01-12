Write-Output " -> Installing jq"

$jqUrl = "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe"
Invoke-WebRequest -Uri "$jqUrl" -OutFile "C:\Windows\System32\jq.exe"

Write-Output " -> Installing cryptic secrets"
New-Item -Path "C:\secrets" -ItemType "directory"

# Only copy the secrets we need
Copy-Item -Path "$PSScriptRoot\..\secrets\agent.key" -Destination "C:\secrets"
Copy-Item -Path "$PSScriptRoot\..\secrets\agent.pub" -Destination "C:\secrets"
Copy-Item -Path "$PSScriptRoot\..\secrets\buildkite-api-token" -Destination "C:\secrets"

# Tell the cryptic environment hook how to find our secrets
[Environment]::SetEnvironmentVariable("BUILDKITE_PLUIGIN_CRYPYTIC_SECRETS_MOUNT_POINT", "C:\secrets", [System.EnvironmentVariableTarget]::Machine)
