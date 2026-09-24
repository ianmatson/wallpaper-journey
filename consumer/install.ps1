# Installs or updates the Wallpaper Journey Windows subscriber. No admin rights
# needed. Meant to run as `irm <url> | iex`, so it never calls exit (that would
# close the user's shell) and keeps its variables inside the script block.

& {
  $ErrorActionPreference = "Stop"
  $ProgressPreference = "SilentlyContinue"
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $Base = "https://raw.githubusercontent.com/ianmatson/wallpaper-journey/main/consumer"
  $Dir = "$env:USERPROFILE\WallpaperJourney"
  $Script = "$Dir\wallpaper.ps1"
  $TaskName = "WallpaperJourney"
  $WatcherTaskName = "WallpaperJourneyWatcher"

  New-Item -ItemType Directory -Force -Path $Dir | Out-Null

  # Download first, replace the script last: a failure anywhere in between
  # leaves the previous installation as it was.
  $tmp = "$Script.download"
  Invoke-WebRequest "$Base/wallpaper.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 60

  # A headless console host, because -WindowStyle Hidden hides the window only
  # after it opens, and Windows Terminal can keep it open for the watcher's
  # whole session.
  function New-Action([string]$Extra) {
    New-ScheduledTaskAction -Execute "conhost.exe" `
      -Argument "--headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" $Extra"
  }

  # Several polls a day, so a release published after the usual window still
  # arrives the same day. A poll with nothing new downloads no image. Logon
  # covers machines that were switched off for every scheduled time.
  $triggers = @(4, 8, 12, 16, 20 | ForEach-Object {
    New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($_))
  })
  $triggers += New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

  # StartWhenAvailable runs a poll that was missed while the machine was asleep.
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable

  # The watcher stays up from logon until logoff: no time limit, one instance,
  # and a restart if it ever dies.
  $watcherSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

  # Drop the task registered under the old name, or upgrades would leave two
  # polling. It is usually missing, which is not an error here.
  try { Unregister-ScheduledTask -TaskName "DailyWallpaper" -Confirm:$false -ErrorAction Stop } catch { }

  try {
    Register-ScheduledTask -TaskName $TaskName -Action (New-Action "") -Trigger $triggers `
      -Settings $settings -Description "Downloads the daily Wallpaper Journey triptych and sets one panel per monitor." `
      -Force | Out-Null
    Register-ScheduledTask -TaskName $WatcherTaskName -Action (New-Action "-Watch") `
      -Trigger (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME") -Settings $watcherSettings `
      -Description "Reapplies the cached Wallpaper Journey triptych when monitors change." `
      -Force | Out-Null
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    # Single-image versions registered a logon trigger for every user, which
    # needs admin rights, so an old task may be one this shell cannot replace.
    throw "Could not register the scheduled tasks ($($_.Exception.Message)). If you installed an earlier version from an administrator PowerShell, run this command once from one too."
  }

  Move-Item $tmp $Script -Force
  # Left behind by the manual installation of single-image versions.
  Remove-Item "$Dir\install.ps1" -Force -ErrorAction SilentlyContinue

  # Restart the watcher so the new script is the one running. It is missing on
  # a first install, which is not an error here.
  try { Stop-ScheduledTask -TaskName $WatcherTaskName -ErrorAction Stop } catch { }
  # The watcher ignores a start while an instance still runs, so wait for the
  # old one to go.
  foreach ($i in 1..20) {
    if ((Get-ScheduledTask -TaskName $WatcherTaskName).State -ne "Running") { break }
    Start-Sleep -Milliseconds 500
  }

  Start-ScheduledTask -TaskName $TaskName
  Start-ScheduledTask -TaskName $WatcherTaskName

  Write-Host "Wallpaper Journey is installed. Today's triptych is downloading now."
}
