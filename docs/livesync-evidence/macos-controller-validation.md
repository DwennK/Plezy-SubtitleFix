# Actual Mac production-controller validation

The Mac workflow previously built the ordinary app and exercised app-linked
Swift/native contracts. Those checks do not exercise Dart controller acquisition
with actual active PCM and Whisper. The Windows controller harness already does.

After archiving the ordinary Mac app and completing native contracts, build the
same dedicated Flutter controller entrypoint for macOS. Run the two existing
Sintel development fixtures: six-channel calibration and 90-second silent intro,
with a seeded incorrect cache gap. Keep the Mac production default base.en-q5_1
and the same complete SRT, PCM source and controller implementation. No new
independent corpus partition is consumed.

The runner rejects stale/partial reports, early process exits, incorrect
platform/configuration/case, missing playback-control checks, offset errors of
750 ms or more, and acquisition beyond 45 seconds plus the explicit intro.
It preserves raw reports, fixture hashes and runner outcomes on failure and
terminates only the process it created. A timeout is a failed observation;
the runner never restarts it. Seven local runner tests and actionlint pass.

This exercises a native Flutter app on a hosted arm64 Mac with null audio output.
It does not establish audible playback, manual visual inspection, Mentalist,
precise acoustic-onset accuracy, full drift or automatic scene gaps. The helper
binary is distinct from the already archived ordinary application. Actual native
execution must complete before any passing controller claim is recorded here.

## Native contract prerequisite failure

The preceding e85fd4bd Mac run `35148927428` builds and signs the ordinary app,
but one of 14 native contracts fails. The [retained report](macos-activation-race-e85fd4bd.json)
locates the first error at capture activation, followed by reads from a capture
that never enabled. The chain's disabled-state property is available before the
native PCM-format guard permits activation. Await only that transient unavailable
status within the original five-second deadline, require the enabled-state
acknowledgement, and keep the real PCM and disable assertions. Swift formatting
and a type check against the actual mpv header pass; new native execution remains
required. The workflow also exports the numeric XCTest summary after failures.

The first Mac controller workflow is run `35149938639`, source `4da5ba32`.
It retains the earlier contract and is still running; do not cancel or replace
its evidence merely because the bounded-activation test correction is now ready.
