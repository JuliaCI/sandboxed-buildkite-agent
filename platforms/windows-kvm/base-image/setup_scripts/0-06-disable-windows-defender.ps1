# We typically run in a ephemeral regime; resetting to a known-good
# configuration after every run, so let's not bother with malware
# scanning, especially since it can interfere with Pkg.
Write-Output " -> Disabling Windows Defender"
Set-MpPreference -DisableRealtimeMonitoring $true
