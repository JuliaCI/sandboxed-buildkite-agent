# julia-buildkite's jobs use the AWS CLI with Buildkite OIDC credentials, e.g. test jobs
# fetch the Test Analytics token from SSM. Same version as the Linux rootfs images.
$version = "2.35.5"
Write-Output "-> Installing AWS CLI $version"

$url = "https://awscli.amazonaws.com/AWSCLIV2-$version.msi"
$msi = Join-Path $env:TEMP "AWSCLIV2-$version.msi"
Invoke-WebRequest -Uri $url -OutFile $msi -ErrorAction Stop

# The MSI is served without a published checksum; require Amazon's Authenticode signature.
$sig = Get-AuthenticodeSignature -FilePath $msi
if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notmatch "O=Amazon") {
    throw "AWS CLI installer signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
}

$proc = Start-Process -Wait -PassThru -FilePath "msiexec.exe" -ArgumentList "/i `"$msi`" /qn /norestart"
if ($proc.ExitCode -ne 0) {
    throw "AWS CLI installer failed with exit code $($proc.ExitCode)"
}

# The MSI adds its directory to the machine PATH, which this session doesn't see yet.
$aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $aws)) {
    throw "AWS CLI not found at $aws after install"
}
& $aws --version
