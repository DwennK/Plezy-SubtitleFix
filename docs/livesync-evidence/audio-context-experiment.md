# Rejected reduced-context inference experiment

Windows full-controller observations still exceed the three-second p95 budget.
The pinned Whisper worker uses the default 1500-position audio context for every
8–15-second window. Test a fixed 768-position context (15.36 seconds) in an
isolated source copy, with the same model, two threads, CPU options, DTW timestamps
and embedded speech detector. No production source or runtime is replaced.

On this M4, the public JFK fixture in default/reduced/reduced/default order gives:

| Model | Default seconds | Reduced seconds | Default WER | Reduced WER |
| --- | --- | --- | --- | --- |
| base.en-q5_1 | 1.051, 1.054 | 0.510, 0.504 | 0 | 2/44 |
| base.en | 0.891, 0.897 | 0.426, 0.425 | 0 | 2/44 |

Five already-consumed short dialogue windows also complete faster. However, the
window starting at 75.3696875 seconds loses the cue-10 anchor under unchanged
confidence gates. The default context obtains cues 8 and 10; reduced context only
obtains cue 8, with three beginning-confidence rejections. This can reproduce the
missing-independent-anchor condition that prevented scene recovery earlier.

**Reject this variant for production.** Lower latency does not justify losing a
required anchor. These are offline development observations, not Windows app
performance, independent acoustic truth, or a percentile benchmark. No held-out
corpus was consumed. Exact numbers and hashes are retained in
[audio-context-768-experiment.json](audio-context-768-experiment.json).
