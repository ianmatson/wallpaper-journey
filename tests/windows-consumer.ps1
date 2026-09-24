# Checks the Windows consumer's layout and opt-out policy. Runs anywhere
# PowerShell does (pwsh on macOS included), because it loads only the pure
# functions: dot-sourcing wallpaper.ps1 stops before anything touches Windows.
#
#   pwsh -NoProfile -File tests/windows-consumer.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$failures = 0

function Check([string]$Name, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { return }
  $script:failures++
  Write-Host "FAIL ${Name}: expected '$Expected', got '$Actual'"
}

# Every file must parse under the PowerShell grammar before anything else.
foreach ($file in @("consumer/wallpaper.ps1", "consumer/install.ps1")) {
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$null, [ref]$errors) | Out-Null
  foreach ($e in $errors) {
    $failures++
    Write-Host "FAIL parse ${file}:$($e.Extent.StartLineNumber): $($e.Message)"
  }
}

. (Join-Path $root "consumer/wallpaper.ps1")
$Dir = "C:\Users\me\WallpaperJourney"
$ThemesDir = "C:\Users\me\AppData\Roaming\Microsoft\Windows\Themes"

function Monitor([string]$Id, [int]$Left, [int]$Top, [int]$Width = 1920, [int]$Height = 1080, [string]$Wallpaper = "") {
  [pscustomobject]@{ Id = $Id; Left = $Left; Top = $Top; Width = $Width; Height = $Height; Wallpaper = $Wallpaper }
}

function Layout($Monitors) {
  (@(Get-Assignments $Monitors (Get-SlotPaths "wall-2026-09-23")) | ForEach-Object { "$($_.Id):$($_.Slot)" }) -join " "
}

# Slots follow the left-to-right arrangement, whatever order Windows lists
# monitors in, including monitors left of the primary at negative X.
Check "one monitor" (Layout @(Monitor "A" 0 0)) "A:middle"
Check "two monitors" (Layout @((Monitor "B" 1920 0), (Monitor "A" 0 0))) "A:left B:middle"
Check "three monitors" (Layout @((Monitor "C" 1920 0), (Monitor "A" -1512 0), (Monitor "B" 0 0))) "A:left B:middle C:right"
Check "portrait on the right" (Layout @((Monitor "A" 0 0), (Monitor "B" 1920 -99 1080 1920), (Monitor "C" -1920 0))) "C:left A:middle B:right"
Check "four repeat" (Layout @((Monitor "A" 0 0), (Monitor "B" 1920 0), (Monitor "C" 3840 0), (Monitor "D" 5760 0))) "A:left B:middle C:right D:left"
Check "stacked monitors sort by top" (Layout @((Monitor "B" 0 1080), (Monitor "A" 0 0))) "A:left B:middle"
# Duplicated monitors share a rectangle: count once, show the same panel.
Check "duplicates" (Layout @((Monitor "A" 0 0), (Monitor "A2" 0 0), (Monitor "B" 1920 0))) "A:left A2:left B:middle"
Check "only duplicates" (Layout @((Monitor "A" 0 0), (Monitor "A2" 0 0))) "A:middle A2:middle"

$paths = Get-SlotPaths "wall-2026-09-23"
Check "slot paths" ($paths -join "|") "$Dir\wall-2026-09-23-landscape-left.jpg|$Dir\wall-2026-09-23-landscape-middle.jpg|$Dir\wall-2026-09-23-landscape-right.jpg"

# The fingerprint moves with the layout, not with the wallpaper shown.
$before = Get-Fingerprint @((Monitor "A" 0 0 -Wallpaper "x"), (Monitor "B" 1920 0))
Check "fingerprint ignores wallpaper" (Get-Fingerprint @((Monitor "B" 1920 0), (Monitor "A" 0 0 -Wallpaper "y"))) $before
Check "fingerprint sees a move" ((Get-Fingerprint @((Monitor "A" 0 0), (Monitor "B" -1920 0))) -eq $before) "False"
Check "fingerprint sees a new monitor" ((Get-Fingerprint @((Monitor "A" 0 0), (Monitor "B" 1920 0), (Monitor "C" 3840 0))) -eq $before) "False"

