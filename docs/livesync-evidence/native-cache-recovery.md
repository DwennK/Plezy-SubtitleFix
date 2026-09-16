# Real controller recovery from a deliberately wrong cached gap

The optional Windows input `seed_wrong_gap` enables an isolated corruption
scenario in the existing production-controller probe. It requires immediate
subtitles and disables the separate startup-seek scenario to keep attribution
clear. Existing accuracy, seek, manual/audio-delay, cache and shutdown checks
remain unchanged. The acquisition budget is reported independently.

Before activation, the probe uses the production cache writer to save a false
video-only interval covering the entire calibration excerpt (75 seconds, or
165 with the authored silent intro). A synthetic segment using valid source cue
identities lies beyond the played excerpt, satisfying the cache's structural
requirements. These deliberately authored cache records are not learned audio
evidence and do not prove automatic scene-gap discovery.

The probe requires all of the following:

1. The production cache decoder accepts the record and the controller actually
   restores its gap and segment.
2. The native subtitle visibility becomes hidden inside the restored gap.
3. Real active-playback PCM and Whisper yield the expected correction through
   the production controller, without injecting transcripts or timing anchors.
4. Native subtitle visibility returns to the viewer's visible preference.
5. The corrected cache on disk no longer has the false gap, and the unrelated
   future segment remains intact.
6. The ordinary manual-delay, audio-delay, seek, cache-reload and disable checks
   still pass.

Two local fixture tests exercise the actual cache codec for negative and positive
offsets. Whole-project analysis and actionlint pass. The native result remains
pending until the exact source run completes; unit tests alone do not prove
native recovery or Mentalist synchronization.

Local combined validation: 162 feature/player/fixture tests pass.

## Subsequent native result and promotion

The final candidate `f04d8e29` passes Windows recovery run `35109362139`,
macOS run `35109400288` (14 native contracts), Dart and upstream CI.
Both false-cache cases restore the seeded gap, hide subtitles, recover through
actual PCM/Whisper, restore visibility and remove the false interval from disk
while retaining the unrelated segment. Acquisition: 20.946 s / 122.224 s;
authored-SRT error: 198.7 / 227.6 ms. All ordinary controller checks pass.
PR #3 is promoted in `7a68ca09`; production code is identical to tested source.
[Numeric reports and remaining limits](cache-recovery-f04d8e29-windows.json).
This does not establish automatic scene discovery, independent acoustic accuracy
or Mentalist playback. The a5838cbe draft archives predate this change.
