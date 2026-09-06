#!/usr/bin/env zsh

set -euo pipefail
umask 022

readonly SCRIPT_DIR="${0:A:h}"
readonly TIME_ZONE="${AI_WALLPAPERS_TIME_ZONE:-America/Chicago}"
readonly REPOSITORY="${AI_WALLPAPERS_REPOSITORY:-${SCRIPT_DIR:h}}"
readonly WORKSPACE_ROOT="${AI_WALLPAPERS_WORKSPACE_ROOT:-${REPOSITORY:h}}"
readonly REQUIRED_ORIGIN="${AI_WALLPAPERS_REQUIRED_ORIGIN:-git@github.com:ianmatson/wallpaper-journey.git}"
readonly GITHUB_REPOSITORY="${AI_WALLPAPERS_GITHUB_REPOSITORY:-ianmatson/wallpaper-journey}"
readonly NATIVE_ROOT="${AI_WALLPAPERS_NATIVE_ROOT:-$WORKSPACE_ROOT/story/native}"
readonly STYLE_ROOT="${AI_WALLPAPERS_STYLE_ROOT:-$WORKSPACE_ROOT/story/style-references}"
readonly UPSCALED_ROOT="${AI_WALLPAPERS_UPSCALED_ROOT:-$WORKSPACE_ROOT/story/upscaled}"
readonly STAGING_ROOT="${AI_WALLPAPERS_STAGING_ROOT:-$WORKSPACE_ROOT/story/staging}"
readonly PRIVATE_ROOT="${AI_WALLPAPERS_PRIVATE_ROOT:-$WORKSPACE_ROOT/story/private}"
readonly INPUT_ROOT="${AI_WALLPAPERS_INPUT_ROOT:-$WORKSPACE_ROOT/tmp}"
readonly CONTROL_ROOT="${AI_WALLPAPERS_CONTROL_DIR:-$WORKSPACE_ROOT/control/producer}"
readonly UPSCAYL_MODE="${AI_WALLPAPERS_UPSCAYL_MODE:-auto}"
readonly UPSCAYL_INBOX="${AI_WALLPAPERS_UPSCAYL_INBOX:-$WORKSPACE_ROOT/upscayl/inbox}"
readonly UPSCAYL_OUTPUT="${AI_WALLPAPERS_UPSCAYL_OUTPUT:-$WORKSPACE_ROOT/upscayl/output}"
readonly UPSCAYL_WORK="${AI_WALLPAPERS_UPSCAYL_WORK:-$WORKSPACE_ROOT/upscayl/work}"
readonly UPSCAYL_EXECUTABLE="${AI_WALLPAPERS_UPSCAYL_EXECUTABLE:-upscayl-bin}"
readonly UPSCAYL_MODELS="${AI_WALLPAPERS_UPSCAYL_MODELS:-$WORKSPACE_ROOT/upscayl/models}"
readonly UPSCAYL_MODEL="${AI_WALLPAPERS_UPSCAYL_MODEL:-digital-art-4x}"
readonly UPSCAYL_SCALE="${AI_WALLPAPERS_UPSCAYL_SCALE:-4}"
readonly UPSCAYL_GPU_ID="${AI_WALLPAPERS_UPSCAYL_GPU_ID:-}"
readonly UPSCAYL_MODEL_BIN_SHA256="${AI_WALLPAPERS_UPSCAYL_MODEL_BIN_SHA256:-fe01c269cfd10cdef8e018ab66ebe750cf79c7af4d1f9c16c737e1295229bacc}"
readonly UPSCAYL_MODEL_PARAM_SHA256="${AI_WALLPAPERS_UPSCAYL_MODEL_PARAM_SHA256:-2b8fb6e0ae4d2d85704ca08c119a2f5ea40add4f2ecd512eb7f4cd44b6127ed4}"
readonly SEED_IMAGE="${AI_WALLPAPERS_SEED_IMAGE:-$WORKSPACE_ROOT/seed/digital-alpine-observatory.png}"
readonly UPSCALE_TIMEOUT_SECONDS="${AI_WALLPAPERS_UPSCALE_TIMEOUT_SECONDS:-2700}"
readonly ENFORCE_WORKSPACE_BOUNDARY="${AI_WALLPAPERS_ENFORCE_WORKSPACE_BOUNDARY:-$([[ "$OSTYPE" == linux* ]] && print -r -- true || print -r -- false)}"

readonly RUN_DATE="${AI_WALLPAPERS_RUN_DATE:-$(TZ="$TIME_ZONE" date +%F)}"
[[ "$RUN_DATE" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]] || {
  print -u2 -r -- "ERROR: invalid run date: $RUN_DATE"
  exit 1
}
if date -d "$RUN_DATE" +%F >/dev/null 2>&1; then
  [[ "$(date -d "$RUN_DATE" +%F)" == "$RUN_DATE" ]] || {
    print -u2 -r -- "ERROR: invalid calendar date: $RUN_DATE"
    exit 1
  }
elif date -j -f %F "$RUN_DATE" +%F >/dev/null 2>&1; then
  [[ "$(date -j -f %F "$RUN_DATE" +%F)" == "$RUN_DATE" ]] || {
    print -u2 -r -- "ERROR: invalid calendar date: $RUN_DATE"
    exit 1
  }
else
  print -u2 -r -- "ERROR: could not validate run date: $RUN_DATE"
  exit 1
fi
readonly TAG="wall-$RUN_DATE"
readonly NATIVE_DIR="$NATIVE_ROOT/$TAG"
readonly UPSCALED_DIR="$UPSCALED_ROOT/$TAG"
readonly STAGING_DIR="$STAGING_ROOT/$TAG"
readonly SPOTIFY_BASE="$STAGING_DIR/spotify-playlist.json"
readonly STORY_FILE="$STAGING_DIR/story.txt"
readonly EPISODE_FILE="$STAGING_DIR/episode.txt"
readonly NOTES_BASE="$STAGING_DIR/release-notes.txt"
readonly CONTINUITY_LOG="$PRIVATE_ROOT/daily-continuity-log.md"
readonly SLOTS=(left middle right)

die() {
  print -u2 -r -- "ERROR: $*"
  exit 1
}

info() {
  print -u2 -r -- "[$(TZ="$TIME_ZONE" date '+%F %T %Z')] $*"
}

active_revision() {
  local latest=0 file name revision
  [[ -f "$SPOTIFY_BASE" ]] && latest=1
  for file in "$STAGING_DIR"/spotify-playlist-r*.json(N); do
    name="${file:t}"
    revision="${name#spotify-playlist-r}"
    revision="${revision%.json}"
    [[ "$revision" == <-> ]] || continue
    (( revision > latest )) && latest="$revision"
  done
  print -r -- "$latest"
}

spotify_file_for_revision() {
  local revision="$1"
  if (( revision <= 1 )); then
    print -r -- "$SPOTIFY_BASE"
  else
    print -r -- "$STAGING_DIR/spotify-playlist-r$revision.json"
  fi
}

notes_file_for_revision() {
  local revision="$1"
  if (( revision <= 1 )); then
    print -r -- "$NOTES_BASE"
  else
    print -r -- "$STAGING_DIR/release-notes-r$revision.txt"
  fi
}

active_spotify_file() {
  local revision="$(active_revision)"
  (( revision == 0 )) && revision=1
  spotify_file_for_revision "$revision"
}

active_notes_file() {
  local revision="$(active_revision)"
  (( revision == 0 )) && revision=1
  notes_file_for_revision "$revision"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file is missing: $1"
}

