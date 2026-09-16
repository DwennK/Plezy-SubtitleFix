# Separate Debug and Release validation

The measured 52.022-second startup-seek acquisition came from a Debug Flutter
application. The native inference libraries were already built in Release mode,
but Flutter startup, model verification, isolate work and matching still ran in
the Debug application. That result remains a failed 45-second acquisition target;
this observation does not establish that Release will meet it.

The Windows workflow now accepts `build_mode=debug|release`, retaining Debug as
the compatible default for existing upstream integration. The application,
native reliability contracts, renderer and production-controller probe all use
the selected configuration. Native inference/PCM helper builds keep their
existing Release configuration. The pinned upstream patched Flutter engine
already supplies both Windows modes.

Release artifacts receive a `-release` suffix. `build-mode.json` records the
workflow configuration and the controller probe independently reports Flutter's
compile-time mode. The same PCM, model, match/confirmation thresholds, fixture,
manual controls and acquisition target remain in effect.

Actionlint and full Flutter analysis pass locally. Release execution is pending.
Comparing two hosted runs alone is not a paired hardware benchmark or evidence
of audible playback performance. User-machine budgets and Mentalist acceptance
remain separate requirements.

## macOS configuration and archive boundary

The macOS workflow also accepts debug/release, with the legacy Debug default
and artifact names preserved. Release archives and contract evidence have an
explicit `-release` suffix and a build-mode receipt. The ordinary application
is strictly signature-verified and archived before XCTest rebuilds it.

RunnerTests uses `@testable import`, so the contract build explicitly enables
Swift testability in the selected configuration. Release optimizations remain
selected, but this instrumented test host is not claimed to be byte-identical
to the ordinary archived application. The archive is never replaced by that
host. This does not prove native UI interaction or audible playback on a Mac.

Local actionlint and existing upstream orchestration checks pass. The first
macOS Release build and contract run remain pending until actually completed.
