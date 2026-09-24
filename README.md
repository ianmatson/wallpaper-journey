# Wallpaper Journey

An ongoing illustrated story told through daily wallpapers. Each episode pairs
three adjoining landscape panels with a short story passage and a Spotify
soundtrack. Codex plans the journey, generates the images, and reviews the result.

**[Latest release](https://github.com/ianmatson/wallpaper-journey/releases/latest)**
· **[Story archive](https://github.com/ianmatson/wallpaper-journey/releases)**

Releases use the tag `wall-YYYY-MM-DD` and are retained permanently. Production
runs daily, but publication time can vary. These links always serve the latest
published images; no GitHub account or token is needed:

| Left | Middle | Right |
| --- | --- | --- |
| [Download](https://github.com/ianmatson/wallpaper-journey/releases/latest/download/landscape-left.jpg) | [Download](https://github.com/ianmatson/wallpaper-journey/releases/latest/download/landscape-middle.jpg) | [Download](https://github.com/ianmatson/wallpaper-journey/releases/latest/download/landscape-right.jpg) |

## The story

The journey unfolds through planned arcs spanning weeks and months. Exploration
and drama have equal weight, with character development slightly ahead of
mystery. Themes emerge through choices and consequences; the cast, relationships,
and direction of the journey can change over time.

Private story state preserves established events, character knowledge, and
unresolved threads separately from future plans. Each new episode publishes a
caption and 80–150 words of story; outlines and the continuity journal stay private.

Planning follows completed episodes: editorial review every seven episodes, full
detail for the next arc with seven episodes remaining, and the next season's broad
outline before the final arc begins. Reviews can refine the future while preserving
what the audience has already seen.

## Subscribe

The desktop subscribers check at login and at 04:00, 08:00, 12:00, 16:00, and
20:00 in your local time. They download images when a new release appears.
Software updates require rerunning the installation commands.

### macOS

Install or update without admin rights:

```sh
curl -fsSL https://raw.githubusercontent.com/ianmatson/wallpaper-journey/main/consumer/install-macos.sh | zsh
```

Panels follow your left-to-right arrangement in **System Settings → Displays**:

| Monitors | Panels |
| --- | --- |
| 1 | Middle |
| 2 | Left, middle |
| 3 | Left, middle, right |
| 4+ | Left, middle, right, repeating |

The subscriber applies images across Spaces and reapplies cached images after
monitor, wake, or Space changes. It keeps seven days of images locally. A detected
manual wallpaper change on any screen opts you out and uninstalls the subscriber.

```sh
# Check the installation
zsh ~/WallpaperJourney/wallpaper.sh --status

# Check for a new release now
launchctl kickstart -k gui/$(id -u)/com.ianmatson.wallpaper

# Uninstall explicitly
zsh ~/WallpaperJourney/wallpaper.sh --uninstall
```

### Windows

Install or update without admin rights (Windows 8 or later):

```powershell
irm https://raw.githubusercontent.com/ianmatson/wallpaper-journey/main/consumer/install.ps1 | iex
```

<details>
<summary>Manual installation</summary>

```powershell
$Base = "https://raw.githubusercontent.com/ianmatson/wallpaper-journey/main/consumer"
$Dir = "$env:USERPROFILE\WallpaperJourney"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Invoke-WebRequest "$Base/install.ps1" -OutFile "$Dir\install.ps1" -UseBasicParsing
# Read it, then run it. It fetches wallpaper.ps1 and registers both tasks.
powershell -ExecutionPolicy Bypass -File "$Dir\install.ps1"
```

</details>

Panels follow your left-to-right arrangement in **Settings → System → Display**,
using the same table as macOS. A watcher task reapplies cached images within
seconds after monitor or virtual desktop changes, without network requests. It
keeps seven days of images locally. A manual wallpaper change on any monitor,
including a solid colour, opts you out and uninstalls the subscriber.

When a newer Windows subscriber is available, the next check asks once whether
to open this README; rerun the installation command to update. Versions from
before September 2026 use one image on every monitor and cannot announce
updates, so rerun it once to move to per-monitor panels.

```powershell
# Check the installation (logs: %LOCALAPPDATA%\WallpaperJourney\wallpaper.log)
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\WallpaperJourney\wallpaper.ps1" -Status

# Check for a new release now
Start-ScheduledTask -TaskName WallpaperJourney

# Uninstall explicitly
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\WallpaperJourney\wallpaper.ps1" -Uninstall
```

### iPhone and iPad

Install the [Daily Background shortcut](https://www.icloud.com/shortcuts/7e6407d39a0f42bf8187600761266203),
run it once, and approve its requested permissions. Select the wallpaper to change
in its **Set Wallpaper Photo** action. The shortcut uses the middle panel.

## How production works

The Linux producer runs through [`wallpaper-producer`](producer/wallpaper-producer),
the sole production entrypoint. Codex handles story planning, image generation,
visual review, public prose, and soundtrack selection. The wrapper handles
validation, 4× upscaling through the configured watcher, staging, and publication.

Story state advances only after the exact published release is verified.
Interrupted runs retain their episode, lease, and accepted artifacts for recovery;
artwork or soundtrack corrections preserve the episode number and prior local
revisions. Subscriber cache cleanup never deletes the public release archive.

- [Producer setup and recovery](producer/README.md)
- [Story state and planning cadence](producer/NARRATIVE.md)
- [Daily production skill](.agents/skills/wallpaper-journey-producer/SKILL.md)

From the repository root, run the isolated state and publication fixtures with:

```sh
python3 tests/narrative-state.py
zsh tests/linux-producer.zsh
```