# Opt-out evidence.
Check "ours" (Get-WallpaperOwner "$Dir\wall-2026-09-23-landscape-left.jpg") "ours"
Check "ours, other case" (Get-WallpaperOwner "c:\users\ME\wallpaperjourney\current.jpg") "ours"
Check "empty" (Get-WallpaperOwner "") "unknown"
Check "transcoded copy" (Get-WallpaperOwner "$ThemesDir\TranscodedWallpaper") "unknown"
Check "sibling folder is not ours" (Get-WallpaperOwner "C:\Users\me\WallpaperJourneyOld\a.jpg") "foreign"
Check "user's photo" (Get-WallpaperOwner "C:\Users\me\Pictures\cat.jpg") "foreign"

$left = "$Dir\wall-2026-09-23-landscape-left.jpg"
$middle = "$Dir\wall-2026-09-23-landscape-middle.jpg"
$transcoded = "$ThemesDir\TranscodedWallpaper"
$applied = @(
  [pscustomobject]@{ Id = "A"; Path = $left; Seen = $left },
  [pscustomobject]@{ Id = "B"; Path = $middle; Seen = $transcoded })
function Readings([string]$A, [string]$B) { @((Monitor "A" 0 0 -Wallpaper $A), (Monitor "B" 1920 0 -Wallpaper $B)) }

Check "all as applied" (Find-UserWallpaper $applied (Readings $left $transcoded)) ""
Check "older panel of ours" (Find-UserWallpaper $applied (Readings "$Dir\wall-2026-09-22-landscape-left.jpg" $middle)) ""
Check "user's photo" (Find-UserWallpaper $applied (Readings $left "C:\cat.jpg")) "C:\cat.jpg"
Check "solid colour" (Find-UserWallpaper $applied (Readings "" $transcoded)) "a solid colour"
# Windows transcodes the user's photo too, but that reads as a change only on a
# monitor that read as our own path after the apply.
Check "transcoded after ours" (Find-UserWallpaper $applied (Readings $transcoded $transcoded)) $transcoded
# A monitor that was not in the last apply shows whatever Windows gave it.
Check "new monitor is not an opt-out" (Find-UserWallpaper $applied @((Monitor "A" 0 0 -Wallpaper $left), (Monitor "C" 1920 0 -Wallpaper "C:\Windows\Web\img0.jpg"))) ""
Check "nothing recorded" (Find-UserWallpaper @() (Readings "C:\cat.jpg" "")) ""

# An apply records a monitor only when it reads back as ours.
Check "record ours" (Test-Recordable $left) "True"
Check "record transcoded" (Test-Recordable $transcoded) "True"
Check "slideshow won" (Test-Recordable "C:\Users\me\Pictures\slide.jpg") "False"
Check "blank after set" (Test-Recordable "") "False"

function Assignment([string]$Id, [string]$Path, [string]$Current) { [pscustomobject]@{ Id = $Id; Path = $Path; Current = $Current } }
Check "shown" (Test-AlreadyShown (Assignment "A" $left $left) $applied) "True"
Check "shown as transcoded" (Test-AlreadyShown (Assignment "B" $middle $transcoded) $applied) "True"
Check "new day" (Test-AlreadyShown (Assignment "B" "$Dir\wall-2026-09-24-landscape-middle.jpg" $transcoded) $applied) "False"
Check "new monitor" (Test-AlreadyShown (Assignment "C" $left "C:\Windows\Web\img0.jpg") $applied) "False"
Check "blank" (Test-AlreadyShown (Assignment "A" $left "") $applied) "False"

# Retention keeps the newest seven dated triptychs.
Check "tag of a panel" (Get-TagOf "wall-2026-09-23-landscape-right.jpg") "wall-2026-09-23"
Check "not a panel" (Get-TagOf "current.jpg") ""
Check "not a panel either" (Get-TagOf "wall-2026-09-23-landscape-right.jpg.download") ""
$tags = @(1..10 | ForEach-Object { "wall-2026-09-{0:D2}" -f $_ }) + @("wall-2026-09-10")
Check "doomed" ((Get-DoomedTags $tags 7) -join " ") "wall-2026-09-03 wall-2026-09-02 wall-2026-09-01"
Check "nothing doomed" ((Get-DoomedTags @("wall-2026-09-01") 7) -join " ") ""

if ($failures -gt 0) {
  Write-Host "$failures check(s) failed"
  exit 1
}
Write-Host "windows-consumer: all checks passed"
