$version = "1.8.5"
$majmin = $version.Substring(0, $version.lastIndexOf('.'))
Write-Output "Installing Julia v$version..."
$juliaUrl = "https://julialang-s3.julialang.org/bin/winnt/x64/${majmin}/julia-${version}-win64.zip"
$juliaZip = Join-Path $env:TEMP "julia-${version}.zip"
Invoke-WebRequest -Uri $juliaUrl -OutFile $juliaZip -ErrorAction Stop

$juliaInstallDir = Join-Path $env:ProgramFiles "Julia-${version}"
Expand-Archive -Path $juliaZip -DestinationPath "$env:TEMP" -ErrorAction Stop -Force
Move-Item -Path (Join-Path $env:TEMP "julia-${version}") `
    -Destination $juliaInstallDir -ErrorAction Stop

# Add Julia to the PATH:
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine) + ";C:\Program Files\Julia-${version}\bin",
    [EnvironmentVariableTarget]::Machine)
