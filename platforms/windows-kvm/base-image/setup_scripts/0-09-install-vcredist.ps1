# Install all the supported Visual C++ redistributables with the VcRedist
# module (https://vcredist.com/), as its install.ps1 does. The module comes
# straight from the PowerShell Gallery's package feed: the in-box
# PowerShellGet 1.0.0.1 can fail to register the gallery on a fresh Server 2025
# ("Unable to find module repositories"), and install.ps1 needs it registered.
$ErrorActionPreference = 'Stop'

$nupkg = Join-Path $env:TEMP 'VcRedist.zip'
$unpacked = Join-Path $env:TEMP 'VcRedist-package'
Invoke-WebRequest -UseBasicParsing 'https://www.powershellgallery.com/api/v2/package/VcRedist' -OutFile $nupkg
Remove-Item -Recurse -Force $unpacked -ErrorAction SilentlyContinue
Expand-Archive -Path $nupkg -DestinationPath $unpacked
$version = (Import-PowerShellDataFile (Join-Path $unpacked 'VcRedist.psd1')).ModuleVersion
Write-Output " -> Installing the VcRedist module v$version"
$moduleDir = "C:\Program Files\WindowsPowerShell\Modules\VcRedist\$version"
New-Item -ItemType Directory -Force -Path $moduleDir | Out-Null
Get-ChildItem $unpacked |
    Where-Object { $_.Name -notin '_rels', 'package', '[Content_Types].xml' -and $_.Extension -ne '.nuspec' } |
    Copy-Item -Destination $moduleDir -Recurse -Force
Import-Module VcRedist -RequiredVersion $version

$downloads = Join-Path $env:TEMP 'VcRedist'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
Write-Output " -> Installing the Visual C++ redistributables"
Get-VcList -Architecture x86, x64 | Save-VcRedist -Path $downloads | Install-VcRedist -Silent |
    Select-Object -Property Name, Release, Architecture, Version -Unique | Format-Table -AutoSize | Out-String -Width 200
