# Run with powershell.exe or pwsh -NoProfile -File platforms/tests/test_windows_cache.ps1.
# Uses real Git repositories and mocked Windows storage commands; no disks are touched.
$ErrorActionPreference = 'Stop'
$setupPath = Join-Path $PSScriptRoot '../windows-kvm/buildkite-worker/setup_scripts/0-02-install-buildkite-agent.ps1'
$tokens = $null; $errors = $null
$setup = [System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Extract the generated service without running the image installer.
$service = $setup.Find({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('function Repair-GitMirrors')}, $true).Value
$ast = [System.Management.Automation.Language.Parser]::ParseInput($service, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$repair = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Repair-GitMirrors'}, $true).Extent.Text
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$testMirrorsRoot = Join-Path $testRoot 'repos'
$testGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
New-Item -ItemType Directory $testMirrorsRoot | Out-Null
function Write-JobLog { param($Message) Write-Host $Message }
# Substitute only the fixture paths; execute the production recovery function.
$repair = $repair.Replace('"C:\cache\repos"', '$script:testMirrorsRoot').Replace('"C:\Program Files\Git\bin\git.exe"', '$script:testGit')
Invoke-Expression $repair
try {
    foreach ($name in @('healthy', 'zero-head', 'zero-refs', 'missing-origin', 'empty')) {
        $repo = Join-Path $testMirrorsRoot $name
        & $testGit init --bare --quiet $repo
        & $testGit --git-dir $repo config remote.origin.url https://example.invalid/repo
    }
    [IO.File]::WriteAllBytes((Join-Path $testMirrorsRoot 'zero-head/HEAD'), [byte[]]::new(23))
    [IO.File]::WriteAllBytes((Join-Path $testMirrorsRoot 'zero-refs/packed-refs'), [byte[]]::new(100))
    & $testGit --git-dir (Join-Path $testMirrorsRoot 'missing-origin') config --unset remote.origin.url
    New-Item -ItemType Directory (Join-Path $testMirrorsRoot 'partial-clone') | Out-Null
    foreach ($name in @('zero-head.clonelockf', 'healthy.clonelockf')) {
        New-Item -ItemType File (Join-Path $testMirrorsRoot $name) | Out-Null
    }
    Repair-GitMirrors
    $remaining = @(Get-ChildItem $testMirrorsRoot | Sort-Object Name | ForEach-Object Name)
    if (($remaining -join ',') -ne 'empty,healthy,healthy.clonelockf') { throw "Unexpected survivors: $remaining" }
    Write-Host 'PASS: healthy/empty mirrors retained; NUL HEAD, NUL refs, missing origin and partial clone removed; unrelated lock retained'

    $detach = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Detach-CacheVolume'}, $true)
    $assignment = $detach.Find({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script'}, $true)
    Invoke-Expression $assignment.Extent.Text
    [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ($errors | Out-String) }
    $mockPrelude = @'
function Stop-Service { 'stop-docker' }
function Import-Module { }
function Write-VolumeCache { 'flush' }
function mountvol.exe {
    "mountvol $args"
    $global:LASTEXITCODE = 0
    if ($env:FAIL_MOUNTVOL -eq $args[1]) { $global:LASTEXITCODE = 1 }
}
'@
    $child = Join-Path $testRoot 'detach.ps1'
    Set-Content $child ($mockPrelude + "`n" + $script)
    $pwsh = (Get-Process -Id $PID).Path
    foreach ($failure in @('', '/D', '/P')) {
        $env:FAIL_MOUNTVOL = $failure
        $output = (& $pwsh -NoProfile -File $child | Out-String)
        $code = $LASTEXITCODE
        if ($failure -eq '') {
            if ($code -ne 0 -or $output -notmatch '(?s)stop-docker.*flush.*mountvol C:\\cache /D.*mountvol Z:\\ /P.*Detached cache volume') { throw "Bad detach sequence: $output" }
        } else {
            if ($code -ne 1 -or $output -match 'Detached cache volume') { throw "Failure ignored: $output" }
            if ($failure -eq '/D' -and $output -match 'mountvol Z:') { throw "Continued after /D failure: $output" }
        }
    }
    Write-Host 'PASS: generated child parses; Docker/flush/unmount order and native-command failure propagation'
} finally {
    Remove-Item $testRoot -Recurse -Force
    Remove-Item Env:FAIL_MOUNTVOL -ErrorAction SilentlyContinue
}
