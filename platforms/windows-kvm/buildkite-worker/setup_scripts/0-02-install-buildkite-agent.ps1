Write-Output " -> Installing buildkite-agent"

# The installer requires a token to render the config; use a non-secret placeholder
# and clear it from the final config below.  The scheduler injects the real token
# at runtime.
$env:buildkiteAgentToken = "placeholder-token"
$env:buildkiteAgentUrl = "https://github.com/buildkite/agent/releases/download/v3.129.0/buildkite-agent-windows-amd64-3.129.0.zip"
iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/buildkite/agent/main/install.ps1'))

# Customize buildkite config
$bk_config="C:\buildkite-agent\buildkite-agent.cfg"
((Get-Content -path "$bk_config" -Raw) `
    -replace '(?m)^[# ]*name=.*$',"name=`"$env:buildkiteAgentName`"" `
    -replace '(?m)^[# ]*token=.*$',"token=`"`"" `
    -replace '(?m)^[# ]*tags=.*$',"tags=`"`"" `
) | Set-Content -Path "$bk_config"

# Use `bash` as the shell, so our plugins work everywhere
Add-Content -Path "$bk_config" -Value "shell=`"bash.exe -c`""

# The scheduler starts one VM for one assigned Buildkite job.  The agent must
# exit after that job so the host can reap the VM and release the cache pool.
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

@'
$ErrorActionPreference = "Stop"

$exitPath = "C:\buildkite-agent\run-buildkite-job.exit"
$logPath = "C:\buildkite-agent\run-buildkite-job.log"
Remove-Item -Path $exitPath -Force -ErrorAction SilentlyContinue

function Write-JobLog {
    param([string]$Message)

    Add-Content -Path $logPath -Value $Message
    try {
        $Message | Out-File -FilePath "\\.\COM1" -Encoding ASCII -Append
    } catch {
    }
}

function Test-CacheVolumeDirty {
    $dirtyOutput = (& fsutil dirty query Z: 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query NTFS dirty bit for Z:: $dirtyOutput"
    }
    return $dirtyOutput -match "is dirty"
}

function Repair-CacheVolumeIfDirty {
    if (-not (Test-CacheVolumeDirty)) {
        return
    }

    Write-JobLog "$(Get-Date -Format o) Cache volume Z: is dirty; running chkdsk before starting Buildkite"
    Stop-Service -Name docker -Force -ErrorAction SilentlyContinue

    $chkdskOutput = (& chkdsk Z: /F /X 2>&1 | Out-String)
    Write-JobLog $chkdskOutput
    if (Test-CacheVolumeDirty) {
        throw "Cache volume Z: remains dirty after chkdsk; refusing to start Buildkite job $env:BUILDKITE_ACQUIRE_JOB_ID"
    }

    Start-Service -Name docker -ErrorAction SilentlyContinue
}

$exitCode = 1
try {
    Write-JobLog "$(Get-Date -Format o) Starting Buildkite job $env:BUILDKITE_ACQUIRE_JOB_ID as $env:BUILDKITE_AGENT_NAME"
    Repair-CacheVolumeIfDirty
    $agentArgs = @(
        "start",
        "--disconnect-after-job",
        "--acquire-job", $env:BUILDKITE_ACQUIRE_JOB_ID,
        "--name", $env:BUILDKITE_AGENT_NAME,
        "--tags", $env:BUILDKITE_AGENT_TAGS,
        "--config", "C:\buildkite-agent\buildkite-agent.cfg"
    )
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & "C:\buildkite-agent\bin\buildkite-agent.exe" @agentArgs 2>&1 | ForEach-Object {
            Write-JobLog $_.ToString()
        }
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($null -ne $LASTEXITCODE) {
        $exitCode = $LASTEXITCODE
    }
    Write-JobLog "$(Get-Date -Format o) Buildkite job $env:BUILDKITE_ACQUIRE_JOB_ID exited with $exitCode"
} catch {
    Write-JobLog ($_ | Out-String)
} finally {
    $exitCode | Set-Content -Path $exitPath -Encoding ASCII
}
exit $exitCode
'@ | Set-Content -Path "C:\buildkite-agent\run-buildkite-job-service.ps1" -Encoding ASCII

$serviceName = "buildkite-agent-acquire-job"
& "C:\Windows\nssm.exe" install $serviceName "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File C:\buildkite-agent\run-buildkite-job-service.ps1"
& "C:\Windows\nssm.exe" set $serviceName AppDirectory "C:\buildkite-agent"
& "C:\Windows\nssm.exe" set $serviceName AppStdout "C:\buildkite-agent\run-buildkite-job-service.log"
& "C:\Windows\nssm.exe" set $serviceName AppStderr "C:\buildkite-agent\run-buildkite-job-service.log"
& "C:\Windows\nssm.exe" set $serviceName ObjectName "$env:UserDomain\$env:UserName" "$env:windows_password"
& "C:\Windows\nssm.exe" set $serviceName AppExit "Default" "Exit"
& "C:\Windows\nssm.exe" set $serviceName Start "SERVICE_DEMAND_START"

@'
param(
    [Parameter(Mandatory = $true)]
    [string]$JobId
)

$ErrorActionPreference = "Stop"

$exitPath = "C:\buildkite-agent\run-buildkite-job.exit"
$launcherLogPath = "C:\buildkite-agent\run-buildkite-job-launcher.log"
Remove-Item -Path $exitPath -Force -ErrorAction SilentlyContinue

try {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $buildkiteDns = Resolve-DnsName "agent-edge.buildkite.com" -ErrorAction SilentlyContinue
        $githubDns = Resolve-DnsName "github.com" -ErrorAction SilentlyContinue
        if ($buildkiteDns -and $githubDns) {
            break
        }
        if ($attempt -eq 30) {
            throw "Timed out waiting for DNS before starting Buildkite job $JobId"
        }
        Start-Sleep -Seconds 2
    }

    $serviceName = "buildkite-agent-acquire-job"
    if (-not $env:BUILDKITE_AGENT_TAGS) {
        throw "BUILDKITE_AGENT_TAGS is not set for Buildkite job $JobId"
    }

    & "C:\Windows\nssm.exe" set $serviceName AppEnvironmentExtra `
        "BUILDKITE_AGENT_TOKEN=$env:BUILDKITE_AGENT_TOKEN" `
        "BUILDKITE_AGENT_NAME=$env:BUILDKITE_AGENT_NAME" `
        "BUILDKITE_ACQUIRE_JOB_ID=$JobId" `
        "BUILDKITE_AGENT_TAGS=$env:BUILDKITE_AGENT_TAGS" `
        "BUILDKITE_PLUGIN_JULIA_CACHE_DIR=C:\cache\julia-buildkite-plugin"

    $lastStartError = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            Start-Service -Name $serviceName
            exit 0
        } catch {
            $lastStartError = $_
            Start-Sleep -Seconds 2
        }
    }
    throw $lastStartError
} catch {
    $_ | Out-String | Set-Content -Path $launcherLogPath -Encoding ASCII
    1 | Set-Content -Path $exitPath -Encoding ASCII
    exit 1
}
'@ | Set-Content -Path "C:\buildkite-agent\run-buildkite-job.ps1" -Encoding ASCII
