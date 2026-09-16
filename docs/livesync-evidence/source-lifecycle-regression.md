# Plex source binding after native open

Mentalist S2 E16 on the installed `0d2482fb` Mac Release build renders video
and the selected English SRT, but LiveSync activation immediately reports
Unsupported / Select an accessible SRT subtitle track.

Initial playback publishes the session before calling `PlayerNative.open`.
Publishing used to install the Plex subtitle provider and server cache identity.
`open` deliberately clears the prior media's provider and restores a local
identity, so both new server bindings were lost. This prevents the real screen
from reaching extraction even though the isolated production source loader
successfully returns 57,067 bytes in 48,983 ms on this episode.

The shared resolved-open path now attaches the final session after native open
and any sidecar fallback, behind the current-attempt guard and before track
setup. Session publication/reporting timing is unchanged. Native open still
clears the prior source, and stale/failed opens do not attach a replacement.

Validation:
- New screen regression uses the actual PlayerNative open lifecycle with mocked
  native channels and a Plex-typed client. It asserts no provider at loadfile,
  then a provider on the active player after open.
- On the maintained baseline it fails with one successful loadfile and no
  remaining provider; with the patch it passes.
- An initial concurrent suite attempt timed out before loadfile while compiling
  the native app. The unchanged test passes in the serial focused suite; no
  product timing or test timeout was enlarged.
- Full Flutter analysis passes. Native Mac build/UI validation is pending.

No private PCM, transcript, subtitle text, token, or server URL is retained in
this report. Extraction alone is not synchronization or an acoustic reference.
