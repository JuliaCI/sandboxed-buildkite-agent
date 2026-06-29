Write-Output " -> Checking qemu-ga guest-exec availability"

$service = Get-CimInstance Win32_Service -Filter "Name='QEMU-GA'"
if ($null -eq $service) {
    throw "QEMU-GA service is not installed"
}

$binPath = $service.PathName.Trim()

# qemu-ga 105 supports an RPC blacklist, not an allow-list. guest-exec is
# available by default in the virtio-win build, so preserve the service command
# line and fail the image build if a future base image explicitly disables it.
$blacklistMatch = [regex]::Match($binPath, '(?i)(?:^|\s)(?:--blacklist=([^"\s]+)|--blacklist\s+([^"\s]+)|-b\s+([^"\s]+))')
if ($blacklistMatch.Success) {
    $blacklist = @($blacklistMatch.Groups[1].Value, $blacklistMatch.Groups[2].Value, $blacklistMatch.Groups[3].Value) |
        Where-Object { $_ -ne "" } |
        Select-Object -First 1
    $disabledRpcs = $blacklist -split ','
    foreach ($requiredRpc in @("guest-ping", "guest-exec", "guest-exec-status")) {
        if ($requiredRpc -in $disabledRpcs) {
            throw "QEMU-GA service disables required RPC '$requiredRpc': $binPath"
        }
    }
}

Set-Service -Name QEMU-GA -StartupType Automatic -ErrorAction Stop
