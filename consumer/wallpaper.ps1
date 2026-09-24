# Wallpaper Journey subscriber for Windows. The default run downloads the latest
# triptych and puts one panel on each monitor. -Apply only reapplies the newest
# cached triptych, -Watch is the resident process that does that when monitors
# change, -Status prints everything a bug report needs, and -Uninstall removes
# every task and file Wallpaper Journey created.
#
# Targets Windows PowerShell 5.1, which every supported Windows ships with.

param(
  [switch]$Apply,
  [switch]$Watch,
  [switch]$Status,
  [switch]$Uninstall
)

$Version = 2   # bump on any Windows consumer change, and keep consumer/VERSION-windows equal; unversioned scripts count as 1

$Repo = "https://github.com/ianmatson/wallpaper-journey"
$Dir  = "$env:USERPROFILE\WallpaperJourney"   # where images are saved
$LogDir = "$env:LOCALAPPDATA\WallpaperJourney"
$LogFile = "$LogDir\wallpaper.log"
$Keep = 7                                      # days of wallpapers to retain
$Slots = @("left", "middle", "right")
$TaskName = "WallpaperJourney"
$WatcherTaskName = "WallpaperJourneyWatcher"
$LegacyTaskName = "DailyWallpaper"   # registered under the old name before the rename
$MutexName = "Local\WallpaperJourney"
$WatchInterval = 2                   # seconds between the watcher's checks

$TagFile      = "$Dir\current-tag"
$Marker       = "$Dir\.applied"
$TopologyFile = "$Dir\.display-topology"
$NoticeMarker = "$Dir\.update-noticed"   # highest version already announced
# Windows keeps its own transcoded copy of each wallpaper here and sometimes
# reports that copy instead of the file we set, so a path under it proves nothing.
$ThemesDir    = "$env:APPDATA\Microsoft\Windows\Themes"
# Single-image versions set this one file on every monitor.
$LegacyFiles  = @("$Dir\current.jpg", "$Dir\applied.txt", "$Dir\download.tmp")

# ---------------------------------------------------------------------------
# Pure layout and policy. No Windows calls, so tests/windows-consumer.ps1 can
# run these anywhere.

# Same rule as macOS: one monitor gets the middle, two get left + middle so
# the panels flow, three get all three, and more repeat left/middle/right.
function Get-SlotIndex([int]$Count, [int]$Index) {
  if ($Count -eq 1) { return 1 }
  if ($Count -eq 2) { return $Index }
  return $Index % 3
}

function Get-RectKey($Monitor) {
  "{0},{1},{2},{3}" -f $Monitor.Left, $Monitor.Top, $Monitor.Width, $Monitor.Height
}

# Matches the arrangement in Settings → Display. Monitors that duplicate each
# other share one rectangle, so they count once and show the same panel.
function Get-Assignments($Monitors, [string[]]$Paths) {
  $sorted = @($Monitors | Sort-Object Left, Top, Id)
  $rects = @($sorted | ForEach-Object { Get-RectKey $_ } | Select-Object -Unique)
  foreach ($monitor in $sorted) {
    $slot = Get-SlotIndex $rects.Count ([array]::IndexOf($rects, (Get-RectKey $monitor)))
    [pscustomobject]@{
      Id      = $monitor.Id
      Slot    = $Slots[$slot]
      Path    = $Paths[$slot]
      Current = $monitor.Wallpaper
    }
  }
}

# Changes whenever a monitor is added, removed, moved, or resized.
function Get-Fingerprint($Monitors) {
  (@($Monitors | Sort-Object Id | ForEach-Object { "$($_.Id)=$(Get-RectKey $_)" })) -join ";"
}

function Test-UnderDir([string]$Path, [string]$Parent) {
  if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Parent)) { return $false }
  $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-SamePath([string]$A, [string]$B) {
  [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase)
}

# The wallpaper a monitor shows, as evidence of an opt-out: "ours", "unknown"
# (proves nothing either way), or "foreign" (the user chose it).
function Get-WallpaperOwner([string]$Path) {
  if ([string]::IsNullOrEmpty($Path)) { return "unknown" }   # solid colour, or not reported yet
  if (Test-UnderDir $Path $Dir) { return "ours" }
  if (Test-UnderDir $Path $ThemesDir) { return "unknown" }
  return "foreign"
}

