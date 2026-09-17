#pragma once

#include <cstddef>
#include <memory>
#include <vector>

namespace livesync {

enum class SpeechSupport { unknown = 0, supported = 1, unsupported = 2 };

struct SpeechInterval {
  double start;
  double end;
};

// Times are seconds relative to the submitted 16 kHz PCM window. A successful
// empty result means silence; failure means unknown, never verified silence.
struct SpeechEvidence {
  bool available = false;
  double duration = 0;
  std::vector<SpeechInterval> intervals;

  SpeechSupport support(double seconds, double uncertainty) const;
};

// Single inference-worker ownership. Construction and destruction run outside
// the UI/audio threads. The caller must verify model bytes before construction.
// Context is loaded once, reused with LSTM state reset for every independent
// window, and released on destruction. No audio or probabilities are retained
// by this wrapper after analyze returns.
class SpeechDetector {
 public:
  SpeechDetector(const unsigned char* model, size_t bytes, int threads = 2);
  ~SpeechDetector();
  SpeechDetector(const SpeechDetector&) = delete;
  SpeechDetector& operator=(const SpeechDetector&) = delete;

  SpeechEvidence analyze(const float* samples, size_t count);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace livesync
