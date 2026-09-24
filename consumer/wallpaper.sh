#!/bin/zsh
# Wallpaper Journey subscriber for macOS. The default action downloads the latest
# triptych and applies it. --apply only reapplies the newest cached triptych, so
# the display watcher never needs network access. --check uninstalls everything
# if the user has set their own wallpaper, and --uninstall does so on demand.
# --status prints everything a bug report needs.

set -u

VERSION=3   # bump on any macOS consumer change, and keep consumer/VERSION in the repo equal (Windows has VERSION-windows)

# Don't inherit whatever PATH the caller had. Several steps here fail quietly
# when a tool is missing — a lost osascript reads as "no Spaces reference
# anything", which would let pruning delete an image a desktop is still using.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

REPO="https://github.com/ianmatson/wallpaper-journey"
SCRIPT_PATH="${0:A}"
DIR="$HOME/WallpaperJourney"   # where images are saved — change this and both plist paths together
# Installs predating the rename kept their images here. The folder is left
# behind as a symlink so Spaces still pointing inside it keep rendering, which
# also means a path under it is ours, not a wallpaper the user chose.
LEGACY_DIR="$HOME/DailyWall"
KEEP=7                  # days of wallpapers to retain
CURRENT_TAG_FILE="$DIR/current-tag"
APPLIED_MARKER="$DIR/.applied"
RELOAD_MARKER="$DIR/.reloading"
RELOAD_OWED_MARKER="$DIR/.reload-owed"
SYSTEM_EVENT_MARKER="$DIR/.system-change-pending"
SYSTEM_EVENT_TTL=900
NOTICE_MARKER="$DIR/.update-noticed"   # highest version already announced
STABLE_SET_FILE="$DIR/.stable-set"
TOPOLOGY_FILE="$DIR/.display-topology"
LOCK_FILE="/tmp/com.ianmatson.wallpaper-journey.$EUID.lock"
QUIET_AFTER_RELOAD=30   # seconds to leave the restarting wallpaper agent alone
# Every Space stores its own wallpaper as a file path. Two sets of paths let a
# daily update switch URLs instead of asking macOS to notice new bytes at the
# same URL. Old Spaces keep a valid previous set until convergence moves them.
STABLE_PREFIX="$DIR/current"
WALLPAPER_STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
LOG_DIR="$HOME/Library/Logs/WallpaperJourney"   # where launchd sends both jobs' output
STABLE_CHANGED=0
CONVERGE_PENDING=0
APPLY_CHANGED=0
typeset -a SYSTEM_EVENT_SNAPSHOT=()
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DAILY_JOB="com.ianmatson.wallpaper"
WATCHER_JOB="com.ianmatson.wallpaper-watcher"

mkdir -p "$DIR"

# Timestamped line for the launchd logs; a manual run shows it on the terminal.
note() {
  print -r -- "[$(date '+%F %T')] $*"
}

stable_set() {
  local set=""

  [[ -r "$STABLE_SET_FILE" ]] && set="$(<"$STABLE_SET_FILE")"
  [[ "$set" == a || "$set" == b ]] || return 1
  print -r -- "$set"
}

active_stable_prefix() {
  local set

  set=$(stable_set) || set=a
  print -r -- "$STABLE_PREFIX-$set"
}

stable_ready() {
  local prefix="${1:-$(active_stable_prefix)}"
  local slot

  for slot in left middle right; do
    [[ -s "$prefix-$slot.jpg" ]] || return 1
  done
}

