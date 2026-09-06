# Producer operator reference

This is human-facing setup and recovery documentation. Routine scheduled production loads the project skill and uses the wrapper help; it does not require this file as model context.

`wallpaper-producer` is the only production entrypoint. It loads the owner-only configuration, acquires a per-date lease and command lock, and delegates deterministic work to `pipeline.zsh`. Do not invoke the pipeline directly in production.

## Configuration

Copy `wallpaper.env.example` outside the public repository, replace its placeholders with absolute paths, and set mode `0600`. Store the fine-grained GitHub token in the separately configured token file, also outside the repository and mode `0600`; never put the token in the environment file, prompts, logs, or repository.

The wrapper rejects unsafe ownership, permissions, paths, dates, overlapping runtime roots, unexpected Git state, or the wrong GitHub identity. Agent-created inputs are accepted only from `AI_WALLPAPERS_INPUT_ROOT`.

Current Linux production intentionally uses watcher-mode upscaling. The wrapper associates each canonical watcher result with the native panel digest, preserves an unverified or mismatched same-date result under the local work tree, waits within the configured timeout, validates exact 4x dimensions, and atomically archives the matching result. This prevents a corrected panel from reusing an older same-date result while retaining failed local artifacts for diagnosis. Operators and agents must not start or control the watcher, Vulkan, or Upscayl directly. Direct mode remains available for configured hosts and isolated tests.

## Run lifecycle

Narrative production first reads `story-context`, resumes its unfinished date/run,
and follows the versioned episode plan. The leased sequence is `story-prepare`,
image acceptance/upscale/review, `story-finalize`, playlist validation, `stage`,
`publish`, `story-commit`, `completion-check`, and `end-run`. The public release
includes a caption and 80–150 words of episode prose. `story-commit` owns the private
journal append. See [narrative state](NARRATIVE.md) for input shapes, plan revisions,
and exact-release recovery after midnight. The existing cast and journey may evolve
through planned events; previous members and their consequences remain in history.

The same daily run also services `story-context.planning.due`: editorial review
every seven completed episodes, full next-arc detail with seven episodes remaining,
and the next season's broad outline before the final arc begins. `story-review`
records completion durably; an unchanged outline is a valid outcome. Due checkpoints
must be resolved before preparing another episode and never block interrupted-run recovery.

The following sequence is retained for dates at or before the migration baseline:

```sh
producer/wallpaper-producer begin-run RUN_ID
producer/wallpaper-producer --run-id RUN_ID preflight
producer/wallpaper-producer --run-id RUN_ID context
producer/wallpaper-producer --run-id RUN_ID references
producer/wallpaper-producer --run-id RUN_ID continuity-log
# generate and accept images, story, and playlist through the remaining commands
producer/wallpaper-producer --run-id RUN_ID stage
producer/wallpaper-producer --run-id RUN_ID publish
producer/wallpaper-producer --run-id RUN_ID append-continuity-log FILE
producer/wallpaper-producer --run-id RUN_ID completion-check
producer/wallpaper-producer end-run RUN_ID
```

Every workflow command requires the owning run ID. If a lease already exists, resume that exact ID. A failed run deliberately keeps its lease and accepted artifacts. `end-run` independently repeats the completion check and releases the lease only after the public release and today's private journal entry validate.

Run `producer/wallpaper-producer help` for the complete command list. Routine commands validate and reuse existing artifacts or stop on conflicts; they do not overwrite native, upscaled, staged, soundtrack, or journal records.

## Responsibilities and privacy

The agent supplies visual judgment, image generation and review, the public story sentence, and selection of an existing public Spotify playlist. The wrapper handles paths, immutable acceptance, image validation, upscaling, release notes, GitHub publication, public Spotify validation, release-asset digest checks, append-only journaling, and final completion. Published GitHub Releases and their tags are permanent: the producer never prunes them. Local consumer cache cleanup remains consumer-managed.

`references` separates dedicated style references from prior journey images. Dedicated style references are the exclusive visual inputs to image generation. Prior journey images and the private journal may inform text-only continuity and recurring-element identity, but must never be attached to image generation or control the new scene's composition or rendering style.

The continuity journal is stored outside the public repository and staging tree. It is append-only by date and must never be quoted, staged, uploaded, or attached to image generation.

## Recovery and validation

Soundtrack rerolls use `replace-playlist`, followed by `stage` and `publish`; prior revisions remain archived. Supervised image corrections use revision roots and `replace-release-assets`, which requires and revalidates exactly the three expected release assets.

Run `python3 tests/narrative-state.py` and `zsh tests/linux-producer.zsh` from the repository root for isolated state and publication fixtures, and `producer/wallpaper-producer doctor` for read-only host readiness. The fixtures must pass before production changes are activated.
