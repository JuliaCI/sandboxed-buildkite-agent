# In addition to the changes above we also execute the script from
# https://github.com/Aetherinox/pause-windows-updates. The changes above are not
# sufficient but in combination with this script we see no restarts. (It is
# unclear whether this script alone would do the trick, but let's not touch
# something that works...).
$RegFilePath = Join-Path -Path $PSScriptRoot -ChildPath "windows-updates-pause.reg"
Start-Process -FilePath "regedit.exe" -ArgumentList "/s", "`"$RegFilePath`"" -Wait -Verb RunAs
