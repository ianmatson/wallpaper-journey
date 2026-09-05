# Narrative state

Use `wallpaper-producer` for all operations. Private state lives under the configured
private root in `narrative/`; it never enters the repository or release staging.
`story-context` supplies current state, broad remaining season beats, the next five
episode plans, recent events, older evidence references, and unfinished run ownership.
`story-outline` returns the full plan when extending or revising it.

## Authoring an episode

Save input JSON under the configured input root (normally workspace `tmp/`) with
mode 0600. Start from the state and revision returned by `story-context`.

```json
{
  "base_revision": "the current revision returned by the wrapper",
  "number": 1,
  "beat": "the planned beat ID for this episode",
  "public": {"caption": "One public sentence.", "prose": "80 to 150 words of original public episode prose."},
  "after": {"characters": {}, "facts": {}, "threads": {}},
  "changes": [{"collection": "characters", "id": "stable-id", "reason": "The event that caused this change.", "expression": "Where the viewer sees or reads it.", "channel": "image"}],
  "purpose": {"journey": "...", "character": "...", "theme": "...", "continuity": "..."},
  "journal": "One private retrospective paragraph, 120 to 2000 characters.",
  "promise_evidence": {"a-planted-or-paid-off-promise-id": "Its specific expression in today's image or public prose."},
  "review": {"panorama": "...", "character_evidence": "...", "knowledge": "...", "setup_payoff": "...", "privacy": "..."}
}
```

The `after` object is the complete current state with today's changes applied.
Each record has `description` and `status`. Character records also have `name`,
`name_revealed` (boolean), `visual`, `desire`, `belief`, and `relationships` (other
character IDs mapped to prose). Fact records distinguish `audience_knows` (boolean)
and `known_by` (character IDs). A character's belief can be mistaken; a fact's
description records established author truth. Unknown facts stay explicitly unknown.
Threads record current tensions/questions and their status, not future answers.

Preserve existing IDs and `_episodes` provenance. Never delete a departed character
or a superseded fact: update its status and explain the transition. Every changed
record requires one `changes` entry. `channel` is `image`, `prose`, or `author`;
character/thread development must use image or prose. Private author knowledge
alone does not establish that the viewer understands a development.

`story-prepare FILE` saves intentions before image generation. `story-finalize FILE`
accepts the reconciled result after native validation and visual review; only final
inputs need `review` and evidence for every planned setup/payoff. A quiet episode
may have no state changes, but still needs a concrete purpose. Don't manufacture
development to populate a field. Write public prose independently; never copy a
private paragraph into it.

## Planning ahead

The foundation records standing creative boundaries. The plan contains `season`,
`theme`, `ending`, and `character_destinations` prose; `arcs` keyed by stable IDs
with `objective`, `conflict`, and `resolution`; and `beats` keyed by stable IDs with
`arc`, `purpose`, and `requires` (prior beat IDs).

`promises` maps IDs to `setup`, `payoff`, and `target_beat`. `episodes` is an ordered
list of detailed episode plans: `number`, `beat`, `purpose`, `visible_action`,
`completes_beat` (boolean), `plants` and `pays_off` (promise IDs). Extra authored
planning notes are permitted. Plan a season broadly and the current arc fully;
extend the next arc before its first episode. Endings and character destinations
are planned deliberately. Completed episode count governs pacing, not elapsed days.

For `story-plan FILE`, provide `base_revision`, the full updated `plan`, and `reason`.
If a planted promise or its scheduled payoff changes, add `promise_impacts` mapping
its ID to how existing setup will still be honored. A beat cannot close with an
unpaid promise assigned to it. Completed episode plans/beats cannot be rewritten;
planted promises cannot be removed. Retain older definitions when adding another
season. The daily context filters completed material; original history stays
retrievable. Finish any pending episode before revising its outline.

## Commit and recovery

`stage` exports approved public text. `publish` durably freezes the intended files
before contacting GitHub. `story-commit` verifies the exact release (including full
public text and image digests), then stores the next immutable snapshot, atomically
advances `CURRENT`, and appends the matching journal paragraph. A pending record
remains until all steps finish. Identical retries are safe; different files stop.
The journal is a readable projection; immutable snapshots are authoritative.

Use `story-context` to discover an unfinished date and run ID, then
`wallpaper-producer --date YYYY-MM-DD --run-id RUN_ID ...`. If upload is incomplete,
rerun `publish` for the same frozen episode: existing panels are verified and only
missing panels are uploaded. If upload succeeded but local commit failed, resume
`story-commit`. Do not regenerate, discard leases,
delete pending records, or infer completion from the calendar. A later day cannot
start while another date owns an unfinished lease. `completion-check` and
`end-run` require the state commit and journal. Revisions of published artwork or
soundtracks keep the same episode number; they do not advance the narrative.

`story-audit` verifies the reachable revision chain and contiguous episode history.
`story-history NUMBER` retrieves an original episode, with 0 reserved for migration
evidence. Keep private state and its revision history in the owner's private backup
process alongside the existing journal. Local immutable records are not an off-host backup.

## Baseline and tests

`story-init FILE` validates the existing release for the selected date, then accepts
`baseline_date`, `foundation`, `state`, `plan`, and `evidence`. The baseline date is
not a new episode. Preserve published facts and journal evidence, distinguish
unknown character identities/motives from upcoming introductions, and retain the
legacy journal. Existing releases are never backfilled with new fiction.

Before the first episode is prepared, a migration error can be corrected with
`story-baseline-correction FILE`: supply `base_revision`, corrected full `state`,
and an evidence-based `reason`. This appends a revision and retains the original
baseline. It is unavailable once episodic production begins.

Run `python3 tests/narrative-state.py` and `zsh tests/linux-producer.zsh` before
activation. They exercise a three-week synthetic arc, arrivals/departures, knowledge,
payoff ordering, immutable history, interrupted commits, public/private separation,
and the wrapper's complete stubbed publication/recovery flow. They do not assess
real ImageGen composition or prove that prose earns an emotional payoff.
