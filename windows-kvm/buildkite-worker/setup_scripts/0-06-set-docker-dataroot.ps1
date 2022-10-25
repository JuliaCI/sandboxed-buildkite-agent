Write-Output " -> Setting Docker dataroot to Z:\docker-data"
Stop-Service docker

# Delete the old data-root
Remove-Item -Recurse -Force "C:\ProgramData\Docker"
New-Item -Path "C:\ProgramData\Docker" -ItemType Directory
New-Item -Path "C:\ProgramData\Docker\config" -ItemType Directory

# Set the data-root for docker's daemon
@"
{
    "data-root": "Z:\\docker-data"
}
"@ | Out-File -Encoding ASCII -FilePath "C:\ProgramData\Docker\config\daemon.json" -Force -ErrorAction Stop

# Allow docker to restart
Start-Service docker