stable_matches_tag() {
  local tag="$1"
  local prefix
  local set
  local slot

  if (( $# >= 2 )); then
    prefix="$2"
  else
    set=$(stable_set) || return 1
    prefix="$STABLE_PREFIX-$set"
  fi
  for slot in left middle right; do
    [[ "$DIR/$tag-landscape-$slot.jpg" -ef "$prefix-$slot.jpg" ]] \
      || cmp -s -- "$DIR/$tag-landscape-$slot.jpg" "$prefix-$slot.jpg" \
      || return 1
  done
}

cached_tag() {
  local tag=""
  local slot
  local middle

  if [[ -r "$CURRENT_TAG_FILE" ]]; then
    tag="$(<"$CURRENT_TAG_FILE")"
  fi

  # Let existing subscribers upgrade without waiting for the next daily run.
  if [[ "$tag" != wall-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]]; then
    middle=$(print -rl -- "$DIR"/wall-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-landscape-middle.jpg(N) \
      | sort -r | head -n 1)
    [[ -n "$middle" ]] || return 1
    tag="${middle:t}"
    tag="${tag%-landscape-middle.jpg}"
  fi

  for slot in left middle right; do
    [[ -s "$DIR/$tag-landscape-$slot.jpg" ]] || return 1
  done

  print -r -- "$tag"
}

# Publishes a complete day to the inactive a/b path set, then moves one small
# marker to make that set active. Hard links keep the archive and live paths on
# one copy of the bytes. Alternating the paths avoids macOS's same-URL cache.
# Sets STABLE_CHANGED when the active set moved.
publish_stable() {
  local tag="$1"
  local current=""
  local target
  local target_prefix
  local slot
  local src
  local dst
  local tmp
  local marker_tmp

  STABLE_CHANGED=0
  if current=$(stable_set); then
    if stable_matches_tag "$tag" "$STABLE_PREFIX-$current"; then
      return 0
    fi
    [[ "$current" == a ]] && target=b || target=a
  else
    target=a
  fi
  target_prefix="$STABLE_PREFIX-$target"

  # The active marker stays on the old complete set until every new link is in
  # place. A stopped process can leave only an unused inactive set behind.
  for slot in left middle right; do
    src="$DIR/$tag-landscape-$slot.jpg"
    dst="$target_prefix-$slot.jpg"
    [[ -s "$src" ]] || return 1
    tmp="$dst.new.$$"
    ln -f -- "$src" "$tmp" 2>/dev/null || cp -f -- "$src" "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dst" || { rm -f -- "$tmp"; return 1; }
  done

  marker_tmp="$STABLE_SET_FILE.$$"
  print -r -- "$target" > "$marker_tmp" || return 1
  # Persist this before the active-bank commit. If the process stops after the
  # commit, a later event still knows that WallpaperAgent must reload the new
  # bytes. An early marker only causes one harmless reload of the old bank.
  : > "$RELOAD_OWED_MARKER" || { rm -f -- "$marker_tmp"; return 1; }
  mv -f -- "$marker_tmp" "$STABLE_SET_FILE" || { rm -f -- "$marker_tmp"; return 1; }
  STABLE_CHANGED=1
  return 0
}

# Every question asked of the wallpaper store runs through this one JXA
# program, so the fragile part — decoding Apple's undocumented Index.plist,
# with image choices hidden in nested binary plists — lives in exactly one
# place. $1 selects the question:
#   status      ours / "theirs <unix-time>" / "theirs unknown" / nothing
#   referenced  paths under our folders that some desktop still points at
#   converge    rewrite the store so every desktop points at the active paths
#   describe    one readable line per display and Space, for --status
# The callers below document what each answer means.
store_query() {
  local stable_prefix

  stable_prefix=$(active_stable_prefix)
  osascript -l JavaScript - "$1" "$WALLPAPER_STORE" "$DIR" "$LEGACY_DIR" "$stable_prefix" 2>/dev/null <<'EOF'
function run(argv) {
  ObjC.import("AppKit");
  const mode = argv[0];
  const storePath = argv[1];
  const dirs = [argv[2], argv[3]].map(function (d) { return d.replace(/\/*$/, "/"); });
  const stablePrefix = argv[4];

  // ---- shared decoding helpers ----

  function dict(value) {
    if (value === null || value === undefined) return null;
    return !value.isNil() && value.isKindOfClass($.NSDictionary) ? value : null;
  }

  function parsePlist(data, mutable) {
    if (data.isNil() || !data.isKindOfClass($.NSData)) return null;
    // 2 = mutable containers and leaves, so entries can be edited in place.
    const value = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(
      data, mutable ? 2 : 0, Ref(), Ref());
    return value.isNil() ? null : value;
  }

  function loadStore(mutable) {
    const store = parsePlist($.NSData.dataWithContentsOfFile(storePath), mutable);
    return store !== null && store.isKindOfClass($.NSDictionary) ? store : null;
  }

  function choiceOf(desktop) {
    if (desktop === null) return null;
    const content = dict(desktop.objectForKey("Content"));
    if (content === null) return null;
    const choices = content.objectForKey("Choices");
    if (choices.isNil() || !choices.isKindOfClass($.NSArray) || choices.count === 0) return null;
    const choice = choices.objectAtIndex(0);
    return choice.isKindOfClass($.NSDictionary) ? choice : null;
  }

  // The file path inside one Configuration blob, or null.
  function pathFromConfig(cfg) {
    const inner = parsePlist(cfg, false);
    if (inner === null || !inner.isKindOfClass($.NSDictionary)) return null;
    const url = dict(inner.objectForKey("url"));
    if (url === null) return null;
    const relative = ObjC.unwrap(url.objectForKey("relative"));
    if (!relative) return null;
    return ObjC.unwrap($.NSURL.URLWithString(relative).path);
  }

  function imagePath(desktop) {
    const choice = choiceOf(dict(desktop));
    if (choice === null) return null;
    if (ObjC.unwrap(choice.objectForKey("Provider")) !== "com.apple.wallpaper.choice.image") return null;
    return pathFromConfig(choice.objectForKey("Configuration"));
  }

  function ours(path) {
    return path !== null && dirs.some(function (d) { return path.startsWith(d); });
  }

  function lastSet(desktop) {
    const stamp = desktop.objectForKey("LastSet");
    return stamp.isNil() ? 0 : stamp.timeIntervalSince1970;
  }

  // ---- status ----

  // When was the wallpaper we are looking at chosen? A desktop showing an
  // image file answers exactly, by the path it recorded. A desktop showing one
  // of Apple's own wallpapers — dynamic, aerial, or a solid color — records no
  // file at all and so can never match a path, which is why the newest time on
  // any desktop that is not ours has to answer for it. Without that fallback
  // every such desktop reads as undatable, and an undatable desktop used to
  // end the subscription on sight.
  function chosenAt(store, wanted) {
    let exact = 0;
    let foreign = 0;
    function walk(value) {
      if (value.isNil()) return;
      if (value.isKindOfClass($.NSArray)) { value.js.forEach(walk); return; }
      if (!value.isKindOfClass($.NSDictionary)) return;
      const desktop = dict(value.objectForKey("Desktop"));
      if (desktop !== null) {
        const stamp = desktop.objectForKey("LastSet");
        if (!stamp.isNil()) {
          const path = imagePath(desktop);
          const when = stamp.timeIntervalSince1970;
          if (path === wanted) exact = Math.max(exact, when);
          else if (!ours(path)) foreign = Math.max(foreign, when);
        }
      }
      value.allValues.js.forEach(walk);
    }
    walk(store);
    return exact || foreign;
  }

  function statusMode() {
    const ws = $.NSWorkspace.sharedWorkspace;
    const screens = $.NSScreen.screens.js;
    if (screens.length === 0) return "";

    let foreignPath = null;
    for (const screen of screens) {
      const url = ws.desktopImageURLForScreen(screen);
      // No answer means unknown, not an opt-out: the wallpaper agent reports
      // nothing while it is busy, and guessing there would uninstall us.
      if (url.isNil()) return "";
      const path = ObjC.unwrap(url.path);
      if (!path) return "";
      if (!ours(path)) {
        foreignPath = path;
        break;
      }
    }
    if (foreignPath === null) return "ours";

    const store = loadStore(false);
    if (store === null) return "theirs unknown";
    const chosen = chosenAt(store, foreignPath);
    return chosen === 0 ? "theirs unknown" : "theirs " + Math.round(chosen);
  }

  // ---- referenced ----

  function referencedMode() {
    const store = loadStore(false);
    if (store === null) return "";
    const found = {};
    // Walk the whole store and decode any data blob that turns out to be an
    // image choice, whichever corner of the format it sits in.
    function walk(value) {
      if (value.isNil()) return;
      if (value.isKindOfClass($.NSDictionary)) {
        value.allValues.js.forEach(walk);
      } else if (value.isKindOfClass($.NSArray)) {
        value.js.forEach(walk);
      } else if (value.isKindOfClass($.NSData)) {
        const path = pathFromConfig(value);
        if (ours(path)) found[path] = true;
      }
    }
    walk(store);
    return Object.keys(found).join("\n");
  }

  // ---- converge ----

  function convergeMode() {
    function stablePath(slot) { return stablePrefix + "-" + slot + ".jpg"; }
    function slotOf(path) {
      if (/-left\.jpg$/.test(path)) return "left";
      if (/-right\.jpg$/.test(path)) return "right";
      return "middle";
    }

    // Keep the exact bytes that we decoded. WallpaperAgent can save the same
    // file while this process works, so never replace a newer agent write with
    // a tree that came from an older snapshot.
    const originalData = $.NSData.dataWithContentsOfFile(storePath);
    const store = parsePlist(originalData, true);
    if (store === null || !store.isKindOfClass($.NSDictionary)) return "pending";

    let changed = false;
    let pending = false;

    // Ours under a dated or pre-rename path is repointed at the active path for
    // its panel, so a stale entry can serve as a source like any other.
    function normalize(desktop) {
      const path = imagePath(desktop);
      if (!ours(path)) return;
      const slot = slotOf(path);
      if (path === stablePath(slot)) return;
      const choice = choiceOf(desktop);
      const inner = parsePlist(choice.objectForKey("Configuration"), true);
      if (inner === null || !inner.isKindOfClass($.NSDictionary)) return;
      const url = dict(inner.objectForKey("url"));
      if (url === null) return;
      url.setObjectForKey(
        ObjC.unwrap($.NSURL.fileURLWithPath(stablePath(slot)).absoluteString), "relative");
      // 200 = binary plist, the format the agent writes itself.
      const rewritten = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(
        inner, 200, 0, Ref());
      if (rewritten.isNil()) return;
      choice.setObjectForKey(rewritten, "Configuration");
      changed = true;
    }

    // Deep, independent copy, via the same serializer that writes the file.
    function duplicate(desktop) {
      const blob = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(
        desktop, 200, 0, Ref());
      if (blob.isNil()) return null;
      const copy = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(
        blob, 2, Ref(), Ref());
      return copy.isNil() ? null : copy;
    }

    const displays = dict(store.objectForKey("Displays"));
    if (displays === null) return "pending";
    const spaces = dict(store.objectForKey("Spaces"));

    // Everything on one display converges to one entry, so gather its own
    // holder plus each Space's explicit holder for that display. A Space has
    // only one shared Default holder. It cannot represent several displays and
    // must never be added to every display group.
    const byDisplay = {};
    const defaults = [];
    function holdersFor(key) {
      return byDisplay[key] || (byDisplay[key] = []);
    }
    displays.allKeys.js.forEach(function (dkey) {
      const entry = dict(displays.objectForKey(dkey));
      if (entry !== null) holdersFor(ObjC.unwrap(dkey)).push(entry);
    });
    if (spaces !== null) {
      spaces.allKeys.js.forEach(function (skey) {
        const space = dict(spaces.objectForKey(skey));
        if (space === null) return;
        const def = dict(space.objectForKey("Default"));
        if (def !== null) defaults.push(def);
        const perDisplay = dict(space.objectForKey("Displays"));
        if (perDisplay === null) return;
        perDisplay.allKeys.js.forEach(function (dkey) {
          const holder = dict(perDisplay.objectForKey(dkey));
          if (holder === null) return;
          holdersFor(ObjC.unwrap(dkey)).push(holder);
        });
      });
    }

    Object.keys(byDisplay).forEach(function (dkey) {
      const holders = byDisplay[dkey];

      // The freshest ours entry on the display is the model everything else
      // copies. Newest wins because apply_tag's write is always the newest —
      // right after an install that is the Space it just set, since a
      // wallpaper the user set by hand lands on the display's own entry.
      let model = null;
      let modelStamp = -1;
      let foreign = false;
      holders.forEach(function (holder) {
        const desktop = dict(holder.objectForKey("Desktop"));
        if (desktop === null) return;
        if (!ours(imagePath(desktop))) {
          foreign = true;
          return;
        }
        if (lastSet(desktop) > modelStamp) {
          modelStamp = lastSet(desktop);
          model = desktop;
        }
      });
      if (model === null) {
        if (foreign) pending = true;
        return;
      }
      normalize(model);
      const modelPath = imagePath(model);

      holders.forEach(function (holder) {
        const desktop = holder.objectForKey("Desktop");
        if (!desktop.isNil() && imagePath(desktop) === modelPath) return;
        const copy = duplicate(model);
        if (copy === null) return;
        holder.setObjectForKey(copy, "Desktop");
        changed = true;
      });
    });

    // Keep an existing app-owned Default on the active a/b path for its own
    // panel. Leave a foreign Default alone because no single display model is
    // correct for a fallback that is shared by all displays.
    defaults.forEach(function (holder) {
      const desktop = dict(holder.objectForKey("Desktop"));
      if (desktop !== null && ours(imagePath(desktop))) normalize(desktop);
    });

    if (changed) {
      const outData = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(
        store, 200, 0, Ref());
      if (outData.isNil()) return "pending";
      const currentData = $.NSData.dataWithContentsOfFile(storePath);
      if (currentData.isNil() || !currentData.isEqualToData(originalData)) return "pending";
      if (!outData.writeToFileAtomically(storePath, true)) return "pending";
    }
    return (changed ? "changed " : "") + (pending ? "pending" : "");
  }

  // ---- describe ----

  function describeMode() {
    const store = loadStore(false);
    if (store === null) return "store unreadable";
    const lines = [];
    function shown(desktop) {
      const choice = choiceOf(dict(desktop));
      if (choice === null) return "none";
      const path = imagePath(desktop);
      return path !== null ? path : ObjC.unwrap(choice.objectForKey("Provider"));
    }
    const displays = dict(store.objectForKey("Displays"));
    if (displays !== null) {
      displays.allKeys.js.forEach(function (dkey) {
        const entry = dict(displays.objectForKey(dkey));
        if (entry === null) return;
        lines.push("display " + ObjC.unwrap(dkey).slice(0, 8) + "  " +
          shown(entry.objectForKey("Desktop")));
      });
    }
    const spaces = dict(store.objectForKey("Spaces"));
    if (spaces !== null) {
      spaces.allKeys.js.forEach(function (skey) {
        const space = dict(spaces.objectForKey(skey));
        if (space === null) return;
        const def = dict(space.objectForKey("Default"));
        lines.push("space   " + (ObjC.unwrap(skey) || "default*").slice(0, 8) + "  " +
          (def === null ? "none" : shown(def.objectForKey("Desktop"))));
      });
    }
    return lines.sort().join("\n");
  }

  if (mode === "status") return statusMode();
  if (mode === "referenced") return referencedMode();
  if (mode === "converge") return convergeMode();
  if (mode === "describe") return describeMode();
  return "";
}
EOF
}

# The store is the wallpaper agent's memory of every desktop, on screen or not.
# Editing it is the only way to reach a Space that is not visible: the public
# API stops at the active Space of each display, and Apple ships nothing else.
# So converge the whole store in one pass: for each display, take the entry of
# ours the agent stamped most recently — apply_tag's write is always the
# newest — and copy it over every entry on that display that differs, Spaces
# and the display's own entry alike. That converts a desktop showing something
# foreign, repoints a dated or pre-rename path at the active paths, corrects a
# Space carrying the wrong panel for its display, and gives new Spaces an ours
# entry to inherit. The agent reload that follows lands it all on screen.
#
# The source entry can as easily be a Space as the display's own entry: macOS
# stamps a wallpaper set by hand onto the display entry itself, so right after
# an install the freshest ours entry on a display is usually the Space
# apply_tag just set, not the display.
#
# Copy, never invent: every entry written here is a byte copy of one the agent
# already accepted. Anything unrecognized — an unreadable store, a reshaped
# format — is left alone, and the cost of that caution is only that those
# desktops keep their old wallpaper. Sets STABLE_CHANGED when the store moved
# and a reload is owed, and CONVERGE_PENDING when a display had foreign entries
# but nothing of ours to copy yet — the agent records what apply_tag set only a
# few seconds after the fact, so pending resolves by waiting and trying again.
converge_store() {
  local out

  CONVERGE_PENDING=0
  if ! out=$(store_query converge); then
    CONVERGE_PENDING=1
    note "wallpaper store query failed; postponing its reload"
    return 0
  fi
  if [[ "$out" == *changed* ]]; then
    STABLE_CHANGED=1
    : > "$RELOAD_OWED_MARKER" || note "could not save the pending reload marker"
  fi
  [[ "$out" == *pending* ]] && CONVERGE_PENDING=1
  return 0
}

reload_owed() {
  (( STABLE_CHANGED )) || [[ -e "$RELOAD_OWED_MARKER" ]]
}

# The wallpaper agent saves a public-API change to its store a few seconds
# after the setter returns. Wait for that model when a setter ran. A no-op apply
# can converge at once. Reload only when a bank or store entry changed.
settle_and_converge() {
  local tag="$1"
  local first_delay="${2:-5}"
  local try

  for try in 1 2 3 4 5; do
    if (( try == 1 )); then
      (( first_delay > 0 )) && sleep "$first_delay"
    else
      sleep 5
    fi
    converge_store
    (( CONVERGE_PENDING )) || break
    note "converge pending (agent not settled yet), try $try of 5"
  done
  if (( CONVERGE_PENDING )); then
    note "converge still pending; the next event retries before any reload"
  elif reload_owed; then
    note "reloading the wallpaper agent so every desktop picks up $tag"
    reload_all_spaces
  fi
}

# Restarting the wallpaper agent makes it reload every Space from the store
# that convergence just updated. SIP blocks launchctl kickstart for this
# service, so signal the agent instead.
#
# The marker dates the restart. Until the agent has read its store back it
# answers with whatever it likes, and the watcher must not read one of those
# answers as the user choosing a wallpaper.
reload_all_spaces() {
  : > "$RELOAD_MARKER"
  killall WallpaperAgent 2>/dev/null || true
  rm -f -- "$RELOAD_OWED_MARKER"
}

# True while the wallpaper agent is still coming back from our own reload.
reloading() {
  local stamp

  stamp=$(stat -f %m "$RELOAD_MARKER" 2>/dev/null) || return 1
  (( $(date +%s) - stamp < QUIET_AFTER_RELOAD ))
}

# The watcher writes this marker before it queues a display, wake, or Space
# apply. A check that is already running must not treat that short transition
# as a manual opt-out while the watcher waits for its one child task to finish.
system_change_pending() {
  local marker
  local stamp

  for marker in "$SYSTEM_EVENT_MARKER".*(N); do
    stamp=$(stat -f %m "$marker" 2>/dev/null) || continue
    (( $(date +%s) - stamp < SYSTEM_EVENT_TTL )) && return 0
  done
  return 1
}

# Capture exact marker names before an operation. Each event gets a unique file,
# so deleting this snapshot after success cannot delete a newer queued event.
capture_system_events() {
  SYSTEM_EVENT_SNAPSHOT=("$SYSTEM_EVENT_MARKER".*(N))
}

complete_system_events() {
  (( ${#SYSTEM_EVENT_SNAPSHOT} > 0 )) \
    && rm -f -- "${SYSTEM_EVENT_SNAPSHOT[@]}"
  SYSTEM_EVENT_SNAPSHOT=()
}

# APPLIED_MARKER is the opt-out cutoff, not an activity timestamp. Create it
# for an older installation, and move it only after at least one setter worked.
record_apply_success() {
  local did_set="$1"

  if (( did_set )) || [[ ! -e "$APPLIED_MARKER" ]]; then
    : > "$APPLIED_MARKER"
  fi
}

apply_tag() {
  local tag="$1"
  local prefix
  local output
  local state
  local diagnostics
  local topology_tmp
  local attempt
  local set_count
  local applied_any=0

  APPLY_CHANGED=0

  # Upgrades and interrupted publications can have no active path set, or an
  # active set for an older cached tag. Publish a complete alternate set first.
  stable_matches_tag "$tag" || publish_stable "$tag" || return 1
  prefix=$(active_stable_prefix)
  stable_ready "$prefix" || return 1

  # One JXA process owns one complete operation. It snapshots the ordered
  # displays, chooses the slots, applies every file, and then verifies that the
  # topology did not change under it. A changed topology or failed setter makes
  # the whole attempt fail so the shell can retry from a fresh snapshot.
  for attempt in 1 2 3; do
    if output=$(osascript -l JavaScript - \
      "$prefix-left.jpg" "$prefix-middle.jpg" "$prefix-right.jpg" 2>&1 <<'EOF'
function run(argv) {
  ObjC.import("AppKit");
  ObjC.import("CoreGraphics");
  ObjC.import("Foundation");
  ObjC.bindFunction("CGDisplayCreateUUIDFromDisplayID", ["id", ["unsigned int"]]);
  ObjC.bindFunction("CFMakeCollectable", ["id", ["void *"]]);

  if (argv.length !== 3) throw new Error("expected left, middle, and right image paths");

  const fm = $.NSFileManager.defaultManager;
  argv.forEach((path) => {
    if (!fm.fileExistsAtPath(path)) throw new Error("wallpaper file is missing: " + path);
  });

  function uuidFor(displayID) {
    try {
      const uuidRef = $.CGDisplayCreateUUIDFromDisplayID(displayID);
      if (uuidRef.isNil()) return "display-" + displayID;
      const stringRef = $.CFUUIDCreateString(null, uuidRef);
      const stringObject = $.CFMakeCollectable(stringRef);
      if (stringObject.isNil()) return "display-" + displayID;
      const value = ObjC.unwrap(stringObject);
      if (value) return String(value);
    } catch (_) {}
    return "display-" + displayID;
  }

  function displaySnapshot() {
    const items = $.NSScreen.screens.js.map((screen) => {
      const number = screen.deviceDescription.objectForKey("NSScreenNumber");
      if (number.isNil()) throw new Error("a screen has no Core Graphics display ID");
      const displayID = Number(ObjC.unwrap(number));
      const frame = screen.frame;
      let name = "";
      try { name = String(ObjC.unwrap(screen.localizedName) || ""); } catch (_) {}

      return {
        screen: screen,
        id: displayID,
        uuid: uuidFor(displayID),
        name: name,
        frame: {
          x: Number(frame.origin.x),
          y: Number(frame.origin.y),
          width: Number(frame.size.width),
          height: Number(frame.size.height),
        },
        scale: Number(screen.backingScaleFactor),
        pixels: {
          width: Number($.CGDisplayPixelsWide(displayID)),
          height: Number($.CGDisplayPixelsHigh(displayID)),
        },
        rotation: Number($.CGDisplayRotation(displayID)),
        mirror: {
          inSet: Boolean($.CGDisplayIsInMirrorSet(displayID)),
          always: Boolean($.CGDisplayIsAlwaysInMirrorSet(displayID)),
          sourceID: Number($.CGDisplayMirrorsDisplay(displayID)),
        },
      };
    });

    items.sort((a, b) => {
      const horizontal = a.frame.x - b.frame.x;
      const vertical = b.frame.y - a.frame.y;
      return horizontal || vertical || a.uuid.localeCompare(b.uuid);
    });
    if (items.length === 0) throw new Error("macOS reported no displays");
    return items;
  }

  function plain(items) {
    return items.map((item) => ({
      id: item.id,
      uuid: item.uuid,
      name: item.name,
      frame: item.frame,
      scale: item.scale,
      pixels: item.pixels,
      rotation: item.rotation,
      mirror: item.mirror,
    }));
  }

  function fingerprint(items) {
    return JSON.stringify(items.map((item) => ({
      uuid: item.uuid,
      frame: item.frame,
      scale: item.scale,
      pixels: item.pixels,
      rotation: item.rotation,
      mirror: item.mirror,
    })));
  }

  function slotFor(count, index) {
    if (count === 1) return 1;
    if (count === 2) return index;
    return index % 3;
  }

  const ws = $.NSWorkspace.sharedWorkspace;
  const before = displaySnapshot();
  const beforeFingerprint = fingerprint(before);
  const failures = [];
  const assignments = [];
  let setCount = 0;

  before.forEach((item, index) => {
    const slot = slotFor(before.length, index);
    const path = argv[slot];
    const url = $.NSURL.fileURLWithPath(path);
    const current = ws.desktopImageURLForScreen(item.screen);
    const assignment = {
      uuid: item.uuid,
      name: item.name,
      slot: ["left", "middle", "right"][slot],
      path: path,
      result: "unchanged",
    };
    assignments.push(assignment);
    if (!current.isNil() && ObjC.unwrap(current.path) === path) return;
    const error = Ref();
    const ok = ws.setDesktopImageURLForScreenOptionsError(
      url,
      item.screen,
      ws.desktopImageOptionsForScreen(item.screen),
      error
    );
    if (!Boolean(ok)) {
      assignment.result = "failed";
      let message = "macOS rejected the wallpaper";
      try {
        const nativeError = error[0];
        if (nativeError !== undefined && !nativeError.isNil()) {
          message = String(ObjC.unwrap(nativeError.localizedDescription) || message);
        }
      } catch (_) {}
      failures.push({
        uuid: item.uuid,
        name: item.name,
        slot: ["left", "middle", "right"][slot],
        path: path,
        error: message,
      });
    } else {
      assignment.result = "applied";
      setCount += 1;
    }
  });

  const after = displaySnapshot();
  const details = JSON.stringify({
    displays: plain(after),
    assignments: assignments,
    failures: failures,
    setCount: setCount,
  });
  if (beforeFingerprint !== fingerprint(after)) return "RETRY_TOPOLOGY\n" + details;
  if (failures.length > 0) return "ERROR\n" + details;
  return "OK\n" + details;
}
EOF
    ); then
      state="${output%%$'\n'*}"
      diagnostics="${output#*$'\n'}"
      set_count=$(print -r -- "$diagnostics" \
        | sed -n 's/.*"setCount":\([0-9][0-9]*\)}$/\1/p')
      [[ "$set_count" == <-> ]] && (( set_count > 0 )) && applied_any=1
      if [[ "$state" == OK ]]; then
        topology_tmp="$TOPOLOGY_FILE.$$"
        print -r -- "$diagnostics" > "$topology_tmp" || return 1
        mv -f -- "$topology_tmp" "$TOPOLOGY_FILE" || { rm -f -- "$topology_tmp"; return 1; }
        # This timestamp is the opt-out cutoff. Do not move it when every URL
        # already matched: a no-op system event must not hide a wallpaper the
        # user selected earlier on another Space. A missing marker is created
        # once so an older installation can migrate safely.
        record_apply_success "$applied_any"
        APPLY_CHANGED=$applied_any
        return 0
      fi
      note "wallpaper apply attempt $attempt of 3 returned $state"
      [[ -n "$diagnostics" ]] && print -u2 -r -- "$diagnostics"
    else
      note "wallpaper apply attempt $attempt of 3 failed"
      [[ -n "$output" ]] && print -u2 -r -- "$output"
    fi
    (( attempt < 3 )) && sleep 1
  done
  return 1
}

# Prints "ours" when every screen's wallpaper lives in $DIR or the folder used
# before the rename, "theirs <unix-time>" when any screen shows something else,
# "theirs unknown" when it does but the store cannot date it, and nothing when
# the answer is unknowable. The time says when that wallpaper was chosen, which
# is what separates a desktop this subscription has never reached from one the
# user has just changed.
wallpaper_status() {
  store_query status
}

# One immediate sample of the subscription state. Confirmation sleeps before
# any mutation lock, and a recent system-event marker rejects a transient
# foreign screen while the watcher's queued apply waits to run.
subscription_sample() {
  local state          # not "status": zsh keeps that one read-only
  local chosen
  local applied

  # Before the first apply there is nothing to opt out of.
  [[ -e "$APPLIED_MARKER" ]] || { print -r -- ok; return; }

  # None of the agent's answers count while it restarts from our own reload.
  reloading && { print -r -- unknown; return; }

  state="$(wallpaper_status)"
  case "$state" in
    ours) print -r -- ok; return ;;
    'theirs '*) ;;
    # No answer at all. Ask again on the next check.
    *) print -r -- unknown; return ;;
  esac

  chosen="${state#theirs }"
  # A store we could not read at all. A desktop we have never reached and one
  # the user has just changed look identical from here, so do neither thing
  # rather than guess: guessing once cost a subscriber the whole subscription.
  [[ "$chosen" == <-> ]] || { print -r -- unknown; return; }

  applied=$(stat -f %m "$APPLIED_MARKER" 2>/dev/null) || applied=0

  # A desktop this subscription has never reached still shows whatever the user
  # had before installing, and overwriting that on arrival is the job — ending
  # the subscription over it is not. Only a wallpaper chosen after our most
  # recent apply is a real opt-out.
  (( chosen > applied )) || { print -r -- ok; return; }

  # The watcher can receive a system event while this check is in its confirm
  # delay. Its queued apply runs after this process exits, so leave the
  # subscription alone until that apply has corrected the visible desktop.
  system_change_pending && { print -r -- unknown; return; }

  print -r -- optout
}

# Where the subscription stands on the desktops currently on screen:
#   optout   the user chose a wallpaper after our most recent apply
#   ok       every screen is ours, or shows a desktop we have never reached
#   unknown  a screen is not ours and nothing on hand says when it was chosen
subscription_state() {
  local first
  local second

  first=$(subscription_sample)
  [[ "$first" == optout ]] || { print -r -- "$first"; return; }

  # Require a second independent opt-out sample. If a display, wake, or Space
  # event arrives during this delay, its marker makes that sample unknown and
  # the watcher runs the queued apply after this process exits.
  sleep 3
  second=$(subscription_sample)
  print -r -- "$second"
}

# Removes everything the installer created. $1 is the launchd job the caller
# runs under; it is booted out last because bootout kills the job's processes,
# which would end this script before the cleanup finished.
uninstall() {
  local last="$1"
  local domain="gui/$(id -u)"
  local job

  for job in "$DAILY_JOB" "$WATCHER_JOB"; do
    [[ "$job" == "$last" ]] && continue
    launchctl bootout "$domain/$job" 2>/dev/null || true
  done

  # Delete only files Wallpaper Journey created, in case DIR points at a shared
  # folder.
  rm -f -- \
    "$LAUNCH_AGENTS/$DAILY_JOB.plist" \
    "$LAUNCH_AGENTS/$WATCHER_JOB.plist" \
    "$LOG_DIR/wallpaper.log" "$LOG_DIR/wallpaper-watcher.log" \
    /tmp/wallpaper.log /tmp/wallpaper-watcher.log \
    "$DIR"/wall-*(N) "$STABLE_PREFIX"-*.jpg(N) "$CURRENT_TAG_FILE" "$APPLIED_MARKER" \
    "$RELOAD_MARKER" "$RELOAD_OWED_MARKER" "$NOTICE_MARKER" \
    "$STABLE_SET_FILE" "$TOPOLOGY_FILE" \
    "$SYSTEM_EVENT_MARKER" "$SYSTEM_EVENT_MARKER".*(N) \
    "$DIR/wallpaper-watcher.js" "$DIR/wallpaper.sh"
  rmdir -- "$DIR" "$LOG_DIR" 2>/dev/null || true
  # The compatibility symlink left by the rename, but never a real folder that
  # happens to sit there.
  [[ -L "$LEGACY_DIR" ]] && rm -f -- "$LEGACY_DIR"

  launchctl bootout "$domain/$last" 2>/dev/null || true
}

self_destruct() {
  note "manual wallpaper change detected; uninstalling (from $1)"
  osascript -e 'display notification "You set your own wallpaper, so Wallpaper Journey uninstalled itself and removed its files." with title "Wallpaper Journey"' 2>/dev/null || true
  uninstall "$1"
}

# There is deliberately no auto-updater: subscribers run code from this repo
# once, at install, with consent — images are the only thing that flows after
# that, and a repo compromise must not become code running on their machines.
# So updates are announced, never applied: when the repo carries a newer
# consumer version, say so in one notification and let the user rerun the
# installer themselves. The marker keeps each version's announcement to one.
update_notice() {
  local remote
  local noticed=0
  local choice

  remote=$(curl -fsSL --max-time 10 \
    "https://raw.githubusercontent.com/ianmatson/wallpaper-journey/main/consumer/VERSION" \
    2>/dev/null) || return 0
  [[ "$remote" == <-> ]] || return 0
  (( remote > VERSION )) || return 0

  [[ -r "$NOTICE_MARKER" ]] && noticed="$(<"$NOTICE_MARKER")"
  [[ "$noticed" == <-> ]] || noticed=0
  (( remote > noticed )) || return 0

  note "consumer version $remote is available (this is $VERSION); announcing it"
  # The marker is written before the dialog so a version is announced at most
  # once, whatever happens to the dialog.
  print -r -- "$remote" > "$NOTICE_MARKER"

  # A macOS notification cannot carry a button, so ask with a dialog instead.
  # It dismisses itself, and "Later" simply means this version stays quiet —
  # the marker above already saw to that.
  choice=$(osascript -e 'display dialog "A new Wallpaper Journey version is available. Rerun the installer from the README to get it." with title "Wallpaper Journey" buttons {"Later", "Open the README"} default button "Open the README" giving up after 60' 2>/dev/null) || return 0
  if [[ "$choice" == *"button returned:Open the README"* && "$choice" != *"gave up:true"* ]]; then
    open "$REPO#updating--macos" 2>/dev/null || true
  fi
}

# Everything a bug report needs, in one paste.
show_status() {
  local domain="gui/$(id -u)"
  local job
  local when
  local state
  local path_set

  print -r -- "Wallpaper Journey consumer version $VERSION"
  for job in "$DAILY_JOB" "$WATCHER_JOB"; do
    if launchctl print "$domain/$job" >/dev/null 2>&1; then
      print -r -- "$job: loaded"
    else
      print -r -- "$job: not loaded"
    fi
  done
  if [[ -r "$CURRENT_TAG_FILE" ]]; then
    print -r -- "cached release: $(<"$CURRENT_TAG_FILE")"
  else
    print -r -- "cached release: none"
  fi
  if when=$(stat -f %Sm -t '%F %T' "$APPLIED_MARKER" 2>/dev/null); then
    print -r -- "last applied: $when"
  else
    print -r -- "last applied: never"
  fi
  if path_set=$(stable_set); then
    print -r -- "active path set: $path_set"
  else
    print -r -- "active path set: none"
  fi
  if [[ -r "$TOPOLOGY_FILE" ]]; then
    print -r -- "last applied topology: $(<"$TOPOLOGY_FILE")"
  else
    print -r -- "last applied topology: none"
  fi
  state="$(wallpaper_status)"
  print -r -- "screens now: ${state:-unknown}"
  print -r -- "logs: $LOG_DIR"
  print -r -- "desktops (from the wallpaper store):"
  store_query describe | sed 's/^/  /'
}

# Paths under $DIR that the wallpaper agent still points a Space at. Read only.
# The caller prunes only after convergence proves that the store is readable.
referenced_images() {
  store_query referenced
}

prune_cache() {
  local -a referenced
  local -a doomed
  local old
  local file

  referenced=(${(f)"$(referenced_images)"})
  doomed=(${(f)"$(print -rl -- "$DIR"/wall-*.jpg(N) \
    | sed -E 's|.*/(wall-[0-9]{4}-[0-9]{2}-[0-9]{2}).*|\1|' \
    | sort -ru | tail -n "+$((KEEP + 1))")"})

  for old in $doomed; do
    for file in "$DIR/$old"-*.jpg(N); do
      # A Space upgraded from an older version can still point at a dated name.
      # Dropping it would leave that desktop with no image at all.
      (( ${referenced[(I)$file]} )) && continue
      rm -f -- "$file"
    done
  done
}

refresh() {
  local tag
  local slot
  local out
  local tmp
  local tag_tmp

  # Resolve today's release tag from the /latest redirect (no API, no token).
  tag=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    -o /dev/null -w '%{url_effective}' "$REPO/releases/latest") \
    || { note "latest release lookup failed"; return 1; }
  tag="${tag##*/}"
  [[ "$tag" == wall-* ]] || { note "latest release tag is not a wallpaper release"; return 1; }

  # A desktop can be behind even when the release has not moved, so catch those
  # up before the early exit below rather than after it.
  if stable_set >/dev/null && stable_ready; then
    converge_store
    if (( ! CONVERGE_PENDING )) && reload_owed; then
      note "caught up desktops that were behind; reloading the wallpaper agent"
      reload_all_spaces
    fi
  fi

  # This runs several times a day so a late release still lands the same day.
  # Once the newest triptych is cached and on screen there is nothing to do,
  # and stopping here avoids re-setting a wallpaper that is already correct.
  if (( ! CONVERGE_PENDING )) \
    && [[ -r "$CURRENT_TAG_FILE" && "$(<"$CURRENT_TAG_FILE")" == "$tag" ]] \
    && stable_matches_tag "$tag" \
    && [[ "$(wallpaper_status)" == ours ]]; then
    return 0
  fi

  note "updating to $tag"

  # Cache the complete triptych. Display changes can then choose any layout
  # without downloading another asset.
  for slot in left middle right; do
    out="$DIR/$tag-landscape-$slot.jpg"
    [[ -s "$out" ]] && continue
    tmp="$out.download.$$"
    curl -fsSL --connect-timeout 10 --max-time 60 \
      -o "$tmp" "$REPO/releases/latest/download/landscape-$slot.jpg" \
      || { rm -f "$tmp"; note "download failed: landscape-$slot.jpg"; return 1; }
    [[ -s "$tmp" ]] || { rm -f "$tmp"; note "download empty: landscape-$slot.jpg"; return 1; }
    mv "$tmp" "$out"
  done

  # Publish the cache pointer only after all three panels are available.
  tag_tmp="$CURRENT_TAG_FILE.$$"
  print -r -- "$tag" > "$tag_tmp"
  mv "$tag_tmp" "$CURRENT_TAG_FILE"

  # Publish the inactive path bank first, then set the visible desktops, then
  # converge the store so every other Space points at that bank, and finally
  # make the agent reload. The converge must read the store
  # only after the agent has saved what apply_tag just set — it does so a few
  # seconds after a change, and converging a display needs an ours entry on it
  # to copy. Pending means that save has not landed yet, so wait and try again
  # rather than reloading a store that still has desktops to catch.
  publish_stable "$tag" || { note "publishing the active paths failed"; return 1 }
  apply_tag "$tag" || { note "applying to the visible displays failed"; return 1 }
  note "applied $tag to the visible displays"
  settle_and_converge "$tag" "$(( APPLY_CHANGED ? 5 : 0 ))"
  if (( CONVERGE_PENDING )); then
    note "skipping cache pruning until the wallpaper store is readable and settled"
  else
    prune_cache
  fi
}

# lockf queues every Wallpaper Journey mutator on one kernel-managed lock. The
# kernel releases it after normal exits, signals, and crashes. Keep the file so
# no waiter can hold an older unlinked inode. Wait without a lock timeout: each
# network call has its own limit, and a queued system event must not be lost.
with_operation_lock() {
  local action="$1"
  shift

  WALLPAPER_JOURNEY_LOCKED=1 /usr/bin/lockf -k \
    "$LOCK_FILE" "$SCRIPT_PATH" "--locked-$action" "$@"
}

require_operation_lock() {
  [[ "${WALLPAPER_JOURNEY_LOCKED:-}" == 1 ]] || {
    print -u2 -- "internal command requires the Wallpaper Journey operation lock"
    exit 2
  }
}

case "${1:-refresh}" in
  refresh|--refresh)
    case "$(subscription_state)" in
      optout) with_operation_lock optout "$DAILY_JOB" ;;
      ok) with_operation_lock refresh && update_notice ;;
    esac
    ;;
  apply|--apply)
    with_operation_lock apply
    ;;
  status|--status)
    show_status
    ;;
  check|--check)
    if [[ "$(subscription_state)" == optout ]]; then
      with_operation_lock optout "$WATCHER_JOB"
    fi
    ;;
  uninstall|--uninstall)
    with_operation_lock uninstall "$WATCHER_JOB"
    ;;
  --locked-refresh)
    require_operation_lock
    capture_system_events
    case "$(subscription_sample)" in
      ok) refresh && complete_system_events ;;
      optout) note "a manual wallpaper change appeared while refresh waited; leaving it alone" ;;
    esac
    ;;
  --locked-apply)
    require_operation_lock
    capture_system_events
    tag=$(cached_tag) || exit 0
    note "system change: reapplying cached $tag"
    apply_tag "$tag" || { note "applying to the visible displays failed"; exit 1; }
    note "applied $tag to the visible displays"
    settle_and_converge "$tag" "$(( APPLY_CHANGED ? 5 : 0 ))"
    complete_system_events
    ;;
  --locked-optout)
    require_operation_lock
    if [[ "$(subscription_sample)" == optout ]]; then
      self_destruct "$2"
    fi
    ;;
  --locked-uninstall)
    require_operation_lock
    print -r -- "Removing Wallpaper Journey's launch agents, scripts, images, and logs."
    uninstall "$2"
    ;;
  *)
    print -u2 -- "usage: $0 [--refresh|--apply|--check|--status|--uninstall]"
    exit 2
    ;;
esac
