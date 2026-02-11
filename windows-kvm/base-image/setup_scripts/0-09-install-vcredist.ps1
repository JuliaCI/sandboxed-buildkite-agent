# The install.ps1 script require NuGet and if it can't be found it will prompt
# the user so we install explicitly so that the build can proceed without user
# input.
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

# Install all the Visual C++ redistributables
iex ((New-Object System.Net.WebClient).DownloadString('https://vcredist.com/install.ps1'))
