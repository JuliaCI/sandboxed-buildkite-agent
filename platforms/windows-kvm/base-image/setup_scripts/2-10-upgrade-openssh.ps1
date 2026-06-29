# The in-box Windows OpenSSH capability lags far behind upstream, and recent
# servicing builds of it even advertise post-quantum kex algorithms they do
# not implement, making `ssh-keyscan github.com` (which the buildkite agent
# runs to populate known_hosts) fail with:
#   choose_kex: unsupported KEX method sntrup761x25519-sha512@openssh.com
# Replace it with the latest Win32-OpenSSH release, which negotiates GitHub's
# post-quantum kex properly.
$version = "10.0.0.0"
$tag = "10.0.0.0p2-Preview"
Write-Output " -> Upgrading OpenSSH to v$version"

$msi = Join-Path $env:TEMP "OpenSSH-Win64-v$version.msi"
Invoke-WebRequest -Uri "https://github.com/PowerShell/Win32-OpenSSH/releases/download/$tag/OpenSSH-Win64-v$version.msi" -OutFile $msi -ErrorAction Stop

# Remove the in-box capability first.  NOTE: this deletes both the
# C:\Windows\System32\OpenSSH binaries and the sshd firewall rule; both are
# restored below.
Stop-Service sshd -Force -ErrorAction SilentlyContinue
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH*' | Remove-WindowsCapability -Online

# Install the MSI; this registers the `sshd` and `ssh-agent` services running
# the binaries in C:\Program Files\OpenSSH.
Start-Process msiexec.exe -Wait -ArgumentList "/i", "`"$msi`"", "/qn"

# Several consumers hardcode the in-box binary location: our git config sets
# core.sshCommand to C:\Windows\System32\OpenSSH\ssh.exe, and the ssh-agent
# buildkite plugin invokes ssh-agent/ssh-add from the same directory.  Mirror
# the new binaries there so all of those keep working.
New-Item -ItemType Directory -Force -Path "C:\Windows\System32\OpenSSH" | Out-Null
Copy-Item "C:\Program Files\OpenSSH\*" -Destination "C:\Windows\System32\OpenSSH\" -Recurse -Force

# The new sshd refuses to use host keys with the (more permissive) ACLs that
# the in-box sshd created them with, failing connections after TCP accept
# without even sending an SSH banner.  Tighten to SYSTEM+Administrators.
Get-ChildItem "C:\ProgramData\ssh\ssh_host_*_key" -ErrorAction SilentlyContinue | ForEach-Object {
    icacls $_.FullName /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F"
}

# Restore the firewall rule that was removed along with the capability.
New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH SSH Server (sshd)" `
    -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -ErrorAction Continue

# sshd runs at boot (remote debugging access); ssh-agent is started on demand
# (e.g. by the ssh-agent buildkite plugin).
Set-Service sshd -StartupType Automatic
Set-Service ssh-agent -StartupType Manual
Start-Service sshd