require_input_file() {
  local input="$1" input_real root_real
  require_file "$input"
  [[ ! -L "$input" ]] || die "input file must not be a symlink: $input"
  input_real="${input:A}"
  root_real="${INPUT_ROOT:A}"
  [[ "$input_real" == "$root_real"/* ]] || die "input file must be under $root_real: $input_real"
}

story_engine() {
  require_command python3
  AI_WALLPAPERS_WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    AI_WALLPAPERS_PRIVATE_ROOT="$PRIVATE_ROOT" \
    AI_WALLPAPERS_INPUT_ROOT="$INPUT_ROOT" \
    AI_WALLPAPERS_NATIVE_ROOT="$NATIVE_ROOT" \
    AI_WALLPAPERS_STAGING_ROOT="$STAGING_ROOT" \
    AI_WALLPAPERS_RUN_DATE="$RUN_DATE" \
    python3 "$SCRIPT_DIR/narrative.py" "$@"
}

story_enabled() {
  local result=0
  story_engine enabled || result=$?
  (( result <= 1 )) || die "could not read narrative state"
  return "$result"
}

story_init() {
  require_input_file "${1:-}"
  validate_native >/dev/null
  validate_release --exact >/dev/null
  story_engine init "$1"
}

story_finalize() {
  validate_native >/dev/null
  story_engine finalize "$@"
}

story_commit() {
  validate_release --exact >/dev/null
  story_engine commit "$(active_notes_file)"
}

validate_configuration() {
  local path path_real workspace_real repository_real first second
  local -i i j
  local -a runtime_roots
  workspace_real="${WORKSPACE_ROOT:A}"
  repository_real="${REPOSITORY:A}"
  runtime_roots=(
    "$NATIVE_ROOT" "$STYLE_ROOT" "$UPSCALED_ROOT" "$STAGING_ROOT"
    "$PRIVATE_ROOT" "$INPUT_ROOT" "$CONTROL_ROOT" "$UPSCAYL_OUTPUT" "$UPSCAYL_WORK" "$UPSCAYL_MODELS"
  )
  for path in "$WORKSPACE_ROOT" "$REPOSITORY" "${runtime_roots[@]}" "$SEED_IMAGE"; do
    [[ "$path" == /* ]] || die "configured path must be absolute: $path"
  done
  for (( i = 1; i <= ${#runtime_roots[@]}; i++ )); do
    first="${runtime_roots[$i]:A}"
    for (( j = i + 1; j <= ${#runtime_roots[@]}; j++ )); do
      second="${runtime_roots[$j]:A}"
      [[ "$first" != "$second" ]] || die "runtime roots must be distinct: $first"
      [[ "$first" != "$second"/* && "$second" != "$first"/* ]] || \
        die "runtime roots must not be nested: $first and $second"
    done
  done
  if [[ "$ENFORCE_WORKSPACE_BOUNDARY" == true ]]; then
    [[ "$repository_real" == "$workspace_real"/* ]] || die "repository must be inside the workspace root"
    for path in "${runtime_roots[@]}" "${SEED_IMAGE:h}"; do
      path_real="${path:A}"
      [[ "$path_real" == "$workspace_real"/* ]] || die "runtime path escapes the workspace: $path_real"
      [[ "$path_real" != "$repository_real" && "$path_real" != "$repository_real"/* ]] || \
        die "runtime path must remain outside the public repository: $path_real"
    done
  fi
}

platform_name() {
  case "$OSTYPE" in
    darwin*) print -r -- macos ;;
    linux*) print -r -- linux ;;
    *) print -r -- unsupported ;;
  esac
}

resolved_upscayl_mode() {
  case "$UPSCAYL_MODE" in
    auto)
      [[ "$(platform_name)" == "macos" ]] && print -r -- watcher || print -r -- direct
      ;;
    direct|watcher) print -r -- "$UPSCAYL_MODE" ;;
    *) die "invalid AI_WALLPAPERS_UPSCAYL_MODE: $UPSCAYL_MODE" ;;
  esac
}

file_mtime() {
  local file="$1"
  if stat -f %m "$file" >/dev/null 2>&1; then
    stat -f %m "$file"
  else
    stat -c %Y "$file"
  fi
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "neither sha256sum nor shasum is available"
  fi
}

verify_upscayl_model() {
  local bin="$UPSCAYL_MODELS/$UPSCAYL_MODEL.bin"
  local param="$UPSCAYL_MODELS/$UPSCAYL_MODEL.param"
  require_file "$bin"
  require_file "$param"
  upscayl_model_hashes_match || die "Upscayl model hashes do not match the configured digital-art-4x files"
}

selected_vulkan_device_record() {
  command -v vulkaninfo >/dev/null 2>&1 || return 1
  [[ "$UPSCAYL_GPU_ID" == <-> ]] || die "AI_WALLPAPERS_UPSCAYL_GPU_ID must be a numeric Vulkan device index"
  env -u DISPLAY -u WAYLAND_DISPLAY vulkaninfo --summary 2>/dev/null | awk -F= -v wanted="$UPSCAYL_GPU_ID" '
    $0 ~ "^GPU" wanted ":" { selected = 1; next }
    selected && /^GPU[0-9]+:/ { selected = 0 }
    selected && /deviceName/ { name = $2; sub(/^[[:space:]]+/, "", name) }
    selected && /deviceType/ { type = $2; sub(/^[[:space:]]+/, "", type) }
    END { if (name != "" && type != "") print name "\t" type }
  '
}

selected_hardware_vulkan_device() {
  local record device device_type
  record="$(selected_vulkan_device_record)" || return 1
  [[ -n "$record" ]] || return 1
  IFS=$'\t' read -r device device_type <<<"$record"
  [[ "$device_type" == "PHYSICAL_DEVICE_TYPE_DISCRETE_GPU" || "$device_type" == "PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU" ]] || return 1
  [[ "${device:l}" != *llvmpipe* && "${device:l}" != *lavapipe* && "${device:l}" != *swiftshader* ]] || return 1
  print -r -- "$device"
}

verify_hardware_vulkan() {
  local device
  device="$(selected_hardware_vulkan_device)" || \
    die "configured Vulkan device $UPSCAYL_GPU_ID is unavailable or is not a hardware GPU"
  info "configured hardware Vulkan device $UPSCAYL_GPU_ID: $device"
}

upscayl_model_hashes_match() {
  local bin="$UPSCAYL_MODELS/$UPSCAYL_MODEL.bin"
  local param="$UPSCAYL_MODELS/$UPSCAYL_MODEL.param"
  [[ -f "$bin" && -f "$param" ]] || return 1
  [[ "$(sha256_file "$bin")" == "$UPSCAYL_MODEL_BIN_SHA256" ]] || return 1
  [[ "$(sha256_file "$param")" == "$UPSCAYL_MODEL_PARAM_SHA256" ]] || return 1
}

image_backend() {
  if [[ "$(platform_name)" == "macos" ]] && command -v sips >/dev/null 2>&1; then
    print -r -- sips
  elif command -v magick >/dev/null 2>&1; then
    print -r -- magick
  elif command -v identify >/dev/null 2>&1 && command -v convert >/dev/null 2>&1; then
    print -r -- imagemagick6
  else
    return 1
  fi
}

image_info() {
  local image="$1"
  local backend details width height format

  require_file "$image"
  backend="$(image_backend)" || die "no supported image tool found (sips or ImageMagick)"
  case "$backend" in
    sips)
      details="$(sips -g pixelWidth -g pixelHeight -g format "$image" 2>/dev/null)" || die "unreadable image: $image"
      width="$(awk '/pixelWidth:/ { print $2 }' <<<"$details")"
      height="$(awk '/pixelHeight:/ { print $2 }' <<<"$details")"
      format="$(awk '/format:/ { print tolower($2) }' <<<"$details")"
      ;;
    magick)
      details="$(magick identify -quiet -format '%w %h %m' "$image" 2>/dev/null)" || die "unreadable image: $image"
      read -r width height format <<<"$details"
      format="${format:l}"
      ;;
    imagemagick6)
      details="$(identify -quiet -format '%w %h %m' "$image" 2>/dev/null)" || die "unreadable image: $image"
      read -r width height format <<<"$details"
      format="${format:l}"
      ;;
  esac
  [[ "$width" == <-> && "$height" == <-> ]] || die "could not read image dimensions: $image"
  print -r -- "$width $height $format"
}

convert_png_to_jpeg() {
  local png="$1" jpg="$2" backend
  backend="$(image_backend)" || die "no supported image tool found (sips or ImageMagick)"
  case "$backend" in
    sips) sips -s format jpeg -s formatOptions 95 "$png" --out "$jpg" >/dev/null ;;
    magick) magick "$png" -quality 95 "$jpg" ;;
    imagemagick6) convert "$png" -quality 95 "$jpg" ;;
  esac
}

require_png() {
  local image="$1" expected_width="${2:-}" expected_height="${3:-}"
  local width height format
  read -r width height format <<<"$(image_info "$image")"
  [[ "$format" == "png" ]] || die "expected PNG, got $format: $image"
  [[ -z "$expected_width" || "$width" == "$expected_width" ]] || die "unexpected width for $image: $width (expected $expected_width)"
  [[ -z "$expected_height" || "$height" == "$expected_height" ]] || die "unexpected height for $image: $height (expected $expected_height)"
  print -r -- "$width $height"
}

require_jpeg() {
  local image="$1" expected_width="$2" expected_height="$3"
  local width height format
  read -r width height format <<<"$(image_info "$image")"
  [[ "$format" == "jpeg" ]] || die "expected JPEG, got $format: $image"
  [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] || \
    die "unexpected dimensions for $image: ${width}x${height} (expected ${expected_width}x${expected_height})"
}

context() {
  local spotify_accepted="$(active_spotify_file)"
  local notes_file="$(active_notes_file)"
  jq -n \
    --arg run_date "$RUN_DATE" \
    --arg tag "$TAG" \
    --arg native_dir "$NATIVE_DIR" \
    --arg upscaled_dir "$UPSCALED_DIR" \
    --arg staging_dir "$STAGING_DIR" \
    --arg spotify_accepted "$spotify_accepted" \
    --arg story_file "$STORY_FILE" \
    --arg notes_file "$notes_file" \
    --arg continuity_log "$CONTINUITY_LOG" \
    '{run_date:$run_date,tag:$tag,native_dir:$native_dir,upscaled_dir:$upscaled_dir,staging_dir:$staging_dir,spotify_accepted:$spotify_accepted,story_file:$story_file,notes_file:$notes_file,continuity_log:$continuity_log}'
}

preflight() {
  require_command git
  require_command gh
  require_command jq
  require_command curl
  image_backend >/dev/null || die "no supported image tool found (sips or ImageMagick)"

  if [[ "$(resolved_upscayl_mode)" == "direct" ]]; then
    require_command "$UPSCAYL_EXECUTABLE"
    require_command timeout
    [[ "$UPSCALE_TIMEOUT_SECONDS" == <-> && "$UPSCALE_TIMEOUT_SECONDS" -gt 0 ]] || \
      die "Upscayl timeout must be a positive integer"
    [[ "$UPSCAYL_SCALE" == <-> && "$UPSCAYL_SCALE" == "4" ]] || die "Upscayl scale must be exactly 4"
    verify_upscayl_model
    verify_hardware_vulkan
  fi

  [[ -d "$REPOSITORY/.git" ]] || die "repository is missing .git: $REPOSITORY"
  [[ "$(git -C "$REPOSITORY" branch --show-current)" == "main" ]] || die "repository branch is not main"
  [[ -z "$(git -C "$REPOSITORY" status --porcelain)" ]] || die "repository worktree is not clean"
  [[ "$(git -C "$REPOSITORY" remote get-url origin)" == "$REQUIRED_ORIGIN" ]] || die "repository origin does not equal $REQUIRED_ORIGIN"

  local login local_head remote_head
  if ! login="$(gh api user --jq .login 2>&1)"; then
    if [[ "$login" == *"Could not resolve host"* || "$login" == *"connection"* || "$login" == *"network"* ]]; then
      die "network access to api.github.com failed: $login"
    fi
    die "gh api user failed: $login"
  fi
  [[ "$login" == "ianmatson" ]] || die "unexpected GitHub account: $login"
  gh auth status -h github.com >/dev/null || die "gh auth status failed"

  local_head="$(git -C "$REPOSITORY" rev-parse HEAD)"
  remote_head="$(gh api "/repos/$GITHUB_REPOSITORY/commits/main" --jq .sha)" || \
    die "could not read origin/main through the GitHub API"
  [[ "$remote_head" =~ '^[0-9a-f]{40}$' ]] || die "GitHub returned an invalid origin/main revision"
  [[ "$local_head" == "$remote_head" ]] || \
    die "repository HEAD differs from origin/main; update the checkout under supervision"
}

doctor() {
  local image_tool="missing" upscayl_path="missing" model_status=false
  local git_status=false gh_status=false disk_kib=0 vulkan_device="unavailable" vulkan_hardware=false login=""
  image_tool="$(image_backend 2>/dev/null || print -r -- missing)"
  upscayl_path="$(command -v "$UPSCAYL_EXECUTABLE" 2>/dev/null || print -r -- missing)"
  if upscayl_model_hashes_match >/dev/null 2>&1; then
    model_status=true
  fi
  [[ -d "$REPOSITORY/.git" ]] && git_status=true
  if login="$(gh api user --jq .login 2>/dev/null)" && [[ "$login" == "ianmatson" ]]; then
    gh_status=true
  fi
  if vulkan_device="$(selected_hardware_vulkan_device 2>/dev/null)"; then
    vulkan_hardware=true
  else
    vulkan_device="unavailable"
  fi
  disk_kib="$(df -Pk "$WORKSPACE_ROOT" | awk 'NR == 2 {print $4}')"

  jq -n \
    --arg platform "$(platform_name)" \
    --arg workspace_root "$WORKSPACE_ROOT" \
    --arg repository "$REPOSITORY" \
    --arg image_backend "$image_tool" \
    --arg upscayl_mode "$(resolved_upscayl_mode)" \
    --arg upscayl_executable "$upscayl_path" \
    --arg upscayl_model "$UPSCAYL_MODEL" \
    --argjson upscayl_model_verified "$model_status" \
    --arg vulkan_device "$vulkan_device" \
    --argjson vulkan_hardware "$vulkan_hardware" \
    --argjson repository_present "$git_status" \
    --argjson github_authenticated "$gh_status" \
    --argjson disk_available_kib "$disk_kib" \
    '{platform:$platform,workspace_root:$workspace_root,repository:$repository,image_backend:$image_backend,upscayl:{mode:$upscayl_mode,executable:$upscayl_executable,model:$upscayl_model,model_verified:$upscayl_model_verified,vulkan_device:$vulkan_device,vulkan_hardware:$vulkan_hardware},repository_present:$repository_present,github_authenticated:$github_authenticated,disk_available_kib:$disk_available_kib}'
}

references() {
  local candidate primary_dir="" primary_kind="" legacy=""
  local -a complete_dirs primary_files older_files style_files

  [[ -d "$NATIVE_ROOT" ]] || mkdir -p "$NATIVE_ROOT"
  [[ -d "$STYLE_ROOT" ]] || die "style-reference directory is missing: $STYLE_ROOT"

  while IFS= read -r candidate; do
    style_files+=("$candidate")
  done < <(
    find "$STYLE_ROOT" -type f \
      \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
      -print | LC_ALL=C sort
  )
  (( ${#style_files[@]} > 0 )) || die "no style references found under: $STYLE_ROOT"

  # The committed story head, including an explicit correction path, outranks
  # local folders left behind by unpublished/failed image generation.
  local committed_reference
  committed_reference="$(story_engine reference)"
  primary_dir="$(jq -r '.native_dir // empty' <<<"$committed_reference")"
  if [[ -n "$primary_dir" ]]; then
    primary_kind="committed-triptych"
    for candidate in left middle right; do
      require_file "$primary_dir/landscape-$candidate.png"
      primary_files+=("$primary_dir/landscape-$candidate.png")
    done
  fi

  while IFS= read -r candidate; do
    local directory="${candidate:h}"
    [[ "${directory:t}" == "$TAG" ]] && continue
    if [[ -f "$directory/landscape-middle.png" && -f "$directory/landscape-right.png" ]]; then
      complete_dirs+=("$directory")
    fi
  done < <(find "$NATIVE_ROOT" -mindepth 2 -maxdepth 2 -type f -name landscape-left.png -print | LC_ALL=C sort -r)

  if [[ -n "$primary_kind" ]]; then
    : # Current committed episode already selected above.
  elif (( ${#complete_dirs[@]} > 0 )); then
    primary_dir="${complete_dirs[1]}"
    primary_kind="triptych"
    primary_files=(
      "$primary_dir/landscape-left.png"
      "$primary_dir/landscape-middle.png"
      "$primary_dir/landscape-right.png"
    )
    for candidate in "${complete_dirs[@]:1:2}"; do
      older_files+=("$candidate/landscape-middle.png")
    done
  else
    local newest_epoch=0 epoch image
    while IFS= read -r image; do
      [[ "$image" == "$NATIVE_DIR"/* ]] && continue
      epoch="$(file_mtime "$image")"
      if (( epoch > newest_epoch )); then
        newest_epoch="$epoch"
        legacy="$image"
      fi
    done < <(find "$NATIVE_ROOT" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -print)

    if [[ -n "$legacy" ]]; then
      primary_kind="legacy"
      primary_files=("$legacy")
    else
      require_file "$SEED_IMAGE"
      primary_kind="seed"
      primary_files=("$SEED_IMAGE")
    fi
  fi

  local style_json primary_json older_json
  style_json="$(printf '%s\n' "${style_files[@]}" | jq -R . | jq -s .)"
  primary_json="$(printf '%s\n' "${primary_files[@]}" | jq -R . | jq -s .)"
  if (( ${#older_files[@]} > 0 )); then
    older_json="$(printf '%s\n' "${older_files[@]}" | jq -R . | jq -s .)"
  else
    older_json='[]'
  fi

  jq -n \
    --argjson style "$style_json" \
    --arg kind "$primary_kind" \
    --argjson primary "$primary_json" \
    --argjson older "$older_json" \
    '{
      style_references:$style,
      historical_context:{primary_kind:$kind,primary:$primary,older_context_references:$older},
      role_policy:{
        style_references:"exclusive source of visual style, rendering treatment, shape language, palette handling, and texture",
        historical_context:"text-only narrative and continuity context; never attach historical images to image generation"
      }
    }'
}

continuity_log() {
  if [[ -f "$CONTINUITY_LOG" ]]; then
    cat "$CONTINUITY_LOG"
  else
    info "private continuity journal has no entries yet: $CONTINUITY_LOG"
  fi
}

append_continuity_log() {
  if story_enabled; then
    die "narrative journal entries are committed through story-commit"
  fi
  local entry_file="${1:-}" content date_header tmp
  [[ -n "$entry_file" ]] || die "continuity entry file is required"
  require_input_file "$entry_file"

  content="$(awk '
    { lines[NR] = $0 }
    END {
      first = 1
      while (first <= NR && lines[first] ~ /^[[:space:]]*$/) first++
      last = NR
      while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$entry_file")"

  [[ -n "$content" ]] || die "continuity entry is empty"
  (( ${#content} >= 120 )) || die "continuity entry is too short; write one substantive paragraph"
  (( ${#content} <= 2000 )) || die "continuity entry is too long; keep it under 2000 characters"
  awk '
    /^[[:space:]]*$/ { if (seen) gap = 1; next }
    { if (gap) invalid = 1; seen = 1 }
    END { exit invalid }
  ' "$entry_file" || die "continuity entry must be one paragraph"
  ! grep -Eq '^[[:space:]]*#' "$entry_file" || die "continuity entry must not contain Markdown headings"

  date_header="## $RUN_DATE"
  if [[ -f "$CONTINUITY_LOG" ]] && grep -Fqx "$date_header" "$CONTINUITY_LOG"; then
    die "continuity journal already contains an entry for $RUN_DATE"
  fi

  mkdir -p "$PRIVATE_ROOT"
  chmod 700 "$PRIVATE_ROOT"
  tmp="$(mktemp "$PRIVATE_ROOT/.daily-continuity-log.XXXXXX")"
  if [[ -f "$CONTINUITY_LOG" ]]; then
    cat "$CONTINUITY_LOG" >"$tmp"
  else
    print -r -- "# Private wallpaper continuity journal" >"$tmp"
    print -r -- "" >>"$tmp"
    print -r -- "Agent-only narrative context. Never publish, stage, or use as a source of visual style." >>"$tmp"
  fi
  print -r -- "" >>"$tmp"
  print -r -- "$date_header" >>"$tmp"
  print -r -- "" >>"$tmp"
  print -r -- "$content" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CONTINUITY_LOG"
  print -r -- "$CONTINUITY_LOG"
}

accept_native() {
  story_engine require-prepared >/dev/null
  local slot="${1:-}" source="${2:-}" target tmp width height peer peer_width peer_height
  [[ "$slot" == "left" || "$slot" == "middle" || "$slot" == "right" ]] || \
    die "usage: pipeline.zsh accept-native left|middle|right SOURCE_PNG"
  [[ -n "$source" ]] || die "usage: pipeline.zsh accept-native left|middle|right SOURCE_PNG"
  require_input_file "$source"
  read -r width height <<<"$(require_png "$source")"
  (( width > height )) || die "native image is not landscape: $source"
  mkdir -p "$NATIVE_DIR"
  for peer in "${SLOTS[@]}"; do
    [[ "$peer" == "$slot" || ! -e "$NATIVE_DIR/landscape-$peer.png" ]] && continue
    read -r peer_width peer_height <<<"$(require_png "$NATIVE_DIR/landscape-$peer.png")"
    [[ "$width" == "$peer_width" && "$height" == "$peer_height" ]] || \
      die "native dimensions do not match accepted $peer panel"
  done
  target="$NATIVE_DIR/landscape-$slot.png"
  [[ ! -e "$target" ]] || die "refusing to overwrite native image: $target"
  tmp="$(mktemp "$NATIVE_DIR/.landscape-$slot.XXXXXX.png")"
  cp -p "$source" "$tmp"
  require_png "$tmp" "$width" "$height" >/dev/null
  chmod 644 "$tmp"
  ln "$tmp" "$target" || {
    rm -f "$tmp"
    die "refusing to overwrite native image: $target"
  }
  rm -f "$tmp"
  print -r -- "$target"
}

accept_story() {
  if story_enabled; then
    die "finalize the narrative episode; stage exports its approved caption and prose"
  fi
  local source="${1:-}" story line_count tmp
  [[ -n "$source" ]] || die "usage: pipeline.zsh accept-story SOURCE_TEXT"
  require_input_file "$source"
  story="$(<"$source")"
  line_count="$(awk 'NF { count++ } END { print count + 0 }' "$source")"
  [[ "$line_count" == "1" && -n "$story" ]] || die "story must contain exactly one non-empty line"
  (( ${#story} <= 500 )) || die "story must be at most 500 characters"
  mkdir -p "$STAGING_DIR"
  [[ ! -e "$STORY_FILE" ]] || die "refusing to overwrite story: $STORY_FILE"
  tmp="$(mktemp "$STAGING_DIR/.story.XXXXXX.txt")"
  print -r -- "$story" >"$tmp"
  chmod 644 "$tmp"
  ln "$tmp" "$STORY_FILE" || {
    rm -f "$tmp"
    die "refusing to overwrite story: $STORY_FILE"
  }
  rm -f "$tmp"
  print -r -- "$STORY_FILE"
}

validate_native() {
  local first_width="" first_height="" slot width height
  [[ -d "$NATIVE_DIR" ]] || die "native directory is missing: $NATIVE_DIR"

  for slot in "${SLOTS[@]}"; do
    read -r width height <<<"$(require_png "$NATIVE_DIR/landscape-$slot.png")"
    (( width > height )) || die "native image is not landscape: $NATIVE_DIR/landscape-$slot.png"
    if [[ -z "$first_width" ]]; then
      first_width="$width"
      first_height="$height"
    elif [[ "$width" != "$first_width" || "$height" != "$first_height" ]]; then
      die "native triptych dimensions do not match"
    fi
  done

  jq -n --arg directory "$NATIVE_DIR" --argjson width "$first_width" --argjson height "$first_height" \
    '{directory:$directory,width:$width,height:$height,files:["landscape-left.png","landscape-middle.png","landscape-right.png"]}'
}

archive_upscale() {
  local source="$1" target="$2" expected_width="$3" expected_height="$4" tmp
  require_png "$source" "$expected_width" "$expected_height" >/dev/null
  mkdir -p "${target:h}"
  [[ ! -e "$target" ]] || die "refusing to overwrite upscale: $target"
  tmp="$(mktemp "${target:h}/.${target:t}.XXXXXX")"
  cp -p "$source" "$tmp"
  require_png "$tmp" "$expected_width" "$expected_height" >/dev/null
  chmod 644 "$tmp"
  ln "$tmp" "$target" || {
    rm -f "$tmp"
    die "refusing to overwrite upscale: $target"
  }
  rm -f "$tmp"
}

preserve_watcher_artifact() {
  local source="$1" category="$2" digest destination
  [[ -e "$source" ]] || return 0
  digest="$(sha256_file "$source")"
  destination="$UPSCAYL_WORK/preserved-$category/${source:t}.$digest"
  mkdir -p "${destination:h}"
  if [[ -e "$destination" ]]; then
    [[ "$(sha256_file "$destination")" == "$digest" ]] || \
      die "preserved watcher artifact conflicts with existing file: $destination"
    rm -f "$source"
  else
    mv "$source" "$destination"
  fi
  info "preserved stale local watcher artifact: $destination"
}

write_source_digest() {
  local marker="$1" digest="$2" tmp
  if [[ -e "$marker" ]]; then
    [[ -f "$marker" && "$(<"$marker")" == "$digest" ]] || \
      die "Upscayl source digest marker conflicts with native input: $marker"
    return
  fi
  tmp="$(mktemp "${marker:h}/.${marker:t}.XXXXXX")"
  print -r -- "$digest" >"$tmp"
  chmod 644 "$tmp"
  ln "$tmp" "$marker" || {
    rm -f "$tmp"
    die "refusing to overwrite Upscayl source digest marker: $marker"
  }
  rm -f "$tmp"
}

prepare_upscayl_result() {
  local result="$1" marker="$2" native_hash="$3"
  if [[ -e "$result" ]]; then
    if [[ -f "$marker" && "$(<"$marker")" == "$native_hash" ]]; then
      return 0
    fi
    preserve_watcher_artifact "$result" outputs
    [[ -e "$marker" ]] && preserve_watcher_artifact "$marker" metadata
  elif [[ -e "$marker" ]]; then
    preserve_watcher_artifact "$marker" metadata
  fi
  return 1
}

recover_watcher_path_unit() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local service="${AI_WALLPAPERS_UPSCAYL_WATCHER_SERVICE:-wallpaper-upscayl-watcher.service}"
  local path_unit="${AI_WALLPAPERS_UPSCAYL_WATCHER_PATH_UNIT:-wallpaper-upscayl-watcher.path}"
  if systemctl --user is-failed --quiet "$service" || systemctl --user is-failed --quiet "$path_unit"; then
    info "recovering failed Upscayl watcher path unit"
    systemctl --user reset-failed "$service" "$path_unit" || die "could not reset failed Upscayl watcher units"
    systemctl --user restart "$path_unit" || die "could not restart Upscayl watcher path unit"
  fi
}

upscale_direct() {
  require_command "$UPSCAYL_EXECUTABLE"
  require_command timeout
  [[ "$UPSCALE_TIMEOUT_SECONDS" == <-> && "$UPSCALE_TIMEOUT_SECONDS" -gt 0 ]] || \
    die "Upscayl timeout must be a positive integer"
  verify_upscayl_model
  verify_hardware_vulkan
  mkdir -p "$UPSCAYL_OUTPUT" "$UPSCAYL_WORK" "$UPSCALED_DIR"

  local slot native native_hash result result_marker archived width height expected_width expected_height job_dir job_result job_log selected_device
  local -a arguments
  selected_device="$(selected_hardware_vulkan_device)"
  for slot in "${SLOTS[@]}"; do
    native="$NATIVE_DIR/landscape-$slot.png"
    native_hash="$(sha256_file "$native")"
    result="$UPSCAYL_OUTPUT/$TAG-landscape-$slot-4x.png"
    result_marker="$result.source-sha256"
    archived="$UPSCALED_DIR/landscape-$slot.png"
    read -r width height <<<"$(require_png "$native")"
    expected_width=$(( width * UPSCAYL_SCALE ))
    expected_height=$(( height * UPSCAYL_SCALE ))

    if [[ -e "$archived" ]]; then
      require_png "$archived" "$expected_width" "$expected_height" >/dev/null
      info "reusing archived upscale: $archived"
      continue
    fi
    if prepare_upscayl_result "$result" "$result_marker" "$native_hash"; then
      require_png "$result" "$expected_width" "$expected_height" >/dev/null
      info "reusing completed Upscayl result: $result"
      archive_upscale "$result" "$archived" "$expected_width" "$expected_height"
      continue
    fi

    job_dir="$(mktemp -d "$UPSCAYL_WORK/.upscayl-job.XXXXXX")"
    job_result="$job_dir/$TAG-landscape-$slot-4x.png"
    job_log="$job_dir/upscayl.log"
    arguments=(
      -i "$native"
      -o "$job_result"
      -m "$UPSCAYL_MODELS"
      -n "$UPSCAYL_MODEL"
      -s "$UPSCAYL_SCALE"
      -f png
      -v
    )
    [[ -n "$UPSCAYL_GPU_ID" ]] && arguments+=(-g "$UPSCAYL_GPU_ID")
    info "upscaling with $UPSCAYL_MODEL: $native"
    timeout --signal=TERM --kill-after=30s "$UPSCALE_TIMEOUT_SECONDS" \
      "$UPSCAYL_EXECUTABLE" "${arguments[@]}" >"$job_log" 2>&1 || {
      tail -n 40 "$job_log" >&2
      die "Upscayl failed; job preserved at $job_dir"
    }
    grep -Fqi -- "$selected_device" "$job_log" || \
      die "Upscayl did not confirm configured hardware device $UPSCAYL_GPU_ID ($selected_device); job preserved at $job_dir"
    require_png "$job_result" "$expected_width" "$expected_height" >/dev/null
    archive_upscale "$job_result" "$result" "$expected_width" "$expected_height"
    write_source_digest "$result_marker" "$native_hash"
    archive_upscale "$result" "$archived" "$expected_width" "$expected_height"
    rm -f "$job_result"
    rm -f "$job_log"
    rmdir "$job_dir"
  done
}

upscale_watcher() {
  mkdir -p "$UPSCAYL_INBOX" "$UPSCAYL_OUTPUT" "$UPSCALED_DIR"
  local slot native native_hash queued result result_marker archived stale_queued width height expected_width expected_height now
  local deadline=$(( $(date +%s) + UPSCALE_TIMEOUT_SECONDS ))

  for slot in "${SLOTS[@]}"; do
    native="$NATIVE_DIR/landscape-$slot.png"
    native_hash="$(sha256_file "$native")"
    queued="$UPSCAYL_INBOX/$TAG-landscape-$slot.png"
    result="$UPSCAYL_OUTPUT/$TAG-landscape-$slot-4x.png"
    result_marker="$result.source-sha256"
    archived="$UPSCALED_DIR/landscape-$slot.png"
    read -r width height <<<"$(require_png "$native")"
    expected_width=$(( width * 4 ))
    expected_height=$(( height * 4 ))

    if [[ -e "$archived" ]]; then
      require_png "$archived" "$expected_width" "$expected_height" >/dev/null
      info "reusing archived upscale: $archived"
      continue
    fi
    if prepare_upscayl_result "$result" "$result_marker" "$native_hash"; then
      require_png "$result" "$expected_width" "$expected_height" >/dev/null
      info "reusing completed Upscayl result: $result"
      continue
    fi
    for stale_queued in "$UPSCAYL_INBOX/$TAG-landscape-$slot-"*.png(N); do
      preserve_watcher_artifact "$stale_queued" inputs
    done
    if [[ -e "$queued" ]]; then
      require_png "$queued" "$width" "$height" >/dev/null
      if [[ "$(sha256_file "$queued")" == "$native_hash" ]]; then
        info "already queued: $queued"
      else
        preserve_watcher_artifact "$queued" inputs
        cp -p "$native" "$queued"
        info "queued: $queued"
      fi
    else
      cp -p "$native" "$queued"
      info "queued: $queued"
    fi
  done

  recover_watcher_path_unit

  for slot in "${SLOTS[@]}"; do
    native="$NATIVE_DIR/landscape-$slot.png"
    native_hash="$(sha256_file "$native")"
    result="$UPSCAYL_OUTPUT/$TAG-landscape-$slot-4x.png"
    result_marker="$result.source-sha256"
    archived="$UPSCALED_DIR/landscape-$slot.png"
    [[ -e "$archived" ]] && continue
    read -r width height <<<"$(require_png "$native")"
    expected_width=$(( width * 4 ))
    expected_height=$(( height * 4 ))
    while true; do
      if [[ -f "$result" ]] && require_png "$result" "$expected_width" "$expected_height" >/dev/null 2>&1; then
        break
      fi
      now="$(date +%s)"
      (( now < deadline )) || break
      sleep 5
    done
    [[ -f "$result" ]] || die "timed out waiting for Upscayl result: $result"
    write_source_digest "$result_marker" "$native_hash"
    archive_upscale "$result" "$archived" "$expected_width" "$expected_height"
  done
}

upscale() {
  validate_native >/dev/null
  [[ "$UPSCAYL_SCALE" == "4" ]] || die "Upscayl scale must be exactly 4"
  case "$(resolved_upscayl_mode)" in
    direct) upscale_direct ;;
    watcher) upscale_watcher ;;
  esac
  jq -n --arg directory "$UPSCALED_DIR" '{directory:$directory,files:["landscape-left.png","landscape-middle.png","landscape-right.png"]}'
}

public_validate_spotify() {
  local json_file="$1"
  local title creator type uri url playable uri_playlist_id url_playlist_id
  local page_status page_tmp public_description oembed_status oembed_tmp oembed_title oembed_provider

  require_file "$json_file"
  jq -e 'type == "object"' "$json_file" >/dev/null || die "Spotify candidate is not a JSON object: $json_file"
  title="$(jq -er '.title | select(type == "string" and length > 0)' "$json_file")" || die "Spotify candidate lacks title"
  creator="$(jq -er '.creator | select(type == "string" and length > 0)' "$json_file")" || die "Spotify candidate lacks creator"
  type="$(jq -er '.type' "$json_file")" || die "Spotify candidate lacks type"
  uri="$(jq -er '.uri' "$json_file")" || die "Spotify candidate lacks URI"
  url="$(jq -er '.url' "$json_file")" || die "Spotify candidate lacks URL"
  playable="$(jq -er '.playable_status' "$json_file")" || die "Spotify candidate lacks playback status"
  [[ "$type" == "playlist" ]] || die "Spotify result type is not playlist: $type"
  [[ "$playable" == "PLAYABLE" ]] || die "Spotify result is not PLAYABLE: $playable"
  [[ "$uri" == spotify:playlist:* ]] || die "invalid Spotify playlist URI: $uri"
  [[ "$url" == https://open.spotify.com/playlist/* ]] || die "invalid Spotify playlist URL: $url"
  uri_playlist_id="${uri#spotify:playlist:}"
  url_playlist_id="${url#https://open.spotify.com/playlist/}"
  url_playlist_id="${url_playlist_id%%\?*}"
  url_playlist_id="${url_playlist_id%%\#*}"
  url_playlist_id="${url_playlist_id%%/*}"
  [[ -n "$uri_playlist_id" && "$uri_playlist_id" != *:* && "$uri_playlist_id" != */* ]] || \
    die "invalid Spotify playlist ID in URI: $uri"
  [[ "$url_playlist_id" == "$uri_playlist_id" ]] || \
    die "Spotify playlist ID mismatch between URI and URL: '$uri_playlist_id' != '$url_playlist_id'"
  page_tmp="$(mktemp -t ai-wallpapers-spotify-page.XXXXXX)"
  page_status="$(curl -L -sS -o "$page_tmp" -w '%{http_code}' "$url")" || {
    rm -f "$page_tmp"
    die "Spotify playlist page request failed: $url"
  }
  [[ "$page_status" == "200" ]] || {
    rm -f "$page_tmp"
    die "Spotify playlist page returned HTTP $page_status: $url"
  }
  public_description="$(grep -o '<meta property="og:description" content="[^"]*"' "$page_tmp" | head -1 | sed 's/^.*content="//' || true)"
  public_description="${public_description%\"}"
  rm -f "$page_tmp"

  oembed_tmp="$(mktemp -t ai-wallpapers-spotify-oembed.XXXXXX)"
  oembed_status="$(curl -G -sS -o "$oembed_tmp" -w '%{http_code}' --data-urlencode "url=$url" https://open.spotify.com/oembed)" || {
    rm -f "$oembed_tmp"
    die "Spotify oEmbed request failed: $url"
  }
  [[ "$oembed_status" == "200" ]] || {
    rm -f "$oembed_tmp"
    die "Spotify oEmbed returned HTTP $oembed_status: $url"
  }
  oembed_title="$(jq -er '.title' "$oembed_tmp")" || {
    rm -f "$oembed_tmp"
    die "Spotify oEmbed response lacks a title"
  }
  oembed_provider="$(jq -er '.provider_name' "$oembed_tmp")" || {
    rm -f "$oembed_tmp"
    die "Spotify oEmbed response lacks a provider"
  }
  rm -f "$oembed_tmp"

  [[ "$oembed_title" == "$title" ]] || die "Spotify oEmbed title mismatch: '$oembed_title' != '$title'"
  [[ "$oembed_provider" == "Spotify" ]] || die "Spotify oEmbed provider mismatch: $oembed_provider"

  SPOTIFY_PAGE_STATUS="$page_status"
  SPOTIFY_OEMBED_STATUS="$oembed_status"
  SPOTIFY_OEMBED_TITLE="$oembed_title"
  SPOTIFY_OEMBED_PROVIDER="$oembed_provider"
  SPOTIFY_PUBLIC_DESCRIPTION="$public_description"
}

inspect_playlist() {
  local candidate="${1:-}"
  [[ -n "$candidate" ]] || die "usage: pipeline.zsh inspect-playlist CANDIDATE_JSON"
  require_input_file "$candidate"
  public_validate_spotify "$candidate"
  jq -n \
    --arg title "$(jq -r .title "$candidate")" \
    --arg creator "$(jq -r .creator "$candidate")" \
    --arg uri "$(jq -r .uri "$candidate")" \
    --arg url "$(jq -r .url "$candidate")" \
    --arg description "$SPOTIFY_PUBLIC_DESCRIPTION" \
    --argjson page "$SPOTIFY_PAGE_STATUS" \
    --argjson oembed "$SPOTIFY_OEMBED_STATUS" \
    '{title:$title,creator:$creator,uri:$uri,url:$url,public_description:$description,page_http_status:$page,oembed_http_status:$oembed,publicly_resolvable:true}'
}

accept_playlist_candidate() {
  local candidate="$1" target="$2"
  local uri url existing releases_tmp enhanced_tmp

  require_input_file "$candidate"
  [[ ! -e "$target" ]] || die "refusing to overwrite soundtrack revision: $target"
  public_validate_spotify "$candidate"
  uri="$(jq -r .uri "$candidate")"
  url="$(jq -r .url "$candidate")"

  while IFS= read -r existing; do
    if [[ "$(jq -r '.uri // ""' "$existing" 2>/dev/null)" == "$uri" ]]; then
      die "Spotify playlist URI already exists in local staging archive: $uri"
    fi
  done < <(find "$STAGING_ROOT" -type f -name spotify-playlist.json -print 2>/dev/null)

  releases_tmp="$(mktemp -t ai-wallpapers-releases.XXXXXX)"
  gh api "/repos/$GITHUB_REPOSITORY/releases?per_page=30" >"$releases_tmp"
  if jq -er --arg tag "$TAG" --arg url "$url" '[.[] | select(.tag_name != $tag) | (.body // "") | contains($url)] | any' "$releases_tmp" | grep -qx true; then
    rm -f "$releases_tmp"
    die "Spotify playlist URL already appears in a recent GitHub Release: $url"
  fi
  rm -f "$releases_tmp"

  mkdir -p "$STAGING_DIR"
  enhanced_tmp="$(mktemp "$STAGING_DIR/.spotify-accepted.XXXXXX.json")"
  jq \
    --argjson page "$SPOTIFY_PAGE_STATUS" \
    --argjson oembed "$SPOTIFY_OEMBED_STATUS" \
    --arg oembed_title "$SPOTIFY_OEMBED_TITLE" \
    --arg oembed_provider "$SPOTIFY_OEMBED_PROVIDER" \
    --arg public_description "$SPOTIFY_PUBLIC_DESCRIPTION" \
    '. + {page_http_status:$page,oembed_http_status:$oembed,oembed_title:$oembed_title,oembed_provider:$oembed_provider,public_description:$public_description}' \
    "$candidate" >"$enhanced_tmp"
  chmod 644 "$enhanced_tmp"
  ln "$enhanced_tmp" "$target" || {
    rm -f "$enhanced_tmp"
    die "refusing to overwrite soundtrack revision: $target"
  }
  rm -f "$enhanced_tmp"
  info "accepted Spotify playlist: $(jq -r .title "$target")"
  print -r -- "$target"
}

validate_playlist() {
  local candidate="${1:-}" accepted="$(active_spotify_file)"

  if [[ -f "$accepted" ]]; then
    public_validate_spotify "$accepted"
    info "reusing validated Spotify playlist: $(jq -r .title "$accepted")"
    print -r -- "$accepted"
    return
  fi

  [[ -n "$candidate" ]] || die "usage: pipeline.zsh validate-playlist CANDIDATE_JSON"
  accept_playlist_candidate "$candidate" "$SPOTIFY_BASE"
}

replace_playlist() {
  local candidate="${1:-}" current_revision next_revision target
  [[ -n "$candidate" ]] || die "usage: pipeline.zsh replace-playlist CANDIDATE_JSON"
  current_revision="$(active_revision)"
  if (( current_revision == 0 )); then
    accept_playlist_candidate "$candidate" "$SPOTIFY_BASE"
    return
  fi
  next_revision=$(( current_revision + 1 ))
  target="$(spotify_file_for_revision "$next_revision")"
  accept_playlist_candidate "$candidate" "$target"
}

stage() {
  story_engine export >/dev/null
  validate_native >/dev/null
  local revision="$(active_revision)" spotify_accepted notes_file
  (( revision > 0 )) || die "no accepted Spotify playlist exists"
  spotify_accepted="$(spotify_file_for_revision "$revision")"
  notes_file="$(notes_file_for_revision "$revision")"
  require_file "$spotify_accepted"
  public_validate_spotify "$spotify_accepted"
  require_file "$STORY_FILE"

  local story line_count slot png jpg width height expected_tmp jpg_tmp
  story="$(<"$STORY_FILE")"
  line_count="$(awk 'NF { count++ } END { print count + 0 }' "$STORY_FILE")"
  [[ "$line_count" == "1" && -n "$story" ]] || die "story.txt must contain exactly one non-empty line"

  for slot in "${SLOTS[@]}"; do
    png="$UPSCALED_DIR/landscape-$slot.png"
    jpg="$STAGING_DIR/landscape-$slot.jpg"
    read -r width height <<<"$(require_png "$png")"
    if [[ -e "$jpg" ]]; then
      require_jpeg "$jpg" "$width" "$height"
    else
      mkdir -p "$STAGING_DIR"
      jpg_tmp="$(mktemp "$STAGING_DIR/.landscape-$slot.XXXXXX.jpg")"
      convert_png_to_jpeg "$png" "$jpg_tmp"
      require_jpeg "$jpg_tmp" "$width" "$height"
      chmod 644 "$jpg_tmp"
      ln "$jpg_tmp" "$jpg" || {
        rm -f "$jpg_tmp"
        die "refusing to overwrite staged JPEG: $jpg"
      }
      rm -f "$jpg_tmp"
    fi
  done

  mkdir -p "$STAGING_DIR"
  expected_tmp="$(mktemp "$STAGING_DIR/.release-notes.XXXXXX.txt")"
  {
    print -r -- "$story"
    print
    if [[ -f "$EPISODE_FILE" ]]; then
      cat "$EPISODE_FILE"
      print
    fi
    print -r -- "| Left | Middle | Right |"
    print -r -- "|:---:|:---:|:---:|"
    print -r -- "| ![Left panel](https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/landscape-left.jpg) | ![Middle panel](https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/landscape-middle.jpg) | ![Right panel](https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/landscape-right.jpg) |"
    print
    print -r -- "🎧 **Soundtrack:** $(jq -r .title "$spotify_accepted") — $(jq -r .creator "$spotify_accepted") · [Open in Spotify]($(jq -r .url "$spotify_accepted"))"
    print -r -- "**Spotify app URI:** \`$(jq -r .uri "$spotify_accepted")\`"
  } >"$expected_tmp"

  if [[ -e "$notes_file" ]]; then
    cmp -s "$expected_tmp" "$notes_file" || {
      rm -f "$expected_tmp"
      die "existing release notes differ from deterministic output: $notes_file"
    }
    rm -f "$expected_tmp"
  else
    chmod 644 "$expected_tmp"
    ln "$expected_tmp" "$notes_file" || {
      rm -f "$expected_tmp"
      die "refusing to overwrite release notes: $notes_file"
    }
    rm -f "$expected_tmp"
  fi

  jq -n --arg directory "$STAGING_DIR" --arg notes "$notes_file" --argjson soundtrack_revision "$revision" \
    '{directory:$directory,notes:$notes,soundtrack_revision:$soundtrack_revision,assets:["landscape-left.jpg","landscape-middle.jpg","landscape-right.jpg"]}'
}

validate_release() {
  local revision="$(active_revision)" spotify_accepted notes_file
  (( revision > 0 )) || die "no accepted Spotify playlist exists"
  spotify_accepted="$(spotify_file_for_revision "$revision")"
  notes_file="$(notes_file_for_revision "$revision")"
  require_file "$notes_file"
  require_file "$spotify_accepted"
  local release_json body latest slot asset_url spotify_url spotify_uri local_asset remote_asset
  local width height format remote_width remote_height remote_format remote_metadata
  local local_hash remote_hash http_status
  release_json="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json url,tagName,assets,body)" || die "GitHub Release does not exist: $TAG"
  [[ "$(jq -r .tagName <<<"$release_json")" == "$TAG" ]] || die "release tag mismatch"
  jq -e '.assets | map(.name) | sort == ["landscape-left.jpg","landscape-middle.jpg","landscape-right.jpg"]' <<<"$release_json" >/dev/null || \
    die "release does not have exactly the three expected assets"

  if [[ "${1:-}" != --exact ]]; then
    latest="$(gh release view --repo "$GITHUB_REPOSITORY" --json tagName --jq .tagName)"
    [[ "$latest" == "$TAG" ]] || die "latest release is $latest, expected $TAG"
  fi
  body="$(jq -r .body <<<"$release_json")"
  if story_enabled; then
    [[ "$body" == "$(<"$notes_file")" ]] || die "published story text differs from reviewed release notes"
  fi
  spotify_url="$(jq -r .url "$spotify_accepted")"
  spotify_uri="$(jq -r .uri "$spotify_accepted")"
  [[ "$body" == *"$spotify_url"* ]] || die "release body lacks exact Spotify URL"
  [[ "$body" == *"$spotify_uri"* ]] || die "release body lacks exact Spotify app URI"

  for slot in "${SLOTS[@]}"; do
    asset_url="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/landscape-$slot.jpg"
    [[ "$body" == *"$asset_url"* ]] || die "release body lacks embedded asset URL: $asset_url"
    local_asset="$STAGING_DIR/landscape-$slot.jpg"
    read -r width height format <<<"$(image_info "$local_asset")"
    [[ "$format" == "jpeg" ]] || die "expected staged JPEG: $local_asset"
    mkdir -p "$INPUT_ROOT"
    remote_asset="$(mktemp "$INPUT_ROOT/.release-asset-$slot.XXXXXX.jpg")"
    http_status="$(curl -L -sS -o "$remote_asset" -w '%{http_code}' "$asset_url")" || {
      rm -f "$remote_asset"
      die "failed to download release asset: $asset_url"
    }
    [[ "$http_status" == "200" ]] || {
      rm -f "$remote_asset"
      die "embedded asset URL does not resolve: $asset_url"
    }
    if ! remote_metadata="$(image_info "$remote_asset")"; then
      rm -f "$remote_asset"
      die "published asset is not a readable image: landscape-$slot.jpg"
    fi
    read -r remote_width remote_height remote_format <<<"$remote_metadata"
    if [[ "$remote_format" != "jpeg" || "$remote_width" != "$width" || "$remote_height" != "$height" ]]; then
      rm -f "$remote_asset"
      die "published asset format or dimensions differ from local staging: landscape-$slot.jpg"
    fi
    local_hash="$(sha256_file "$local_asset")"
    remote_hash="$(sha256_file "$remote_asset")"
    rm -f "$remote_asset"
    [[ "$remote_hash" == "$local_hash" ]] || die "published asset differs from local staged JPEG: landscape-$slot.jpg"
  done
  public_validate_spotify "$spotify_accepted"

  jq -n \
    --arg url "$(jq -r .url <<<"$release_json")" \
    --arg tag "$TAG" \
    --arg spotify_title "$(jq -r .title "$spotify_accepted")" \
    --arg spotify_url "$spotify_url" \
    --arg spotify_uri "$spotify_uri" \
    '{url:$url,tag:$tag,assets:["landscape-left.jpg","landscape-middle.jpg","landscape-right.jpg"],embedded_previews:true,spotify:{title:$spotify_title,url:$spotify_url,app_uri:$spotify_uri,publicly_validated:true}}'
}

completion_check() {
  validate_release --exact >/dev/null
  story_engine complete >/dev/null
  require_file "$CONTINUITY_LOG"
  grep -Fqx "## $RUN_DATE" "$CONTINUITY_LOG" || \
    die "private continuity journal lacks an entry for $RUN_DATE"
  jq -n --arg tag "$TAG" --arg journal "$CONTINUITY_LOG" \
    '{tag:$tag,release_valid:true,private_journal_entry:true,journal:$journal}'
}

publish() {
  stage >/dev/null
  local notes_file="$(active_notes_file)"
  story_engine freeze "$notes_file" >/dev/null
  if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    local release_json
    release_json="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets)"
    if story_enabled; then
      jq -e '(.assets | map(.name)) as $names | (($names | length) == ($names | unique | length)) and (($names - ["landscape-left.jpg","landscape-middle.jpg","landscape-right.jpg"] | length) == 0)' <<<"$release_json" >/dev/null || \
        die "existing release contains unexpected or duplicate assets"
      local slot remote_asset http_status asset_url
      local -a missing_assets
      for slot in "${SLOTS[@]}"; do
        if jq -e --arg name "landscape-$slot.jpg" '.assets | any(.name == $name)' <<<"$release_json" >/dev/null; then
          asset_url="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/landscape-$slot.jpg"
          remote_asset="$(mktemp "$INPUT_ROOT/.release-resume-$slot.XXXXXX.jpg")"
          http_status="$(curl -L -sS -o "$remote_asset" -w '%{http_code}' "$asset_url")" || {
            rm -f "$remote_asset"
            die "could not verify previously uploaded panel"
          }
          if [[ "$http_status" != 200 || "$(sha256_file "$remote_asset")" != "$(sha256_file "$STAGING_DIR/landscape-$slot.jpg")" ]]; then
            rm -f "$remote_asset"
            die "previously uploaded panel differs from the frozen episode"
          fi
          rm -f "$remote_asset"
        else
          missing_assets+=("$STAGING_DIR/landscape-$slot.jpg")
        fi
      done
      if (( ${#missing_assets[@]} > 0 )); then
        gh release upload "$TAG" "${missing_assets[@]}" --repo "$GITHUB_REPOSITORY" >/dev/null
      fi
    else
      jq -e '.assets | map(.name) | sort == ["landscape-left.jpg","landscape-middle.jpg","landscape-right.jpg"]' <<<"$release_json" >/dev/null || \
        die "existing release assets are invalid; refusing to replace them"
    fi
    gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --notes-file "$notes_file" >/dev/null
  else
    gh release create "$TAG" \
      "$STAGING_DIR/landscape-left.jpg" \
      "$STAGING_DIR/landscape-middle.jpg" \
      "$STAGING_DIR/landscape-right.jpg" \
      --repo "$GITHUB_REPOSITORY" \
      --title "Wallpaper $RUN_DATE" \
      --notes-file "$notes_file" \
      --latest >/dev/null
  fi
  validate_release --exact
}

replace_release_assets() {
  stage >/dev/null
  local notes_file="$(active_notes_file)" release_json
  release_json="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets)" || \
    die "GitHub Release does not exist: $TAG"
  jq -e '.assets | map(.name) | sort == ["landscape-left.jpg","landscape-middle.jpg","landscape-right.jpg"]' <<<"$release_json" >/dev/null || \
    die "existing release assets are invalid; refusing replacement"

  for slot in "${SLOTS[@]}"; do
    require_file "$STAGING_DIR/landscape-$slot.jpg"
  done

  gh release upload "$TAG" \
    "$STAGING_DIR/landscape-left.jpg" \
    "$STAGING_DIR/landscape-middle.jpg" \
    "$STAGING_DIR/landscape-right.jpg" \
    --repo "$GITHUB_REPOSITORY" \
    --clobber
  gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --notes-file "$notes_file" >/dev/null
  validate_release --exact
  story_engine correction "$notes_file" >/dev/null
}

usage() {
  cat <<'EOF'
Usage: producer/pipeline.zsh COMMAND [ARG]

Use wallpaper-producer [--date YYYY-MM-DD] as the entrypoint. Narrative context
and history are private author material. Future plans must never enter releases.

Commands:
  context                         Print today's paths and tag as JSON.
  doctor                          Report local readiness without printing secrets.
  preflight                       Validate Git/GitHub state, fetch, and fast-forward pull.
  references                      Print the local reference-image manifest as JSON.
  continuity-log                  Print the private, agent-only narrative continuity journal.
  append-continuity-log FILE      Append today's validated one-paragraph private journal entry.
  accept-native SLOT FILE         Validate and atomically archive one native PNG without overwrite.
  accept-story FILE               Validate and atomically archive the one-line public story.
  validate-native                 Validate today's three native PNGs.
  upscale                         Queue, wait for, validate, and archive 4x PNGs.
  inspect-playlist CANDIDATE      Show public metadata for judging a Spotify candidate.
  validate-playlist CANDIDATE     Publicly validate and accept a Spotify candidate JSON.
  replace-playlist CANDIDATE      Append a validated soundtrack revision without deleting the old one.
  stage                           Convert JPEGs and deterministically build release notes.
  publish                         Create or edit today's release, then validate it.
  replace-release-assets          Replace exactly the three assets on today's existing release, then validate.
  validate-release                Validate an already-published release without changing it.
  completion-check                Validate the release and today's private journal entry.
  story-context                   Read committed state, plan, recent episodes, and pending work.
  story-outline                   Read the full versioned plan before revising or extending it.
  story-history NUMBER            Retrieve original evidence for an older story episode.
  story-audit                     Validate the complete private revision chain.
  story-journal                   Read the legacy private journal for migration/recovery.
  story-init FILE                 Initialize from a validated existing release and baseline JSON.
  story-baseline-correction FILE  Record an evidenced migration correction before episode 1 is prepared.
  story-plan FILE                 Accept an explained outline revision against the current head.
  story-review FILE               Record a due editorial, next-arc, or next-season review.
  story-prepare FILE              Save the next planned episode before generation (leased).
  story-finalize FILE             Accept the final state and public prose after visual review (leased).
  story-commit                    Reconcile the exact release, commit state, and append journal (leased).

Judgment remains outside this script: image concepts, archive visual review, image generation,
visual QA, story writing, Spotify search, and playlist selection.
EOF
}

main() {
  local command="${1:-}"
  shift || true
  [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" || -z "$command" ]] || \
    validate_configuration
  case "$command" in
    context) context "$@" ;;
    doctor) doctor "$@" ;;
    preflight) preflight "$@" ;;
    references) references "$@" ;;
    continuity-log) continuity_log "$@" ;;
    append-continuity-log) append_continuity_log "$@" ;;
    accept-native) accept_native "$@" ;;
    accept-story) accept_story "$@" ;;
    validate-native) validate_native "$@" ;;
    upscale) upscale "$@" ;;
    inspect-playlist) inspect_playlist "$@" ;;
    validate-playlist) validate_playlist "$@" ;;
    replace-playlist) replace_playlist "$@" ;;
    stage) stage "$@" ;;
    publish) publish "$@" ;;
    replace-release-assets) replace_release_assets "$@" ;;
    validate-release) validate_release "$@" ;;
    completion-check) completion_check "$@" ;;
    story-guard) story_engine guard ;;
    story-context) story_engine context ;;
    story-outline) story_engine outline ;;
    story-history) story_engine history "$@" ;;
    story-audit) story_engine audit ;;
    story-journal) continuity_log ;;
    story-init) story_init "$@" ;;
    story-baseline-correction) story_engine baseline-correction "$@" ;;
    story-plan) story_engine plan "$@" ;;
    story-review) story_engine review "$@" ;;
    story-prepare) story_engine prepare "$@" ;;
    story-finalize) story_finalize "$@" ;;
    story-commit) story_commit ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
