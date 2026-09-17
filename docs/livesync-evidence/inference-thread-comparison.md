# Controlled inference thread comparison

The production Dart worker requests two inference threads. Earlier native ABI
smoke probes requested four without reporting that difference. Hosted Windows
controller inference measured 6.98–9.69 seconds, while a separate four-thread
AVX2 smoke observed 2.06 seconds for base.en. Different audio and concurrent
rendering prevent attributing that difference to threads.

Before the next native smoke, expose the existing one-to-four-thread ABI
parameter in the probe and include it in every new numeric report. Run the same
pinned public JFK fixture and each verified model with two and four threads
against the identical Windows AVX2 library. Keep the production default and
all functional/accuracy gates unchanged. The bounded speech detector still
uses two threads independently of the Whisper setting.

This is an exploratory pair of observations per model, not a percentile or
on/off playback benchmark. It can identify whether a further controlled
application experiment is warranted; it cannot authorize changing the default
or prove the three-second p95, CPU, rendering, or audio budgets. No private
media is consumed or persisted.

Local Apple M4 sanity check using the existing ABI-v2 integrated runtime:
quantized base.en yields zero fixture WER with both settings. Two threads take
1.039707 seconds, four take 0.655667 seconds (inference only). Both report 25
speech-supported tokens. These single Mac observations do not predict Windows
performance or establish timestamp accuracy.

## Windows outcome

Native smoke run 35160756952 passes both platforms at afce451b. On the same
Windows AVX2 binary, base.en takes 2.418048 s with two threads and 2.030007 s
with four. Quantized base.en takes 2.837187 s and 2.605609 s respectively. All
four checks retain zero fixture WER. The host reports two AMD EPYC 7763 cores
and four logical processors.

This modest difference does not establish the cause of the earlier 7–10 s
controller measurements. Retain the two-thread production setting; a larger
thread count has not demonstrated acceptable simultaneous rendering/audio
impact. [Exact numeric reports](inference-threads-afce451b.json).
