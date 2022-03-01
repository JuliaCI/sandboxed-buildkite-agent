Write-Output " -> Formatting Z:"
Get-Disk | Where-Object PartitionStyle -eq "RAW" | `
           Initialize-Disk -PartitionStyle GPT -PassThru | `
           New-Volume -FileSystem NTFS -DriveLetter Z -FriendlyName 'DATA'

# Ensure that Z: gets mounted automatically
Set-StorageSetting -NewDiskPolicy OnlineAll