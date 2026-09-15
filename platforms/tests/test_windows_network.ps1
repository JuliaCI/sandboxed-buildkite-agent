# Run with powershell.exe -NoProfile -File platforms/tests/test_windows_network.ps1.
# Extract the launcher functions without running the image installer or agent.
$ErrorActionPreference = 'Stop'
$setupPath = Join-Path $PSScriptRoot '../windows-kvm/buildkite-worker/setup_scripts/0-02-install-buildkite-agent.ps1'
$tokens = $null; $errors = $null
$setup = [System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$launcher = $setup.Find({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('function Wait-GuestNetwork')}, $true).Value
$ast = [System.Management.Automation.Language.Parser]::ParseInput($launcher, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in 'Get-DhcpLease', 'Wait-GuestNetwork') {
    Invoke-Expression $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true).Extent.Text
}

function Get-NetIPAddress { $script:addresses }
foreach ($state in 'Invalid', 'Tentative', 'Duplicate', 'Deprecated') {
    $script:addresses = @([pscustomobject]@{PrefixOrigin='Dhcp'; AddressState=$state; IPAddress='192.168.122.10'})
    if (Get-DhcpLease) { throw "Accepted $state address" }
}
$script:addresses = @(
    [pscustomobject]@{PrefixOrigin='Manual'; AddressState='Preferred'; IPAddress='172.20.0.1'},
    [pscustomobject]@{PrefixOrigin='Dhcp'; AddressState='Preferred'; IPAddress='169.254.1.2'}
)
if (Get-DhcpLease) { throw 'Accepted static or link-local address' }
$lease = [pscustomobject]@{PrefixOrigin='Dhcp'; AddressState='Preferred'; IPAddress='192.168.122.10'; InterfaceAlias='Ethernet'}
$script:addresses += $lease
if ((Get-DhcpLease).IPAddress -ne $lease.IPAddress) { throw 'Rejected usable lease' }
Write-Host 'PASS: only usable DHCP addresses accepted'

# Advance simulated time in the poll sleep; no networking or processes are changed.
function Get-Date { ([datetime]'2026-01-01').AddSeconds($script:seconds) }
function Start-Sleep { param($Seconds) $script:seconds += $Seconds }
function Write-LauncherLog { param($Message) }
function Get-NetworkState { 'test adapters' }
function Write-NetworkDiagnostics { $script:diagnostics++ }
function Resolve-DnsName { if ($script:dnsReady) { 'resolved' } }
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
    if (-not $PassThru) { throw 'Renewal process must be tracked' }
    $script:renews++
    return [pscustomobject]@{HasExited=$script:renewExited}
}
$JobId = 'network-test'
foreach ($scenario in 'ready', 'no-dns', 'no-lease', 'renew-pending') {
    $script:seconds = 0; $script:renews = 0; $script:diagnostics = 0
    $script:dnsReady = $scenario -eq 'ready'
    $script:renewExited = $scenario -ne 'renew-pending'
    $script:addresses = if ($scenario -in 'ready', 'no-dns') { @($lease) } else { @() }
    $failure = $null
    try { Wait-GuestNetwork -TimeoutSeconds 120 -RenewIntervalSeconds 30 } catch { $failure = $_.ToString() }
    if ($scenario -eq 'ready') {
        if ($failure -or $script:seconds -ne 0) { throw "Happy path failed: $failure" }
    } else {
        $stage = if ($scenario -eq 'no-dns') { 'DNS resolution fails' } else { 'no DHCP lease' }
        if ($failure -notlike "*Timed out after 120s*$stage*" -or $script:diagnostics -ne 1) {
            throw "Wrong timeout or missing diagnostics: $failure"
        }
    }
    $expectedRenews = switch ($scenario) { 'no-lease' { 3 }; 'renew-pending' { 1 }; default { 0 } }
    if ($script:renews -ne $expectedRenews) { throw "${scenario}: expected $expectedRenews renewals, got $script:renews" }
    Write-Host "PASS: $scenario"
}
