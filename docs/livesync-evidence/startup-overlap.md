# Prepare capture during complete-SRT loading

The production controller previously waited for a complete SRT, then loaded the
model and opened capture, then waited for enough recent dialogue. The private
Plex extraction observed earlier took 80.404 seconds before those later stages.
That measurement is historical and is not a benchmark of this change.

This change prepares the complete subtitle index/cache and the model/capture
concurrently. While subtitles are loading, capture uses its existing bounded
PCM ring from active playback; no inference runs until the complete index is
ready. No second media stream or full-episode audio analysis is introduced.
A failed prerequisite cancels its sibling and joins/cleans up an opened capture
before returning. Disable and track changes invalidate the generation and cancel
both pending preparations. The first failure keeps its original typed reason.

The UI shows model preparation while that work is pending, then subtitle
loading if extraction is still pending. Analyzing starts only when both inputs
are ready. This does not shorten Plex's own extraction and does not prove the
Mentalist session is fixed.

## Evidence and remaining verification

Eight deterministic tests cover overlap, both completion orders, cancellation,
late capture creation, teardown waiting, and original/cleanup error propagation.
Whole-project analysis passes locally. Full feature regression results are
recorded alongside the commit/run evidence.

The production native probe has an opt-in 15-second loopback SRT delay. It
requires capture to open before the complete text arrives and at least eight
seconds of real PCM to be buffered on startup. The fixture still must acquire
the expected offset and pass seek, manual-delay, audio-delay, cache and disable
checks. It does not alter acquisition/accuracy thresholds.

Native delayed-source validation is pending. A successful synthetic source-delay
test would prove concurrent startup, not live Plex extraction speed or audible
Mentalist synchronization. No application containing this change is installed.

## Subsequent result

Subsequent result: run 35101753081 passed the 15-second delayed-source scenario at 41dba5c5; see startup-41dba5c5-windows.json. The combined code was promoted through PR #2 after its own startup-seek checks. Mentalist remains unvalidated.
