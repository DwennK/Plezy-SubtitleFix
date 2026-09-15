# LiveSync fixture provenance

## JFK inference smoke sample

- Source bytes: `samples/jfk.wav` from whisper.cpp revision
  `927cfce34f31707e17f2bff35c349632fb9e2c3a` (MIT repository).
- SHA-256: `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
- Mono signed 16-bit PCM, 16 kHz, 176,000 samples, exactly 11 seconds.
- Speech: President John F. Kennedy, inaugural address, 20 January 1961,
  delivered as a US federal official. Public-domain federal speech.
- Primary historical source:
  https://www.archives.gov/milestone-documents/president-john-f-kennedys-inaugural-address
- The bytes are retrieved from the immutable whisper source checkout; no third
  party streaming media or private film/episode is downloaded for these tests.
- Purpose: actual inference and model-loading smoke check. This familiar excerpt
  is **not** a held-out recognition or synchronization evaluation set. Token
  timestamps are not accepted as ground truth. Word error on this sample alone
  cannot establish temporal precision or confidence calibration.

## Generated stereo waveform

`scripts/livesync/probe_pcm.py` generates 12 seconds at 48 kHz, with 317 Hz in the
left channel and 691 Hz in the right. Its formula establishes the expected PCM
value for each absolute media sample index. It tests decoder sample/PTS mapping,
channel layout, seeks, speed, pause and disable using the actual libmpv binary.
It contains no dialogue and does not test Whisper or SRT synchronization.
The fixture generator is part of this GPL-licensed fork.
