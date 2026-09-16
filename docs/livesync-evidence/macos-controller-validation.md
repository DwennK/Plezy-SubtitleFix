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
