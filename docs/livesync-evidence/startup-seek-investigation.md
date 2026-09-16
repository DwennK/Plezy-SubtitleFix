# Seek while startup awaits player properties

Candidate: the combined scene-visibility and concurrent-startup changes.
Local validation: 153 feature/player tests pass; full Flutter analysis and the
changed Windows workflow's actionlint pass.

## Hypothesis to reproduce

After `_worker` receives the prepared capture owner, `_start` awaits native
status/player properties before creating its periodic timer. A real seek can
advance `_generation` in `_reset` during this interval. `_start` then returns
because its generation is stale, although the new generation still needs its
periodic analysis timer. This is a suspected startup-liveness defect, not yet a
confirmed native reproduction.

The opt-in `LIVESYNC_SEEK_DURING_STARTUP` probe issues a real player seek at the
`startupReadyMs` diagnostic event, while startup is still in progress. It keeps
the existing acquisition and accuracy gates. Success requires acquiring the
expected automatic offset after that seek and completing the usual controls,
cache and cleanup checks. The no-delay source case isolates this race from the
separate delayed-SRT experiment.

No production fix is included in this test commit. Retain its exact source SHA
and native outcome before changing the startup ordering. A fixture failure for
another reason does not confirm this hypothesis.
