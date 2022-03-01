# Disable password expiry for julia user
$user = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -Split '\\')[1]
Write-Output " -> Disabling password expiry for user '$user'"
Set-LocalUser -Name "$user" -PasswordNeverExpires 1