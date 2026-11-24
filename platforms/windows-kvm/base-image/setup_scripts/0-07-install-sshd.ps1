# OpenSSH client and server are installed by default since Server 2025, with
# sshd disabled. This makes sshd available while the build runs; 2-10 replaces
# the in-box OpenSSH with the Win32-OpenSSH release.
Write-Output "-> Enabling sshd"
Set-Service -Name sshd -StartupType 'Automatic'
Start-Service sshd
# Open port 22 on every network profile; the in-box rule may be disabled or
# limited to some profiles.
if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH SSH Server (sshd)' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
}

# Next, setup autoexec.cmd to launch `bash.exe`, but only if we're coming in over SSH, and
# we have a terminal hooked up (e.g. when VSCode logs in and tries to start up its server
# process, we don't want that to happen inside `bash.exe`).
$bashLaunchScript = "C:\autoexec.cmd"
$cmd = @"
@echo off
if not defined SSH_CLIENT goto :eof
:: bash.exe only exists once git is installed (stage 2); until then (e.g. when
:: ssh-ing into a VM that is still provisioning) just give a plain cmd shell.
where bash.exe >nul 2>&1
if errorlevel 1 goto :eof
:: check if we've got a terminal hooked up; if not, don't run bash.exe
bash.exe -c "if [ -t 1 ]; then exit 1; fi"
if errorlevel 1 (
    set SSH_CLIENT=
    bash.exe --login
    exit
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
