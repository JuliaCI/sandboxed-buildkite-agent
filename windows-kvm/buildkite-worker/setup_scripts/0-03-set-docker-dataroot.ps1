Write-Output " -> Setting Docker dataroot to Z:\docker-data"
Stop-Service docker

# Delete the old data-root
Remove-Item -Recurse -Force "C:\ProgramData\Docker"
New-Item -Path "C:\ProgramData\Docker" -ItemType Directory
New-Item -Path "C:\ProgramData\Docker\config" -ItemType Directory

# NOTE: we can't use `C:\\cache` here because of [0], so we instead
# bind-mount our cache directory to two separate locations.  The first
# location, Z:\, is to work around [0], and the second location,
# C:\cache, is so that when we do transparent mounts for our builds,
# we can mount C:\cache -> C:\cache inside the container (which doesn't
# have a Z:\).
# [0] https://github.com/docker/for-win/issues/8110
@"
{
    "data-root": "Z:\\docker-data"
}
"@ | Out-File -Encoding ASCII -FilePath "C:\ProgramData\Docker\config\daemon.json" -Force -ErrorAction Stop

# Allow docker to restart
Start-Service docker
