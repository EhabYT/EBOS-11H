$ErrorActionPreference = 'SilentlyContinue'
try { Unregister-ScheduledTask -TaskName 'EBOSDefenderRestartNotice' -Confirm:$false } catch {}
try { & schtasks.exe /Delete /TN EBOSDefenderRestartNotice /F 2>$null | Out-Null } catch {}
& shutdown.exe /r /t 20 /c "Your PC will restart once more in 20 seconds to complete the final cleanup. Enjoy your new lightweight Windows."
