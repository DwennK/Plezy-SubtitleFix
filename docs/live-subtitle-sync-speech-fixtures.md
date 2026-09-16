# Real-speech cadence development fixtures

Sintel's 100–175 second calibration slice contains dialogue cue starts from
107.25 to 152.95 seconds, shorter than the learner's minimum 60-second baseline
for slope estimation. It cannot establish that the affine learner works with
real speech over that baseline.

The additional source is the first reviewed chapter of
[LibriSpeech dev-clean (OpenSLR 12)](https://www.openslr.org/12), chapter
`1272/128104`, 15 original utterances totaling 145.195 seconds. Attribution:
LibriSpeech (c) 2014 by Vassil Panayotov, derived from LibriVox audiobooks;
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The source license is
copied into every generated fixture. These are development clips and may be
used to adjust the implementation; never describe them as independent validation.
Read speech also does not represent a film's music, overlapping actors or effects.

The complete archive is pinned by size and SHA-256 in
`test/fixtures/livesync/librispeech-development.json`. The original download was
also checked against the provider's MD5 list. The generator reads only the
specified regular-file members, rejects a changed archive, and neither extracts
arbitrary paths nor replaces source files.

```sh
python3 scripts/livesync/create_speech_fixture.py \
  --archive /path/to/verified/dev-clean.tar.gz \
  --output build/livesync/speech-drift-slower \
  --case drift-slower
```

`aligned` preserves original timing; `drift-slower` uses slope `25025/24000`
(25 versus 24000/1001 fps), and `drift-faster` uses its inverse. FFmpeg's atempo
filter preserves pitch. Its overlap/add grains can cause a small discrepancy
from the ideal affine duration; provenance records this, and the generator
rejects an endpoint discrepancy exceeding 200 ms. CLI FFmpeg versions and output
hashes are recorded separately from the player's pinned native FFmpeg build.

Caption text is the unchanged official utterance transcription. Cue boundaries
come from cumulative FLAC sample counts at 16 kHz, rounded once to SRT
milliseconds. **These are utterance file boundaries, not manually annotated
acoustic word onsets.** The generated black video is only a native-renderer
container, not a representative video-performance workload.

## Full-playback tracking probe

```sh
dart run tool/livesync_native_engine_probe.dart \
  --mpv /path/to/pinned/libmpv \
  --capture /path/to/livesync_capture_bridge \
  --inference /path/to/livesync_inference_bridge \
  --model /path/to/verified/model.bin \
  --audio build/livesync/speech-drift-slower/fixture.wav \
  --srt build/livesync/speech-drift-slower/fixture.srt \
  --track-timeline true --expected-slope 1.0427083333333333 \
  --expected-offset 0 --maximum-error 0.75 --analysis-seconds 150 \
  --output build/livesync/evidence/speech-drift-slower.json
```

The probe runs the shared matcher, tracker, activity detector and cadence on
actual active-playback PCM. It updates and reads back native `sub-delay` every
500 ms, sampling error approximately once per second after the first lock.
Unknown regions contribute their actual zero automatic delay to that error;
they are not excluded to improve the result. It records first acquisition,
affine acquisition, learned regions, samples, maximum error and nearest-rank
p95. Tracking passes only with enough samples, a final mapping, the expected
slope within 0.005, and p95 below the requested timing bound.

The time samples are correlated and use the ideal fixture transform. Their p95
is an engineering regression measure, not an independent-corpus acoustic p95.
The probe is not the Flutter controller, a visible renderer check, or an audible
playback/performance test. The initial drift trial failed: no affine mapping was learned and tracking
p95 was 912 ms. A control without tempo change passed the 750 ms threshold
with 638 ms p95, but this is still biased relative to the file boundaries.
The sparse-anchor regression exposed by that run is now covered by a test.
Its first native rerun still failed after a rejected inference left an old
constant correction active (1.946 s p95). Both failures are preserved; a unit
regression fix does not establish successful native drift compensation.


With retained anchors and bounded confirmation/recovery (`8f2f7ac2`), the slower
fixture acquired a slope of 1.042619 after 117.647 s. Tracking p95 was 636.899 ms
and maximum error 682.675 ms after the first lock at 93.611 s. This development
regression passed its 750 ms bound. Initial acquisition is still too slow, and
this single result does not establish application-level or independent accuracy.


The opposite `24000/25025` case at the same revision learned slope 0.958991 at
130.563 s, leaving only 7 tracking samples before the 138 s probe ended.
It **failed** the minimum 10-sample requirement. Its 633 ms p95 on that short
interval is not sufficient tracking evidence. The local application build and
analyzer overlapped this trial; it is not a controlled acquisition benchmark.
The clip/end condition was not extended to manufacture more successful samples.


Later acquisition diagnostics and the native prefix regression are documented in
`live-subtitle-sync-validation.md` under `503d81b0`. Initial aligned acquisition
improves to 21.607 s, but earlier locking exposes a longer inaccurate constant
phase during drift. `574ef060` learns slope at 93.625 s while the full-tracking
p95 remains 2.490 s: the regression still fails. Do not replace that full result
with statistics taken only after slope acquisition.
