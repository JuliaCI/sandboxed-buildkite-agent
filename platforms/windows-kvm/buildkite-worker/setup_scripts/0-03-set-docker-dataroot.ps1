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

# Harden dockerd startup against slow cache-drive I/O at boot.
#
# Docker's data-root now lives on Z:\docker-data (the persistent cache disk).
# On a slow/fragmented cache image, dockerd's first start can take a long time
# to scan/recover that data-root, or be killed outright.  Two stock defaults
# turn that transient slowness into a hard, whole-VM-lifetime outage of the
# docker_engine pipe:
#
#   1. The SCM kills any service that doesn't report RUNNING within
#      ServicesPipeTimeout (default 30s).  Reading a large, fragmented
#      data-root can exceed that.  Raise it so a slow-but-progressing dockerd
#      is given time instead of being killed.  (Global knob; harmless on these
#      single-purpose VMs.  Takes effect on the next boot -- the worker image
#      build ends in a reboot and every job cold-boots.)
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "ServicesPipeTimeout" -Value 120000 -Type DWord

#   2. The service's recovery policy gives up after only two 15s restarts.
#      If dockerd loses the boot race twice it then stays stopped for the rest
#      of the VM's life.  Make it keep retrying (and reset the failure count
#      once it has been healthy for a minute).
& sc.exe failure docker reset= 60 actions= restart/5000/restart/10000/restart/15000
