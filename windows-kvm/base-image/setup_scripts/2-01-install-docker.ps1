Write-Output " -> Installing Docker"

# First, install NuGet, so that we aren't prompted to install it when we install the Docker provider
Install-PackageProvider -Name NuGet -Force

# Next, install the docker provider
Install-Module -Name DockerMsftProvider -Repository PSGallery -Force

# Next, install Docker (will require a restart, but that's fine, we're going to do that anyway)
Install-Package -Name docker -ProviderName DockerMsftProvider -Force