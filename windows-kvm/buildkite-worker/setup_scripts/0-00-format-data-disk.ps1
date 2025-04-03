Write-Output " -> Formatting disk, assigning to C:\cache"

# Format our raw disk as NTFS
$Disk = (Get-Disk | Where-Object PartitionStyle -eq "RAW")
$Disk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Volume -FileSystem NTFS -FriendlyName "CACHE"

# Mount it as C:\cache AND Z:\, since we' need to use both for docker (sigh)
$Partition = Get-Partition -DiskNumber $Disk.Number -PartitionNumber 2
New-Item -ItemType Directory -Path "C:\cache"
$Partition | Add-PartitionAccessPath -AccessPath "C:\cache"
$Partition | Add-PartitionAccessPath -AccessPath "Z:\"

# Ensure that Z: gets mounted automatically
Set-StorageSetting -NewDiskPolicy OnlineAll

# Wait for C:\cache to be ready
$timeout = 30
$elapsed = 0
while (-not (Test-Path "C:\cache") -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 1
    $elapsed++
}

if (-not (Test-Path "C:\cache")) {
    Write-Error "C:\cache did not become available in time"
    exit 1
}
