# Records what the scheduler reports about a worker image (`worker.json`, see
# "Windows image servicing" in platforms/KVM_IMAGES.md): the Windows build and,
# for an evaluation edition, when its evaluation period ends. Prints the JSON
# and writes it to the path given. Works in any guest booted from the image, so
# it can also be run through the guest agent on an older worker; it fails when
# the evaluation licence is not activated, as there is no fixed deadline then.
param([string]$OutFile = "C:\Windows\Temp\worker.json")
$ErrorActionPreference = "Stop"

$version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
# Windows' own licence; other products (Office, ...) have other application IDs.
$license = @(Get-CimInstance SoftwareLicensingProduct -Filter `
    "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL")
if ($license.Count -ne 1) {
    throw "expected one installed Windows licence, found $($license.Count)"
}
$license = $license[0]

# An activated evaluation (TIMEBASED_EVAL) ends at a fixed time, which
# `GracePeriodRemaining` counts down to; `EvaluationEndDate` is not set.
# Every job guest boots this image with the host's time, so they all see that
# same deadline.
$expires = $null
if ($license.Description -like "*TIMEBASED_EVAL*") {
    if ($license.LicenseStatus -ne 1) {
        throw "the evaluation licence is not activated (LicenseStatus $($license.LicenseStatus))"
    }
    $expires = [DateTime]::UtcNow.AddMinutes($license.GracePeriodRemaining).ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

$json = [ordered]@{
    windows_build = "$($version.CurrentBuildNumber).$($version.UBR)"
    edition = $version.EditionID
    license_channel = $license.ProductKeyChannel
    evaluation_expires_at = $expires
} | ConvertTo-Json
Write-Output $json
[IO.File]::WriteAllText($OutFile, $json)
