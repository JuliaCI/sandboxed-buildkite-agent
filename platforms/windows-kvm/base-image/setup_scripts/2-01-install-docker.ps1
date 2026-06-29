Write-Output " -> Installing Docker"

# First, install NuGet, so that we aren't prompted to install it when we install the Docker provider
#Install-PackageProvider -Name NuGet -Force

# Next, install the docker provider
#Install-Module -Name DockerMsftProvider -Repository PSGallery -Force

# Next, install Docker (will require a restart, but that's fine, we're going to do that anyway)
#Install-Package -Name docker -ProviderName DockerMsftProvider -Force

Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1" -o install-docker-ce.ps1
.\install-docker-ce.ps1 -NoRestart
