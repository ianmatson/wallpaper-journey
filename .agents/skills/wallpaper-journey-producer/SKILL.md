---
name: wallpaper-journey-producer
description: Produce, validate, publish, or rehearse the daily Wallpaper Journey triptych and soundtrack from the local Linux workspace.
---

# Wallpaper Journey producer

Use this skill for an explicitly requested or scheduled production run, an isolated rehearsal, or validation and repair of today's release.

For every deterministic operation, use only `/home/ian/Documents/Codex/wallpaper-journey/ai-wallpapers/producer/wallpaper-producer`. It owns configuration, leases, immutable archives, upscaling, validation, publishing, and completion checks.

## Boundaries

- Production and publication require explicit authorization in the current request. A rehearsal uses only the isolated fixture and never publishes.
- Never bypass the wrapper, edit its archives directly, operate Upscayl, Vulkan, or the watcher, request broad host access, touch `consumer/` or the desktop wallpaper, or author repository changes during production.
- Obey wrapper conflicts. Never replace accepted artifacts. On failure, preserve the lease and artifacts and report the failed phase.
- The continuity journal is private narrative context. Never quote, attach, stage, publish, or otherwise expose it.
- Published GitHub Releases and their tags are permanent. Never prune them. Cleanup is local-only and remains governed by the local consumer or an explicit owner-approved local retention policy.
- Dedicated style references are the exclusive visual inputs to image generation. Previous journey images and the private journal may inform text-only continuity and recurring-element identity, but never attach either to image generation.
- Preserve the reference finish: smooth clean graphic digital landscape illustration; crisp designed silhouettes; simplified confident geometric forms; layered atmospheric planes; broad controlled color shapes; elegant flat-to-soft gradients; restrained selective detail; and clean edges. Reject photoreal or cinematic matte rendering and pervasive cellular, pebble, stipple, mosaic, impasto, canvas, crackle, dither, brush-grain, painterly-noise, or micro-detail textures.
- Choose an existing public Spotify playlist and preserve its exact returned metadata and URL. Never create a playlist or reconstruct its metadata.

## Production

1. Read `story-context` before choosing a run date. Resume its pending episode or oldest open run using `--date YYYY-MM-DD` and the exact owning run ID, including after midnight. Otherwise acquire today's lease. Run `preflight` and `context`; if that date is complete, validate and report it without regenerating. Finish an older run before starting today's episode.
2. Read the private committed state, next episode plan, recent history, and `references`. Retrieve relevant older evidence with `story-history NUMBER`; the baseline is episode 0. Follow the planned season ending, character destinations, arc resolutions, and setup/payoff dependencies. Before an arc's detailed episodes run out, use `story-outline` and `story-plan` to extend the next arc; preserve established events and explain changes to planted promises. See [narrative inputs and recovery](../../../producer/NARRATIVE.md) when preparing or revising state.
   - Exploration and drama have equal weight across an arc; character development leads mystery slightly. Test themes through choices and consequences. Plan observation, rest, disagreement, and aftermath as well as discoveries. A new destination or major emotional change is not required every day.
   - Continue the existing journey. The cast, relationships, goals, and the journey's direction may evolve through planned, depicted events. Derive recurring-element counts from current state and today's arrivals/departures; retain departed characters in history. Introduce previously unknown names, motives, and visual signatures through upcoming scenes, without inventing retrospective evidence.
   - Keep world truth, character beliefs/knowledge, and audience knowledge distinct. Future outlines are intentions, not memories. Save `story-prepare FILE` before generation, with the proposed state changes, their causes and visible expressions, and separately authored public caption/prose. Preserve that pending episode on failure.
3. Create the triptych as three adjacent crops of one continuous wide scene:
   - Before generation, plan each tile's role and joins, shared camera and perspective, lighting, what changes or stays fixed, and the total and per-tile allocation of recurring elements.
   - Generate the middle first. Accept it only when the composition works and both edges offer plausible continuations without awkwardly cutting important subjects.
   - Base each side prompt on the accepted middle's observed horizon, perspective, lighting, scale, edge geometry, and connecting features—not only on the original plan.
   - Always supply the middle as a clearly labeled spatial reference; add a crop of the relevant middle edge when useful. Generated panels are spatial references only. Dedicated style references remain the exclusive style source; express historical identity only in text.
   - For each side, state briefly what stays fixed, what crosses the seam, what is new, and what must not be duplicated.
   - Generate sides sequentially and inspect the assembled panorama after each candidate. Give the accepted panorama-so-far as context for the final side.
   - Accept panels only from the assembled triptych view. Check scene continuity, perspective, lighting, counts, recurring-element identity, tile distinctness, seam logic, text, logos, watermarks, the clean graphic finish, and prohibited texture drift. Regenerate a failed side with one targeted correction.
   Save candidates under the workspace `tmp/` directory, accept them through the wrapper, run `validate-native`, then `upscale` and inspect the results.
4. Reconcile proposed changes with the accepted panorama and public text. Important development and each setup/payoff need specific image or prose evidence. Use `story-finalize FILE` with concise review findings for continuity, character evidence, knowledge, setup/payoff, and privacy. Include one public story sentence and 80–150 words of public episode prose; both are newly written audience-facing material, never excerpts from private records. Keep wonder and warmth alongside meaningful setbacks and lasting consequences; major losses/departures follow the season plan.
5. Select and validate a scene-appropriate Spotify playlist using exact public metadata. `stage` exports only the approved caption/prose and builds release notes. Inspect those notes for privacy, then `publish`. Publication freezes the episode's files before upload. If upload was incomplete, rerun `publish` for the same frozen episode; it verifies existing panels and uploads only missing ones. Once upload succeeds, run or resume `story-commit` to validate the exact release, commit story state once, and append the journal. Run `completion-check`, then `end-run`; both narrative commit and journal presence must validate. Dates at or before the migration baseline retain the legacy completion procedure.

On success, report the native, upscaled, and staging directories; release URL and asset names; Spotify title and public URL; story sentence and public episode passage; preview validation; committed episode number; and only whether the private journal entry exists. Keep future outlines and private state out of reports.
