# Disable screensaver
Write-Output " -> Disabling screensaver"
Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name ScreenSaveActive -Value 0 -Type DWORD

# Disable display blanking
& powercfg -x -monitor-timeout-ac 0
& powercfg -x -monitor-timeout-dc 0