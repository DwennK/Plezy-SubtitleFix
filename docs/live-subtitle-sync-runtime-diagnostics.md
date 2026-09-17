# Opt-in native session diagnostics

Set `PLEZY_LIVESYNC_DIAGNOSTICS=1` only for an explicitly investigated local
session. The normal application leaves the observer unset. Restart the app to
change this option; do not open a second player for the same episode.

The controller writes lines beginning with `LIVESYNC_DIAGNOSTIC ` to stderr,
outside the application logger and its log-upload store. Each line is a JSON
object containing only allowlisted numerical measurements, booleans and fixed
status values. Unknown keys, free text, nonfinite numbers, dialogue, media URLs,
model paths and credentials are discarded. Anchor lists are capped at 64 items
and each controller emits at most 2,048 events. A failed output sink disables
further output without failing playback.

The events cover source/capture readiness, phase changes, inference and matching
durations, continuity changes, match status, anchor rejection counts, and learned
regions. Recognition and alignment thresholds are unchanged. Existing test
harnesses can still replace `diagnosticObserver` with an in-memory callback.

When collecting a session, drain both process streams but retain only the
prefixed JSON records. Never redirect the complete application output to a
diagnostic artifact: unrelated application logs are outside this schema.
Do not record audio or transcripts, and do not send these diagnostics remotely.
This option is for failure diagnosis; its additional matching counters and
output make it unsuitable as the normal performance acceptance run.

The motivating production observation is the installed aaaa67c2 build reaching
Synced on the reported episode, then showing Unable to sync at 18:08. That UI
observation does not identify whether recognition, temporal anchors, continuity,
or mapping validity caused the loss. The diagnostic session must establish that
cause before selecting another alignment change.
