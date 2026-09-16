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
