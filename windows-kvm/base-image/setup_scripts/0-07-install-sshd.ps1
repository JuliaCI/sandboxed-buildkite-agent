Write-Output "-> Installing sshd"
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Add-WindowsCapability -Online
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'

# Next, setup autoexec.cmd to launch `bash.exe`, but only if we're coming in over SSH, and
# we have a terminal hooked up (e.g. when VSCode logs in and tries to start up its server
# process, we don't want that to happen inside `bash.exe`).
$bashLaunchScript = "C:\autoexec.cmd"
$cmd = @"
@echo off
if defined SSH_CLIENT (
    :: check if we've got a terminal hooked up; if not, don't run bash.exe
    bash.exe -c "if [ -t 1 ]; then exit 1; fi"
    if errorlevel 1 (
        set SSH_CLIENT=
        bash.exe --login
        exit
    )
)
"@
$cmd | Out-File -Encoding ASCII $bashLaunchScript

# Ensure the bash script is executable
$acl = Get-ACL -Path $bashLaunchScript
$newRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrator", "ReadAndExecute", "Allow")
$acl.AddAccessRule($newRule)
Set-Acl -Path $bashLaunchScript -AclObject $acl

# If we manually invoke powershell, it shouldn't go and auto-start bash.exe
$psProfileScript = "C:\Windows\system32\WindowsPowerShell\v1.0\profile.ps1"
$ps = @"
Set-Item -Path env:SSH_CLIENT -Value '' -Force
"@
$ps | Out-File -Encoding ASCII $psProfileScript

# Set `bash` as the default command processor
New-ItemProperty -Path "HKLM:Software\Microsoft\Command Processor" -Name AutoRun -ErrorAction Stop `
                 -Value "$bashLaunchScript" -PropertyType STRING -Force

# Also add `buildkite_rsa.pub` as an authorized key
New-Item -Path "C:\Users\$env:UserName" -Name ".ssh" -ItemType "directory"
$auth_keys = "C:\ProgramData\ssh\administrators_authorized_keys"
Copy-Item -Path "$PSScriptRoot\..\ssh_keys\buildkite_rsa.pub" -Destination "$auth_keys" -Force

$acl = Get-ACL -Path $auth_keys
$acl.SetAccessRuleProtection($True, $True)
Set-Acl -Path $auth_keys -AclObject $acl
$acl = Get-ACL -Path $auth_keys
$ar = New-Object System.Security.AccessControl.FileSystemAccessRule( `
	"NT Authority\Authenticated Users", "ReadAndExecute", "Allow")
$acl.RemoveAccessRule($ar)
$ar = New-Object System.Security.AccessControl.FileSystemAccessRule( `
	"BUILTIN\Administrators", "FullControl", "Allow")
$acl.RemoveAccessRule($ar)
$ar = New-Object System.Security.AccessControl.FileSystemAccessRule( `
	"BUILTIN\Users", "FullControl", "Allow")
$acl.RemoveAccessRule($ar)
Set-Acl -Path $auth_keys -AclObject $acl
