# Receive an explicit stage so that we can reboot and resume a new stage
param([Int32]$stage=0)

# Save all output to packer_setup.log
Start-Transcript -Append -Path "$env:LOCALAPPDATA\packer_setup.log"

while ($true) {
    Write-Output "Setup Stage $stage initiating"
    $stage_scripts = Get-ChildItem $PSScriptRoot -Filter ${stage}-*-*.ps1

    # If we've run off the end of the scripts, don't continue running
    if( $stage_scripts.count -le 0 ) {
        break;
    }

    # Run each script
    $stage_scripts | ForEach-Object {
        Write-Output "Running ${_}"
        & $_.FullName
    }

    $stage = $stage + 1
}