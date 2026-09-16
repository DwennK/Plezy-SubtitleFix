# Confirmed video-only interval: presentation foundation

This change adds reversible subtitle masking for an explicitly confirmed
`TimelineRegionKind.videoOnly` interval. It does **not** detect such intervals:
`TimelineTracker` still has no automatic gap learner. Consequently this is not
proof of automatic scene-addition handling or a correction for Mentalist.

## Behavior

- Mask the selected subtitle before removing its former delay inside the gap.
- Apply the next known delay before releasing the mask on exit.
- Unknown regions retain normal subtitle visibility.
- Keep the viewer's visibility preference separate from the temporary mask.
  Manual hide/show remains meaningful during a mask and survives its release.
- Serialize visibility writes; commit ownership only after successful writes.
  Read the initial native setting, including custom configuration, rather than
  assuming the subtitles were visible.
- Release on disable, discontinuity, track change and fatal capture/control
  failure. Cleanup also attempts release when clearing the delay throws, and
  reports failure until an explicit retry succeeds. Obsolete generations cannot
  release a newer generation's mask after an awaited cleanup operation.

## Validation and limits

Local macOS Dart validation: 145 feature/player tests pass and whole-project
`flutter analyze` reports no issues. Tests include queued manual changes,
missing native state, failed release/retry and controller cleanup failures.
These use a mocked platform channel and do not prove renderer pixels.

The Windows renderer harness now captures 13 states, including temporary masks,
manual show/hide during masks, release and restored selection/manual delay.
It asserts native properties and retains screenshots for visual review.
**The extended native renderer run is pending.** `sub-text` alone is not visual
proof: mpv still decodes selected subtitles when `sub-visibility` is disabled.

Automatic gap detection, removed scenes, cues crossing boundaries, real-film
native gap playback, macOS UI, and Mentalist remain unvalidated. The mask is not
inferred from silence, missing recognition or a single offset jump.
