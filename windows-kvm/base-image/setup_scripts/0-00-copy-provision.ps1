# Copy the provisioning CD (setup scripts + secrets) to the local disk, as the
# very first thing we do.  Anything that runs after a reboot (e.g. the Windows
# Update resume in stage 1) must use this local copy: the virtual CD can
# enumerate late, or under a different drive letter, after a reboot, which
# used to intermittently kill the update/resume chain when the resume command
# pointed at E:\ (see windows-kvm/PLAN.md).
$provisionDir = "C:\provision"
Write-Output " -> Copying provisioning data to $provisionDir"
New-Item -ItemType Directory -Force -Path $provisionDir | Out-Null
foreach ($dir in @("setup_scripts", "secrets")) {
    Copy-Item -Recurse -Force -Path "$PSScriptRoot\..\$dir" -Destination $provisionDir
}
