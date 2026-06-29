Write-Output " -> Installing jq"

$jqUrl = "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe"
Invoke-WebRequest -Uri "$jqUrl" -OutFile "C:\Windows\System32\jq.exe"