# Whether an apply may record a monitor: only when it reads back as our panel,
# or as Windows' transcoded copy of it. Anything else means something else
# (a slideshow, a policy) won, and recording it would read as an opt-out later.
function Test-Recordable([string]$Seen) {
  (Get-WallpaperOwner $Seen) -eq "ours" -or (Test-UnderDir $Seen $ThemesDir)
}

# What the user chose on a monitor we last applied to, or $null. A monitor
# counts as changed when it now reads as neither ours nor what it read right
# after that apply, which catches a solid colour ("") too. Only recorded
# monitors count: one that just appeared shows whatever Windows gave it, which
# is ours to replace, not an opt-out.
function Find-UserWallpaper($Applied, $Monitors) {
  foreach ($monitor in $Monitors) {
    $record = @($Applied | Where-Object { $_.Id -eq $monitor.Id }) | Select-Object -First 1
    if (-not $record) { continue }
    $reading = "$($monitor.Wallpaper)"
    if ((Get-WallpaperOwner $reading) -eq "ours") { continue }
    if (Test-SamePath $reading "$($record.Seen)") { continue }
    if ($reading -eq "") { return "a solid colour" }
    return $reading
  }
  return $null
}

# Whether an apply can leave a monitor alone: it shows its panel already, or it
# reads the same as right after we set this very panel there.
function Test-AlreadyShown($Assignment, $Applied) {
  if (Test-SamePath $Assignment.Current $Assignment.Path) { return $true }
  $record = @($Applied | Where-Object { $_.Id -eq $Assignment.Id }) | Select-Object -First 1
  if (-not $record) { return $false }
  (Test-SamePath $record.Path $Assignment.Path) -and (Test-SamePath $record.Seen $Assignment.Current) -and
    -not [string]::IsNullOrEmpty($Assignment.Current)
}

# Dated tags beyond the newest $Keep. The caller still spares any file a
# monitor points at.
function Get-DoomedTags([string[]]$Tags, [int]$Keep) {
  @($Tags | Sort-Object -Unique -Descending | Select-Object -Skip $Keep)
}

function Get-TagOf([string]$Name) {
  if ($Name -match '^(wall-\d{4}-\d{2}-\d{2})-landscape-(left|middle|right)\.jpg$') { return $Matches[1] }
  return $null
}

function Get-SlotPaths([string]$Tag) {
  @($Slots | ForEach-Object { "$Dir\$Tag-landscape-$_.jpg" })
}

# Dot-sourcing (the tests do) stops here, before anything touches Windows.
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# Windows state.

# IDesktopWallpaper (Windows 8+) is the only public API that sets a different
# image on each monitor. It has no IDispatch, so PowerShell cannot call it
# directly; these static helpers do the calls, each on a fresh instance so a
# restarted Explorer never leaves the watcher holding a dead one. C# 5 only:
# Windows PowerShell compiles this with the .NET Framework compiler.
if (-not ('WallpaperJourney.Desktop' -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WallpaperJourney {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }

  [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IDesktopWallpaper {
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
    uint GetMonitorDevicePathCount();
    [PreserveSig] int GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out Rect displayRect);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
    void SetSlideshow(IntPtr items);
    IntPtr GetSlideshow();
    void SetSlideshowOptions(int options, uint slideshowTick);
    void GetSlideshowOptions(out int options, out uint slideshowTick);
    void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
    int GetStatus();
    void Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
  }

  [ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
  public class DesktopWallpaperClass { }

  public class MonitorInfo {
    public string Id;
    public int Left;
    public int Top;
    public int Width;
    public int Height;
    public string Wallpaper;
  }

  public static class Desktop {
    const int DWPOS_FILL = 4;

    static IDesktopWallpaper Create() {
      return (IDesktopWallpaper)new DesktopWallpaperClass();
    }

    // Attached monitors only: the count includes monitors Windows remembers
    // but has switched off, and those have no rectangle.
    public static MonitorInfo[] Monitors() {
      IDesktopWallpaper w = Create();
      try {
        List<MonitorInfo> list = new List<MonitorInfo>();
        uint count = w.GetMonitorDevicePathCount();
        for (uint i = 0; i < count; i++) {
          string id;
          try { id = w.GetMonitorDevicePathAt(i); } catch (COMException) { continue; }
          if (String.IsNullOrEmpty(id)) continue;
          Rect r;
          if (w.GetMonitorRECT(id, out r) != 0) continue;
          if (r.Right <= r.Left || r.Bottom <= r.Top) continue;
          string path = "";
          try { path = w.GetWallpaper(id) ?? ""; } catch (COMException) { }
          MonitorInfo m = new MonitorInfo();
          m.Id = id;
          m.Left = r.Left;
          m.Top = r.Top;
          m.Width = r.Right - r.Left;
          m.Height = r.Bottom - r.Top;
          m.Wallpaper = path;
          list.Add(m);
        }
        return list.ToArray();
      } finally {
        Marshal.ReleaseComObject(w);
      }
    }

    public static void Set(string monitorID, string path) {
      IDesktopWallpaper w = Create();
      try { w.SetWallpaper(monitorID, path); } finally { Marshal.ReleaseComObject(w); }
    }

    // Fill crops rather than stretches, so portrait monitors get a centre crop
    // of their panel, as macOS "Fill Screen" does. True when it changed.
    public static bool EnsureFill() {
      IDesktopWallpaper w = Create();
      try {
        if (w.GetPosition() == DWPOS_FILL) return false;
        w.SetPosition(DWPOS_FILL);
        return true;
      } finally {
        Marshal.ReleaseComObject(w);
      }
    }
  }
}
"@
}

function Write-Note([string]$Text) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
  Write-Host $line
  try {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    # One previous generation is enough for a bug report.
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
      Move-Item $LogFile "$LogFile.old" -Force
    }
    Add-Content -Path $LogFile -Value $line
  } catch { }
}

