#!/usr/bin/env zsh

set -euo pipefail

readonly REPOSITORY="${0:A:h:h}"
readonly PIPELINE="$REPOSITORY/producer/pipeline.zsh"
readonly WRAPPER="$REPOSITORY/producer/wallpaper-producer"
readonly TEST_ROOT="$(mktemp -d -t wallpaper-producer-test.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

command -v grep >/dev/null
if grep -Fq 'gh release delete' "$PIPELINE"; then
  print -u2 -r -- 'producer must preserve published GitHub Releases and tags'
  exit 1
fi

if command -v magick >/dev/null 2>&1; then
  readonly IMAGE_COMMAND=magick
elif command -v convert >/dev/null 2>&1; then
  readonly IMAGE_COMMAND=convert
else
  print -u2 -r -- "SKIP: ImageMagick is not installed"
  exit 0
fi

mkdir -p \
  "$TEST_ROOT/bin" \
  "$TEST_ROOT/repository" \
  "$TEST_ROOT/input" \
  "$TEST_ROOT/story/native" \
  "$TEST_ROOT/story/upscaled" \
  "$TEST_ROOT/story/staging" \
  "$TEST_ROOT/story/style-references" \
  "$TEST_ROOT/story/private" \
  "$TEST_ROOT/upscayl/models" \
  "$TEST_ROOT/upscayl/work" \
  "$TEST_ROOT/upscayl/output" \
  "$TEST_ROOT/seed"

"$IMAGE_COMMAND" -size 16x9 xc:'#335577' "$TEST_ROOT/input/left.png"
"$IMAGE_COMMAND" -size 16x9 xc:'#446688' "$TEST_ROOT/input/middle.png"
"$IMAGE_COMMAND" -size 16x9 xc:'#557799' "$TEST_ROOT/input/right.png"
"$IMAGE_COMMAND" -size 16x9 xc:'#112233' "$TEST_ROOT/story/style-references/style.png"
cp "$TEST_ROOT/input/middle.png" "$TEST_ROOT/seed/digital-alpine-observatory.png"

print -r -- 'fake model binary' >"$TEST_ROOT/upscayl/models/digital-art-4x.bin"
print -r -- 'fake model parameters' >"$TEST_ROOT/upscayl/models/digital-art-4x.param"
readonly BIN_HASH="$(sha256sum "$TEST_ROOT/upscayl/models/digital-art-4x.bin" | awk '{print $1}')"
readonly PARAM_HASH="$(sha256sum "$TEST_ROOT/upscayl/models/digital-art-4x.param" | awk '{print $1}')"

cat >"$TEST_ROOT/bin/upscayl-bin" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail
local input='' output='' scale=''
while (( $# > 0 )); do
  case "$1" in
    -i) input="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    -s) scale="$2"; shift 2 ;;
    -m|-n|-f|-g) shift 2 ;;
    -v) shift ;;
    *) print -u2 -r -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ "$scale" == 4 && -f "$input" && -n "$output" ]]
if [[ "${FAKE_SOFTWARE_VULKAN:-0}" == 1 ]]; then
  print -r -- '[0 llvmpipe (Fixture Software Vulkan)]'
else
  print -r -- '[0 Fixture Hardware GPU]'
  print -r -- '[1 llvmpipe (Unused Fixture Software Vulkan)]'
fi
[[ "${FAKE_HANG:-0}" == 1 ]] && sleep 5
if command -v magick >/dev/null 2>&1; then
  magick "$input" -resize 400% "$output"
else
  convert "$input" -resize 400% "$output"
fi
EOF
chmod 700 "$TEST_ROOT/bin/upscayl-bin"

cat >"$TEST_ROOT/bin/vulkaninfo" <<'EOF'
#!/usr/bin/env zsh
print -r -- 'GPU0:'
print -r -- '    deviceName = Fixture Hardware GPU'
print -r -- '    deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU'
EOF
chmod 700 "$TEST_ROOT/bin/vulkaninfo"

print -r -- '# Fixture repository' >"$TEST_ROOT/repository/README.md"
git -C "$TEST_ROOT/repository" init -b main >/dev/null
git -C "$TEST_ROOT/repository" config user.name 'Wallpaper Fixture'
git -C "$TEST_ROOT/repository" config user.email 'fixture@example.invalid'
git -C "$TEST_ROOT/repository" add README.md
git -C "$TEST_ROOT/repository" commit -m 'Initialize fixture repository' >/dev/null
git -C "$TEST_ROOT/repository" remote add origin git@github.com:ianmatson/wallpaper-journey.git

cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail
if [[ "${1:-}" == api && "${2:-}" == user ]]; then
  print -r -- 'ianmatson'
elif [[ "${1:-}" == api && "${2:-}" == /repos/ianmatson/wallpaper-journey/commits/main ]]; then
  git -C "$FIXTURE_TEST_ROOT/repository" rev-parse HEAD
elif [[ "${1:-}" == api ]]; then
  print -r -- '[]'
elif [[ "${1:-}" == auth && "${2:-}" == status ]]; then
  exit 0
elif [[ "${1:-}" == release && "${2:-}" == create ]]; then
  tag="$3"
  notes=''
  while (( $# > 0 )); do
    if [[ "$1" == --notes-file ]]; then notes="$2"; shift 2; else shift; fi
  done
  mkdir -p "$FIXTURE_TEST_ROOT/published/$tag"
  cp "$FIXTURE_TEST_ROOT/story/staging/$tag"/landscape-*.jpg "$FIXTURE_TEST_ROOT/published/$tag/"
  jq -n --arg tag "$tag" --rawfile body "$notes" \
    '{url:("https://github.com/ianmatson/wallpaper-journey/releases/tag/"+$tag),tagName:$tag,assets:[{name:"landscape-left.jpg"},{name:"landscape-middle.jpg"},{name:"landscape-right.jpg"}],body:$body}' \
    >"$FIXTURE_TEST_ROOT/published/$tag/release.json"
  if [[ "${FIXTURE_PARTIAL_UPLOAD:-0}" == 1 ]]; then
    rm "$FIXTURE_TEST_ROOT/published/$tag/landscape-middle.jpg" "$FIXTURE_TEST_ROOT/published/$tag/landscape-right.jpg"
    jq '.assets=[{name:"landscape-left.jpg"}]' "$FIXTURE_TEST_ROOT/published/$tag/release.json" >"$FIXTURE_TEST_ROOT/published/$tag/partial.json"
    mv "$FIXTURE_TEST_ROOT/published/$tag/partial.json" "$FIXTURE_TEST_ROOT/published/$tag/release.json"
    exit 73
  fi
elif [[ "${1:-}" == release && "${2:-}" == upload ]]; then
  tag="$3"
  shift 3
  for asset in "$@"; do
    if [[ "$asset" == *.jpg ]]; then
      [[ ! -e "$FIXTURE_TEST_ROOT/published/$tag/${asset:t}" ]]
      cp "$asset" "$FIXTURE_TEST_ROOT/published/$tag/"
      jq --arg name "${asset:t}" '.assets += [{name:$name}]' "$FIXTURE_TEST_ROOT/published/$tag/release.json" >"$FIXTURE_TEST_ROOT/published/$tag/upload.json"
      mv "$FIXTURE_TEST_ROOT/published/$tag/upload.json" "$FIXTURE_TEST_ROOT/published/$tag/release.json"
    fi
  done
elif [[ "${1:-}" == release && "${2:-}" == edit ]]; then
  exit 0
elif [[ "${1:-}" == release && "${2:-}" == view && "${3:-}" == wall-* && "${3:-}" != wall-2099-01-02 ]]; then
  cat "$FIXTURE_TEST_ROOT/published/$3/release.json"
elif [[ "${1:-}" == release && "${2:-}" == view && "$*" == *'url,tagName,assets,body'* ]]; then
  print -r -- '{"url":"https://github.com/ianmatson/wallpaper-journey/releases/tag/wall-2099-01-02","tagName":"wall-2099-01-02","assets":[{"name":"landscape-left.jpg"},{"name":"landscape-middle.jpg"},{"name":"landscape-right.jpg"}],"body":"https://github.com/ianmatson/wallpaper-journey/releases/download/wall-2099-01-02/landscape-left.jpg https://github.com/ianmatson/wallpaper-journey/releases/download/wall-2099-01-02/landscape-middle.jpg https://github.com/ianmatson/wallpaper-journey/releases/download/wall-2099-01-02/landscape-right.jpg https://open.spotify.com/playlist/fixture123 spotify:playlist:fixture123"}'
elif [[ "${1:-}" == release && "${2:-}" == view && "$*" == *'--json tagName'* ]]; then
  print -r -- "${FIXTURE_LATEST_TAG:-wall-2099-01-02}"
else
  exit 2
fi
EOF
chmod 700 "$TEST_ROOT/bin/gh"

cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail
local output='' is_oembed=false url='' argument
for argument in "$@"; do
  [[ "$argument" == 'https://open.spotify.com/oembed' ]] && is_oembed=true
  [[ "$argument" == https://* ]] && url="$argument"
done
while (( $# > 0 )); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]]
if [[ "$url" == https://github.com/*/releases/download/*/landscape-*.jpg ]]; then
  tag="${${url:h}:t}"
  if [[ "$tag" == wall-2099-01-02 ]]; then
    cp "$FIXTURE_TEST_ROOT/story/staging/$tag/${url:t}" "$output"
  else
    cp "$FIXTURE_TEST_ROOT/published/$tag/${url:t}" "$output"
  fi
  [[ "${FIXTURE_REMOTE_MISMATCH:-0}" == 1 ]] && print -n -r -- x >>"$output"
elif $is_oembed; then
  print -r -- '{"title":"Test Soundtrack","provider_name":"Spotify"}' >"$output"
else
  print -r -- '<meta property="og:description" content="A synthetic test playlist">' >"$output"
fi
print -n -r -- '200'
EOF
chmod 700 "$TEST_ROOT/bin/curl"

cat >"$TEST_ROOT/input/spotify.json" <<'EOF'
{"title":"Test Soundtrack","creator":"Fixture Curator","type":"playlist","uri":"spotify:playlist:fixture123","url":"https://open.spotify.com/playlist/fixture123","playable_status":"PLAYABLE","search_query":"synthetic fixture"}
EOF
print -r -- 'A blue-hour expedition crosses one continuous synthetic horizon.' >"$TEST_ROOT/input/story.txt"
print -r -- 'github_pat_fixture_token' >"$TEST_ROOT/github-token"
chmod 600 "$TEST_ROOT/github-token"

export PATH="$TEST_ROOT/bin:$PATH"
export FIXTURE_TEST_ROOT="$TEST_ROOT"
export AI_WALLPAPERS_RUN_DATE=2099-01-02
export AI_WALLPAPERS_WORKSPACE_ROOT="$TEST_ROOT"
export AI_WALLPAPERS_REPOSITORY="$TEST_ROOT/repository"
export AI_WALLPAPERS_NATIVE_ROOT="$TEST_ROOT/story/native"
export AI_WALLPAPERS_STYLE_ROOT="$TEST_ROOT/story/style-references"
export AI_WALLPAPERS_UPSCALED_ROOT="$TEST_ROOT/story/upscaled"
export AI_WALLPAPERS_STAGING_ROOT="$TEST_ROOT/story/staging"
export AI_WALLPAPERS_PRIVATE_ROOT="$TEST_ROOT/story/private"
export AI_WALLPAPERS_INPUT_ROOT="$TEST_ROOT/input"
export AI_WALLPAPERS_SEED_IMAGE="$TEST_ROOT/seed/digital-alpine-observatory.png"
export AI_WALLPAPERS_UPSCAYL_MODE=direct
export AI_WALLPAPERS_UPSCAYL_EXECUTABLE="$TEST_ROOT/bin/upscayl-bin"
export AI_WALLPAPERS_UPSCAYL_MODELS="$TEST_ROOT/upscayl/models"
export AI_WALLPAPERS_UPSCAYL_GPU_ID=0
export AI_WALLPAPERS_UPSCAYL_WORK="$TEST_ROOT/upscayl/work"
export AI_WALLPAPERS_UPSCAYL_OUTPUT="$TEST_ROOT/upscayl/output"
export AI_WALLPAPERS_UPSCAYL_MODEL_BIN_SHA256="$BIN_HASH"
export AI_WALLPAPERS_UPSCAYL_MODEL_PARAM_SHA256="$PARAM_HASH"

cat >"$TEST_ROOT/wallpaper.env" <<EOF
AI_WALLPAPERS_TIME_ZONE=America/Chicago
AI_WALLPAPERS_WORKSPACE_ROOT=$TEST_ROOT
AI_WALLPAPERS_REPOSITORY=$TEST_ROOT/repository
AI_WALLPAPERS_GITHUB_TOKEN_FILE=$TEST_ROOT/github-token
AI_WALLPAPERS_NATIVE_ROOT=$TEST_ROOT/story/native
AI_WALLPAPERS_STYLE_ROOT=$TEST_ROOT/story/style-references
AI_WALLPAPERS_UPSCALED_ROOT=$TEST_ROOT/story/upscaled
AI_WALLPAPERS_STAGING_ROOT=$TEST_ROOT/story/staging
AI_WALLPAPERS_PRIVATE_ROOT=$TEST_ROOT/story/private
AI_WALLPAPERS_INPUT_ROOT=$TEST_ROOT/input
AI_WALLPAPERS_SEED_IMAGE=$TEST_ROOT/seed/digital-alpine-observatory.png
AI_WALLPAPERS_UPSCAYL_MODE=direct
AI_WALLPAPERS_UPSCAYL_EXECUTABLE=$TEST_ROOT/bin/upscayl-bin
AI_WALLPAPERS_UPSCAYL_MODELS=$TEST_ROOT/upscayl/models
AI_WALLPAPERS_UPSCAYL_GPU_ID=0
AI_WALLPAPERS_UPSCAYL_WORK=$TEST_ROOT/upscayl/work
AI_WALLPAPERS_UPSCAYL_OUTPUT=$TEST_ROOT/upscayl/output
AI_WALLPAPERS_UPSCAYL_MODEL_BIN_SHA256=$BIN_HASH
AI_WALLPAPERS_UPSCAYL_MODEL_PARAM_SHA256=$PARAM_HASH
AI_WALLPAPERS_CONTROL_DIR=$TEST_ROOT/control/producer
EOF
chmod 600 "$TEST_ROOT/wallpaper.env"

cp "$TEST_ROOT/wallpaper.env" "$TEST_ROOT/bad-control.env"
print -r -- "AI_WALLPAPERS_CONTROL_DIR=$TEST_ROOT/repository" >>"$TEST_ROOT/bad-control.env"
chmod 600 "$TEST_ROOT/bad-control.env"
readonly REPOSITORY_MODE_BEFORE="$(stat -c %a "$TEST_ROOT/repository")"
if AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/bad-control.env" "$WRAPPER" begin-run bad-control >/dev/null 2>&1; then
  print -u2 -r -- 'expected overlapping control root rejection before lease creation'
  exit 1
fi
[[ "$(stat -c %a "$TEST_ROOT/repository")" == "$REPOSITORY_MODE_BEFORE" ]]
[[ ! -e "$TEST_ROOT/repository/wallpaper-producer-2099-01-02.lease" ]]

wrapper_run() {
  AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" --run-id fixture-run-a "$@"
}

AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" begin-run fixture-run-a | grep -qx fixture-run-a
if AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" begin-run fixture-run-b >/dev/null 2>&1; then
  print -u2 -r -- 'expected competing run lease rejection'
  exit 1
fi

wrapper_run preflight >/dev/null
wrapper_run accept-native left "$TEST_ROOT/input/left.png" >/dev/null
wrapper_run accept-native middle "$TEST_ROOT/input/middle.png" >/dev/null
wrapper_run accept-native right "$TEST_ROOT/input/right.png" >/dev/null
wrapper_run validate-native | jq -e '.width == 16 and .height == 9' >/dev/null

if wrapper_run accept-native left "$TEST_ROOT/input/left.png" >/dev/null 2>&1; then
  print -u2 -r -- 'expected native overwrite rejection'
  exit 1
fi

wrapper_run upscale | jq -e '.files | length == 3' >/dev/null
wrapper_run upscale >/dev/null
for slot in left middle right; do
  native_hash="$(sha256sum "$TEST_ROOT/story/native/wall-2099-01-02/landscape-$slot.png" | awk '{print $1}')"
  [[ -f "$TEST_ROOT/upscayl/output/wall-2099-01-02-landscape-$slot-4x.png" ]]
  [[ "$(<"$TEST_ROOT/upscayl/output/wall-2099-01-02-landscape-$slot-4x.png.source-sha256")" == "$native_hash" ]]
done
wrapper_run accept-story "$TEST_ROOT/input/story.txt" >/dev/null
wrapper_run validate-playlist "$TEST_ROOT/input/spotify.json" >/dev/null
wrapper_run stage | jq -e '.assets | length == 3' >/dev/null

for slot in left middle right; do
  identify -quiet -format '%w %h %m' "$TEST_ROOT/story/upscaled/wall-2099-01-02/landscape-$slot.png" | grep -qx '64 36 PNG'
  identify -quiet -format '%w %h %m' "$TEST_ROOT/story/staging/wall-2099-01-02/landscape-$slot.jpg" | grep -qx '64 36 JPEG'
done

mkdir -p "$TEST_ROOT/story/native/wall-2099-01-03"
for slot in left middle right; do
  cp "$TEST_ROOT/input/$slot.png" "$TEST_ROOT/story/native/wall-2099-01-03/landscape-$slot.png"
done
if FAKE_SOFTWARE_VULKAN=1 AI_WALLPAPERS_RUN_DATE=2099-01-03 "$PIPELINE" upscale >/dev/null 2>&1; then
  print -u2 -r -- 'expected software Vulkan rejection'
  exit 1
fi

mkdir -p "$TEST_ROOT/story/native/wall-2099-01-04"
for slot in left middle right; do
  cp "$TEST_ROOT/input/$slot.png" "$TEST_ROOT/story/native/wall-2099-01-04/landscape-$slot.png"
done
if FAKE_HANG=1 AI_WALLPAPERS_UPSCALE_TIMEOUT_SECONDS=1 AI_WALLPAPERS_RUN_DATE=2099-01-04 "$PIPELINE" upscale >/dev/null 2>&1; then
  print -u2 -r -- 'expected direct Upscayl timeout rejection'
  exit 1
fi
if AI_WALLPAPERS_RUN_DATE=2099-02-31 "$PIPELINE" context >/dev/null 2>&1; then
  print -u2 -r -- 'expected invalid calendar date rejection'
  exit 1
fi
if AI_WALLPAPERS_PRIVATE_ROOT="$TEST_ROOT/story/native" "$PIPELINE" context >/dev/null 2>&1; then
  print -u2 -r -- 'expected duplicate runtime root rejection'
  exit 1
fi

wrapper_run context | jq -e '.tag == "wall-2099-01-02"' >/dev/null
if FIXTURE_REMOTE_MISMATCH=1 wrapper_run validate-release >/dev/null 2>&1; then
  print -u2 -r -- 'expected published asset digest mismatch rejection'
  exit 1
fi
print -r -- 'The synthetic expedition crossed the blue horizon, left a precise signal marker beside the observatory, and opened a clear route toward tomorrow.' >"$TEST_ROOT/input/continuity.txt"
wrapper_run append-continuity-log "$TEST_ROOT/input/continuity.txt" >/dev/null
wrapper_run completion-check | jq -e '.release_valid and .private_journal_entry' >/dev/null
AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" end-run fixture-run-a | grep -qx fixture-run-a

python3 "$REPOSITORY/tests/narrative-state.py" --fixture "$TEST_ROOT" baseline
AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" story-init "$TEST_ROOT/input/baseline.json" | jq -e '.initialized' >/dev/null

narrative_run() {
  AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" --date 2099-01-05 --run-id narrative-fixture "$@"
}
AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" --date 2099-01-05 begin-run narrative-fixture >/dev/null
if AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" --date 2099-01-06 begin-run future-fixture >/dev/null 2>&1; then
  print -u2 -r -- 'expected cross-date unfinished lease rejection'
  exit 1
fi
AI_WALLPAPERS_RUN_DATE=2099-01-05 python3 "$REPOSITORY/tests/narrative-state.py" --fixture "$TEST_ROOT" episode
if narrative_run accept-native middle "$TEST_ROOT/input/middle.png" >/dev/null 2>&1; then
  print -u2 -r -- 'expected story preparation before image acceptance'
  exit 1
fi
narrative_run story-prepare "$TEST_ROOT/input/episode.json" >/dev/null
for slot in left middle right; do
  narrative_run accept-native "$slot" "$TEST_ROOT/input/$slot.png" >/dev/null
done
narrative_run upscale >/dev/null
narrative_run story-finalize "$TEST_ROOT/input/episode.json" >/dev/null
jq '.uri="spotify:playlist:fixture456" | .url="https://open.spotify.com/playlist/fixture456"' \
  "$TEST_ROOT/input/spotify.json" >"$TEST_ROOT/input/spotify-next.json"
narrative_run validate-playlist "$TEST_ROOT/input/spotify-next.json" >/dev/null
if FIXTURE_PARTIAL_UPLOAD=1 narrative_run publish >/dev/null 2>&1; then
  print -u2 -r -- 'expected simulated interrupted upload'
  exit 1
fi
narrative_run story-context | jq -e '.episode == 0 and .pending.phase == "publishing"' >/dev/null
narrative_run publish >/dev/null
if narrative_run completion-check >/dev/null 2>&1; then
  print -u2 -r -- 'expected published story to require a local narrative commit'
  exit 1
fi
if FIXTURE_REMOTE_MISMATCH=1 narrative_run story-commit >/dev/null 2>&1; then
  print -u2 -r -- 'expected digest mismatch to prevent narrative advancement'
  exit 1
fi
# Exact-release recovery works even when a different release is now latest.
FIXTURE_LATEST_TAG=wall-2099-01-06 narrative_run story-commit | jq -e '.episode == 1' >/dev/null
narrative_run story-commit | jq -e '.episode == 1' >/dev/null
narrative_run references | jq -e '.historical_context.primary_kind == "committed-triptych" and (.historical_context.primary[0] | contains("wall-2099-01-05"))' >/dev/null
narrative_run completion-check >/dev/null
AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" --date 2099-01-05 end-run narrative-fixture >/dev/null
AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" story-audit | jq -e '.story_valid and .episode == 1 and (.pending | not)' >/dev/null
if grep -qE 'Fixture season|hidden source' "$TEST_ROOT/published/wall-2099-01-05/release.json"; then
  print -u2 -r -- 'private planning material appeared in public release'
  exit 1
fi

admin_story() {
  AI_WALLPAPERS_ENV_FILE="$TEST_ROOT/wallpaper.env" "$WRAPPER" "$@"
}
admin_story story-outline >"$TEST_ROOT/input/cadence-plan.json"
python3 - "$TEST_ROOT/input/cadence-plan.json" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); source=json.loads(path.read_text()); plan=source['plan']
plan['arcs']['fixture-next']={'objective':'Continue the shared route.','conflict':'Make another shared choice.','resolution':'Retain a visible consequence.'}
plan['beats']['fixture-next']={'arc':'fixture-next','purpose':'Develop a second synthetic arc.','requires':['choice']}
plan['seasons']=[{'id':'fixture-season','title':plan['season'],'theme':plan['theme'],'ending':plan['ending'],
                 'character_destinations':plan['character_destinations'],'transition':'Continue the established synthetic journey.',
                 'arcs':[{'id':'crossing','episodes':2},{'id':'fixture-next','episodes':2}]}]
source['reason']='Enable a short synthetic cadence for wrapper integration.'
path.write_text(json.dumps(source))
PY
admin_story story-plan "$TEST_ROOT/input/cadence-plan.json" >/dev/null
admin_story story-context >"$TEST_ROOT/input/cadence-context.json"
python3 - "$TEST_ROOT/input" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); context=json.loads((root/'cadence-context.json').read_text())
assert context['planning']['due'][0]['id']=='arc-detail:fixture-next'
source={'base_revision':context['revision'],'checkpoint':'arc-detail:fixture-next','decision':'revised','evidence_episodes':[1],
        'findings':{key:'The synthetic episode supports the planned shared destination.' for key in ('pacing','characters','themes','repetition','setup_payoff','continuity')}}
(root/'cadence-review.json').write_text(json.dumps(source))
PY
if admin_story story-review "$TEST_ROOT/input/cadence-review.json" >/dev/null 2>&1; then
  print -u2 -r -- 'expected incomplete next arc to prevent planning review completion'
  exit 1
fi
admin_story story-outline >"$TEST_ROOT/input/cadence-plan.json"
python3 - "$TEST_ROOT/input/cadence-plan.json" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); source=json.loads(path.read_text())
for number in (3,4):
    source['plan']['episodes'].append({'number':number,'beat':'fixture-next','purpose':'Retain the shared choice.',
                                      'visible_action':'The travelers carry the lantern onward.','completes_beat':number==4,'plants':[],'pays_off':[]})
source['reason']='Fully detail the next synthetic arc.'
path.write_text(json.dumps(source))
PY
admin_story story-plan "$TEST_ROOT/input/cadence-plan.json" >/dev/null
admin_story story-context >"$TEST_ROOT/input/cadence-context.json"
python3 - "$TEST_ROOT/input" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); context=json.loads((root/'cadence-context.json').read_text())
path=root/'cadence-review.json'; source=json.loads(path.read_text()); source['base_revision']=context['revision']; path.write_text(json.dumps(source))
PY
admin_story story-review "$TEST_ROOT/input/cadence-review.json" | jq -e '.review_recorded' >/dev/null
admin_story story-review "$TEST_ROOT/input/cadence-review.json" | jq -e '.review_recorded' >/dev/null
admin_story story-context | jq -e '.episode == 1 and .planning.completed_reviews == 1 and (.planning.due | length == 0)' >/dev/null
admin_story story-audit | jq -e '.story_valid and .episode == 1 and (.pending | not)' >/dev/null

print -r -- 'Linux producer fixture passed'
