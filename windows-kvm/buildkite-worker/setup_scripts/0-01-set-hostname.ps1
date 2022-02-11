Write-Output " -> Setting hostname to ${env:sanitized_hostname}"
Rename-Computer -NewName "${env:sanitized_hostname}" -Force