function Get-Monitors { , @([WallpaperJourney.Desktop]::Monitors()) }

# Windows 11 keeps a wallpaper per virtual desktop, so switching desktops can
# show one that missed the last apply. $null where Windows has no such key.
function Get-VirtualDesktopId {
  $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
  foreach ($key in @(
      "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops",
      "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\$session\VirtualDesktops")) {
    try {
      $bytes = (Get-ItemProperty $key -Name CurrentVirtualDesktop -ErrorAction Stop).CurrentVirtualDesktop
      if ($bytes) { return [BitConverter]::ToString($bytes) }
    } catch { }
  }
  return $null
}

# Before Explorer is up at logon, or while it restarts, monitors can read as
# blank. Nothing read then is evidence of anything.
function Test-ShellReady {
  $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
  @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }).Count -gt 0
}

function Get-CachedTag {
  if (-not (Test-Path $TagFile)) { return $null }
  $tag = "$(Get-Content $TagFile -Raw)".Trim()
  if ($tag -notlike 'wall-*') { return $null }
  return $tag
}

function Read-Topology {
  if (-not (Test-Path $TopologyFile)) { return $null }
  try { Get-Content $TopologyFile -Raw | ConvertFrom-Json } catch { return $null }
}

# Every mutator queues on one named mutex, so the watcher never applies while
# a poll is downloading or uninstalling. Windows releases it if the holder
# dies, which surfaces as AbandonedMutexException and still grants it.
# Returns whatever the action returns.
function Invoke-Locked([scriptblock]$Action) {
  $mutex = New-Object System.Threading.Mutex($false, $MutexName)
  $held = $false
  try {
    try { $held = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $held = $true }
    & $Action
  } finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

# ---------------------------------------------------------------------------
# Actions.

# Puts the cached triptych on every monitor. Local only: no network. True when
# every monitor shows its panel.
function Invoke-Apply {
  $tag = Get-CachedTag
  if (-not $tag) { Write-Note "no cached release to apply"; return $false }
  $paths = Get-SlotPaths $tag
  foreach ($path in $paths) {
    if (-not (Test-Path $path)) { Write-Note "cached panel missing: $path"; return $false }
  }

  $previous = Read-Topology
  $applied = @()
  if ($previous) { $applied = @($previous.assignments) }
  $desktop = Get-VirtualDesktopId
  $monitors = Get-Monitors
  if ($monitors.Count -eq 0) { Write-Note "Windows reported no monitors"; return $false }

  $assignments = @(Get-Assignments $monitors $paths)
  $changed = 0
  $failed = 0
  foreach ($a in $assignments) {
    if (Test-AlreadyShown $a $applied) { continue }
    try {
      [WallpaperJourney.Desktop]::Set($a.Id, $a.Path)
      $changed++
    } catch {
      $failed++
      Write-Note "setting $($a.Slot) on $($a.Id) failed: $($_.Exception.Message)"
    }
  }
  try {
    if ([WallpaperJourney.Desktop]::EnsureFill()) { $changed++ }
  } catch {
    Write-Note "setting Fill failed: $($_.Exception.Message)"
  }

  # Read every monitor back and record only those that show their panel, since
  # the opt-out check reads any later change on a recorded monitor as the
  # user's choice. One that did not take is retried at the next poll.
  $after = Get-Monitors
  $shown = @()
  foreach ($a in $assignments) {
    $seen = "$(@($after | Where-Object { $_.Id -eq $a.Id } | ForEach-Object { $_.Wallpaper }) | Select-Object -First 1)"
    if (Test-Recordable $seen) {
      $shown += [pscustomobject]@{ Id = $a.Id; Slot = $a.Slot; Path = $a.Path; Seen = $seen }
    } else {
      $failed++
      Write-Note "$($a.Slot) on $($a.Id) did not take: it reads as '$seen'"
    }
  }

  [pscustomobject]@{
    tag         = $tag
    desktop     = $desktop
    fingerprint = Get-Fingerprint $monitors
    assignments = $shown
  } | ConvertTo-Json -Depth 5 | Set-Content -Path $TopologyFile

  if ($changed -gt 0 -or -not (Test-Path $Marker)) {
    Set-Content -Path $Marker -Value (Get-Date -Format o)
  }
  # Nothing points at the single-image files once every monitor has a panel.
  if ($failed -eq 0) {
    foreach ($path in $LegacyFiles) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
  }
  if ($changed -gt 0) {
    Write-Note ("applied {0} to {1} monitor(s): {2}" -f $tag, $assignments.Count,
      (($assignments | ForEach-Object { $_.Slot }) -join ", "))
  }
  return ($failed -eq 0)
}

# The local half of every run: reapply when the monitors or the virtual desktop
# changed since the last apply, otherwise treat a wallpaper the user chose as
# opting out. The order matters, because a monitor that just appeared, or a
# desktop the last apply never reached, shows whatever Windows gave it. True
# when the caller should stop (uninstalled).
function Invoke-LocalCheck {
  $topology = Read-Topology
  if (-not $topology -or -not (Get-CachedTag)) { return $false }
  if (-not (Test-ShellReady)) { return $false }

  $desktop = Get-VirtualDesktopId
  $monitors = Get-Monitors
  $fingerprint = Get-Fingerprint $monitors
  if ($fingerprint -ne $topology.fingerprint -or $desktop -ne $topology.desktop) {
    Invoke-Apply | Out-Null
    return $false
  }
  # A fresh install never reads the pre-existing desktop as an opt-out.
  if (-not (Test-Path $Marker)) { return $false }
  $choice = Find-UserWallpaper @($topology.assignments) $monitors
  if (-not $choice) { return $false }

  # Uninstalling cannot be undone, so the evidence must hold still: same
  # desktop, same monitors, same reading a few seconds later. Anything that
  # moved in between is left for the next check to reconsider.
  Start-Sleep -Seconds 5
  if (-not (Test-ShellReady) -or (Get-VirtualDesktopId) -ne $desktop) { return $false }
  $monitors = Get-Monitors
  if ((Get-Fingerprint $monitors) -ne $fingerprint) { return $false }
  if ((Find-UserWallpaper @($topology.assignments) $monitors) -ne $choice) { return $false }

  Write-Note "manual wallpaper change detected; uninstalling (monitor shows $choice)"
  Show-Notice "You set your own wallpaper, so Wallpaper Journey uninstalled itself and removed its files."
  Invoke-Uninstall
  return $true
}

# Resolves the newest release tag from the /latest redirect without downloading
# the page or any asset. Returns $null when the network is unavailable.
function Get-LatestTag {
  $location = $null
  try {
    $request = [System.Net.HttpWebRequest]::Create("$Repo/releases/latest")
    $request.Method = "HEAD"
    $request.AllowAutoRedirect = $false
    $request.UserAgent = "WallpaperJourney"
    $request.Timeout = 30000
    $response = $request.GetResponse()
    $location = $response.Headers["Location"]
    $response.Close()
  } catch { return $null }

  if (-not $location) { return $null }
  $tag = $location.TrimEnd('/').Split('/')[-1]
  if ($tag -notlike 'wall-*') { return $null }
  return $tag
}

function Test-Jpeg([string]$Path) {
  try {
    $stream = [System.IO.File]::OpenRead($Path)
    try { return ($stream.ReadByte() -eq 0xFF -and $stream.ReadByte() -eq 0xD8) } finally { $stream.Dispose() }
  } catch { return $false }
}

# Caches the complete triptych, so a monitor change can choose any layout
# without downloading again. The tag file moves only once all three exist.
function Save-Triptych([string]$Tag) {
  foreach ($slot in $Slots) {
    $out = "$Dir\$Tag-landscape-$slot.jpg"
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { continue }
    $tmp = "$out.download"
    try {
      # By tag, not /latest: a release published mid-download must not mix days.
      Invoke-WebRequest "$Repo/releases/download/$Tag/landscape-$slot.jpg" -OutFile $tmp `
        -UseBasicParsing -TimeoutSec 60 -UserAgent "WallpaperJourney"
    } catch {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      Write-Note "download failed: landscape-$slot.jpg ($($_.Exception.Message))"
      return $false
    }
    if (-not (Test-Jpeg $tmp)) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      Write-Note "download is not a JPEG: landscape-$slot.jpg"
      return $false
    }
    Move-Item $tmp $out -Force
  }
  Set-Content -Path "$TagFile.tmp" -Value $Tag
  Move-Item "$TagFile.tmp" $TagFile -Force
  return $true
}

function Invoke-Prune {
  $referenced = @((Get-Monitors) | ForEach-Object { $_.Wallpaper })
  $files = @(Get-ChildItem $Dir -Filter "wall-*.jpg" -File -ErrorAction SilentlyContinue)
  $doomed = Get-DoomedTags @($files | ForEach-Object { Get-TagOf $_.Name } | Where-Object { $_ }) $Keep
  foreach ($file in $files) {
    if ($doomed -notcontains (Get-TagOf $file.Name)) { continue }
    if (@($referenced | Where-Object { Test-SamePath $_ $file.FullName }).Count -gt 0) { continue }
    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
  }
}

# The default run, several times a day. A poll with nothing new costs one
# redirect request and downloads no image. False once uninstalled.
function Invoke-Refresh {
  if (Invoke-LocalCheck) { return $false }

  $tag = Get-LatestTag
  if (-not $tag) {
    Write-Note "latest release lookup failed"   # offline or a GitHub hiccup; the next poll retries
    return $true
  }

  if ($tag -eq (Get-CachedTag) -and
      @(Get-SlotPaths $tag | Where-Object { -not (Test-Path $_) }).Count -eq 0) {
    Invoke-Apply | Out-Null   # catches up a monitor that is behind; a no-op otherwise
    return $true
  }

  Write-Note "updating to $tag"
  if (-not (Save-Triptych $tag)) { return $true }
  if (Invoke-Apply) { Invoke-Prune } else { Write-Note "skipping cache pruning after a failed apply" }
  return $true
}

function Show-Notice($Text) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.Visible = $true
    $notify.ShowBalloonTip(10000, "Wallpaper Journey", $Text, 'Info')
    Start-Sleep -Seconds 10
    $notify.Dispose()
  } catch { }
}

# There is deliberately no auto-updater: subscribers run code from this repo
# once, at install, with consent — images are the only thing that flows after
# that, and a repo compromise must not become code running on their machines.
# So updates are announced, never applied: when the repo carries a newer
# Windows consumer version, ask once and let the user rerun the installer.
function Show-UpdateNotice {
  try {
    $remote = (Invoke-WebRequest "https://raw.githubusercontent.com/ianmatson/wallpaper-journey/main/consumer/VERSION-windows" `
      -UseBasicParsing -TimeoutSec 10 -UserAgent "WallpaperJourney").Content
  } catch { return }
  $remote = "$remote".Trim()
  if ($remote -notmatch '^\d+$' -or [int]$remote -le $Version) { return }

  $noticed = 0
  if (Test-Path $NoticeMarker) {
    $text = "$(Get-Content $NoticeMarker -Raw)".Trim()
    if ($text -match '^\d+$') { $noticed = [int]$text }
  }
  if ([int]$remote -le $noticed) { return }

  Write-Note "consumer version $remote is available (this is $Version); announcing it"
  # Written before the prompt so a version is announced at most once, whatever
  # happens to the prompt.
  Set-Content -Path $NoticeMarker -Value $remote

  # Dismisses itself after 60 seconds; 6 is Yes, 4 is Yes/No, 64 the info icon.
  try {
    $choice = (New-Object -ComObject WScript.Shell).Popup(
      "A new Wallpaper Journey version is available. Open the README to see how to update?",
      60, "Wallpaper Journey", 4 + 64)
    if ($choice -eq 6) { Start-Process "$Repo#updating--windows" }
  } catch { }
}

function Invoke-Uninstall {
  # Delete only files Wallpaper Journey created, in case $Dir is a shared
  # folder, and do it before unregistering: removing the task that runs this
  # process can terminate it.
  $ours = @($TagFile, "$TagFile.tmp", $Marker, $TopologyFile, $NoticeMarker,
            "$Dir\install.ps1", "$Dir\wallpaper.ps1", "$Dir\wallpaper.ps1.download", $LogFile, "$LogFile.old") + $LegacyFiles
  foreach ($path in $ours) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
  Get-ChildItem $Dir -Filter "wall-*-landscape-*" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
  foreach ($folder in @($Dir, $LogDir)) {
    try {
      if (-not (Get-ChildItem $folder -Force -ErrorAction Stop)) {
        Remove-Item $folder -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }

  # The task running this process goes last.
  if ($Watch) {
    $order = @($LegacyTaskName, $TaskName, $WatcherTaskName)
  } else {
    Stop-ScheduledTask -TaskName $WatcherTaskName -ErrorAction SilentlyContinue
    $order = @($WatcherTaskName, $LegacyTaskName, $TaskName)
  }
  foreach ($name in $order) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  }
}

# Resident from logon. Checking every two seconds is how macOS notices a
# monitor change or an opt-out within seconds too; each check is local and
# makes no network request.
function Invoke-Watch {
  Write-Note "watcher started (version $Version)"
  while ($true) {
    Start-Sleep -Seconds $WatchInterval
    if (-not (Test-Path "$Dir\wallpaper.ps1")) { return }   # uninstalled elsewhere
    try {
      $topology = Read-Topology
      if ($topology -and (Get-Fingerprint (Get-Monitors)) -ne $topology.fingerprint) {
        # Let a monitor that is still coming up settle before choosing a layout.
        do {
          $before = Get-Fingerprint (Get-Monitors)
          Start-Sleep -Seconds $WatchInterval
        } while ($before -ne (Get-Fingerprint (Get-Monitors)))
        Write-Note "monitors changed; reapplying the cached triptych"
      }
      if (Invoke-Locked { Invoke-LocalCheck }) { return }
    } catch {
      Write-Note "watcher check failed: $($_.Exception.Message)"
    }
  }
}

function Show-Status {
  "Wallpaper Journey Windows consumer version $Version"
  foreach ($name in @($TaskName, $WatcherTaskName)) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) { "${name}: $($task.State)" } else { "${name}: not registered" }
  }
  $tag = Get-CachedTag
  if ($tag) { "cached release: $tag" } else { "cached release: none" }
  if (Test-Path $Marker) { "last applied: $((Get-Item $Marker).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" } else { "last applied: never" }
  if (Test-Path $TopologyFile) { "last applied topology: $((Get-Content $TopologyFile -Raw) -replace '\s+', ' ')" } else { "last applied topology: none" }
  "virtual desktop: $(Get-VirtualDesktopId)"
  "monitors now:"
  foreach ($m in ((Get-Monitors) | Sort-Object Left, Top)) {
    "  $($m.Id) at $(Get-RectKey $m): $($m.Wallpaper) ($(Get-WallpaperOwner $m.Wallpaper))"
  }
  "log: $LogFile"
  if (Test-Path $LogFile) { Get-Content $LogFile -Tail 15 | ForEach-Object { "  $_" } }
}

# ---------------------------------------------------------------------------

$ProgressPreference = "SilentlyContinue"   # Windows PowerShell's progress bar slows downloads badly
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if ($Status) { Show-Status; exit 0 }

if ($Uninstall) {
  Write-Host "Removing Wallpaper Journey's scheduled tasks, script, images, logs, and state."
  Invoke-Locked { Invoke-Uninstall }
  exit 0
}

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

if ($Watch) { Invoke-Watch; exit 0 }

if ($Apply) {
  if (Invoke-Locked { Invoke-Apply }) { exit 0 } else { exit 1 }
}

# Outside the lock: the update prompt can wait a minute for an answer.
if (Invoke-Locked { Invoke-Refresh }) { Show-UpdateNotice }
