# Revalidate cached absence with fresh dialogue

Cached `videoOnly` and `subtitleOnly` intervals previously prevented every new
mapping that overlapped them. Even confirmed fresh dialogue could therefore
never replace a stale absence interval. With the scene visibility mask, that
could keep subtitles hidden in a region whose cached absence was wrong.

`TimelineTracker` now tracks restored gaps separately. The existing temporal
fitter must confirm independent cue starts inside a gap before it is removed.
Video timestamps must lie wholly inside the interval including their timing
uncertainty. Boundary noise, a repeated cue, evidence outside the interval,
and observations separated by a seek do not suffice. Direct invalidation keeps
unrelated cached intervals. This does not implement automatic gap discovery.

## Validation

Before the change, the new tests reproduced three failures: video-gap
invalidation, subtitle-gap invalidation, and fresh confirmation after a seek.
After the change, all seven gap cases and 44 existing tracker/map/cache cases
pass. The feature directory has 152 passing tests with the optional downloaded
Sintel parser case initially skipped; a subsequent run with that fixture and
both player timing/visibility suites passes all 15 tests. Full Flutter analysis
and `git diff --check` pass.

These are deterministic domain/player tests. They do not establish native scene
discovery or correction of Mentalist S2 E16. The frozen native startup candidate
`a5838cbe` does not contain this follow-up.

## Cache algorithm revision

The algorithm identity is now `bounded-affine-titles-v2`. Bounded segmented
recognition and fresh gap revalidation changed which evidence can establish or
revoke a mapping. Reusing the v1 identity would restore timings learned under
the former semantics before background validation could examine them.

The new identity changes the cache key and rejects v1 envelopes even if copied
under the new key with a valid checksum. Existing files remain subject to the
normal bounded cache retention; no subtitle source or manual delay is modified.
The explicit v1-envelope regression failed before the version change.

After the version change, all 160 feature/player tests (including the downloaded
Sintel parser case), 51 focused map/cache tests, full Flutter analysis, and
`git diff --check` pass. Native app validation of this follow-up remains pending.
