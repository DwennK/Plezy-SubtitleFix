#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "pcm_buffer.h"
#include "speech_support.h"

namespace livesync {

struct TranscriptToken {
  std::string text;
  // A DTW alignment-point interval (20 ms quantum), not word onset/offset
  // ground truth. The temporal aligner must retain its own uncertainty.
  double media_start;
  double media_end;
  float recognition_score;
  bool has_timestamp;
  SpeechSupport speech_support = SpeechSupport::unknown;
};

struct TranscriptSegment {
  std::string text;
  double media_start;
  double media_end;
  std::vector<TranscriptToken> tokens;
};

enum class InferenceStatus {
  success,
  model_unavailable,
  inference_failed,
  output_limit,
  invalid_timestamps,
  valid_prefix
};

// Preference, not proof of physical device execution: whisper may internally
// choose CPU when a requested GPU backend is unavailable.
enum class InferenceBackend { cpu = 1, metal_preferred = 2, cpu_fallback = 3 };

struct InferenceResult {
  uint64_t generation;
  uint64_t continuity;
  InferenceStatus status;
  double elapsed_seconds;
  std::vector<TranscriptSegment> segments;
};

// Native worker foundation. The model path must come from a verified lease;
// keep that lease until this object has finished stopping. The optional Metal
// profile falls back once to CPU on recoverable backend failure.
class InferenceWorker {
 public:
  explicit InferenceWorker(std::string model_path, int threads = 4);
  ~InferenceWorker();
  InferenceWorker(const InferenceWorker&) = delete;
  InferenceWorker& operator=(const InferenceWorker&) = delete;

  // Invalidates pending, running and completed work from the old playback.
  void reset(uint64_t generation, uint64_t continuity);
  // Accept only an 8–15 second window with the current generation/continuity.
  // No unbounded queue: returns false while any worker in this process is
  // analyzing, or until this worker's previous result has been consumed.
  bool submit(PcmWindow window);
  // Destructive poll of a single result. No transcript is logged or persisted.
  std::optional<InferenceResult> take_result();
  bool busy() const;
  bool inferencing() const;
  InferenceBackend backend() const;
  // Control calls belong to one serialized owner. Joins the worker; call from
  // an app cleanup queue, never the UI/audio thread.
  void stop();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace livesync
