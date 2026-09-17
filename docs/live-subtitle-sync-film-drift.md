# Film drift development matrix

The fixed public Elephants Dream media and authored English captions are pinned
in `test/fixtures/livesync/film-drift-development.json`. Only the previously
consumed 0–180 second development partition is decoded. The 360–540 second
holdout is untouched. Audio is converted to mono 16 kHz PCM for the fixture;
the native test then captures that PCM from active playback. Its video is a
neutral generated background, so this is not visual film playback validation.

Prepare each case using the existing source directory:

```sh
python3 scripts/livesync/create_film_drift_fixture.py \
  --source build/livesync/elephants-dream-source \
  --output build/livesync/film-drift/faster --case faster
```

Cases are `aligned`, `faster` (960/1001) and `slower` (1001/960). The complete
original SRT stays unchanged. The generator validates the source hashes, PCM
format and output duration, and records attribution, applied tempo and hashes.
It deliberately does not seek to zero: doing so changed this Ogg decoder's
preroll and failed the duration check during development. The final generator
reproduced the faster case's decoded PCM and SRT exactly. Matroska identifiers
are not byte-reproducible; compare the PCM rather than its container hash.

## Current CPU baseline

Native probe source 3947d586, local guarded worker aaaa67c2, base.en-q5_1,
two inference threads, 165 seconds per case, paced null audio output:

| Case | Acquisition | Median error | P95 error | Cadence detected |
| --- | ---: | ---: | ---: | --- |
| Aligned | 33.641 s | 0.566 s | 0.566 s | Constant retained |
| Faster | 33.643 s | 3.961 s | 6.750 s | No |
| Slower | 33.636 s | 2.102 s | 4.522 s | No |

**All three fail the original combined budgets.** The older native probe marks
the aligned case passed because it checks the 0.75-second p95 threshold but
does not enforce the 0.25-second median threshold. The receipt preserves both
that raw flag and the stricter final verdict. Errors cover the recorded tracking
samples after initial acquisition; these are authored-caption timing errors,
not an independent acoustic-onset measurement.

The tests used standalone mpv, the installed capture bridge and a local guarded
worker. They do not prove the installed application, audible synchronization,
held-out accuracy or production performance. See
`livesync-evidence/film-drift-aaaa67c2.json` for scope and hashes.
