#include "speech_support.h"

#include <whisper.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace livesync {

SpeechSupport SpeechEvidence::support(double seconds, double uncertainty) const {
  if (!available || !std::isfinite(seconds) || !std::isfinite(uncertainty) || uncertainty < 0 || seconds < 0 ||
      seconds >= duration) {
    return SpeechSupport::unknown;
  }
  for (const auto& interval : intervals) {
    if (seconds >= interval.start - uncertainty && seconds <= interval.end + uncertainty) {
      return SpeechSupport::supported;
    }
  }
  return SpeechSupport::unsupported;
}

class SpeechDetector::Impl {
 public:
  whisper_vad_context* context = nullptr;

  Impl(const unsigned char* model, size_t bytes, int threads) {
    // The public entry point bounds malformed caller input before the loader.
    if (!model || bytes == 0 || bytes > 2 * 1024 * 1024) return;
    struct Reader {
      const unsigned char* data;
      size_t size;
      size_t offset = 0;
    } reader{model, bytes};
    whisper_model_loader loader{
        &reader,
        [](void* opaque, void* output, size_t requested) -> size_t {
          auto& input = *static_cast<Reader*>(opaque);
          const size_t count = std::min(requested, input.size - input.offset);
          std::memcpy(output, input.data + input.offset, count);
          input.offset += count;
          return count;
        },
        [](void* opaque) {
          const auto& input = *static_cast<Reader*>(opaque);
          return input.offset >= input.size;
        },
        [](void*) {}};
    auto options = whisper_vad_default_context_params();
    options.n_threads = std::clamp(threads, 1, 2);
    options.use_gpu = false;
    context = whisper_vad_init_with_params(&loader, options);
  }

  ~Impl() {
    if (context) whisper_vad_free(context);
  }
};

SpeechDetector::SpeechDetector(const unsigned char* model, size_t bytes, int threads)
    : impl_(std::make_unique<Impl>(model, bytes, threads)) {}
SpeechDetector::~SpeechDetector() = default;

SpeechEvidence SpeechDetector::analyze(const float* samples, size_t count) {
  SpeechEvidence out;
  if (!impl_->context || !samples || count < 8 * 16000 || count > 15 * 16000) return out;
  for (size_t i = 0; i < count; ++i) {
    if (!std::isfinite(samples[i]) || std::abs(samples[i]) > 1) return out;
  }
  // This API resets state, unlike its no_reset streaming variant. Windows are
  // independently sampled after seeks and must never inherit prior speech.
  if (!whisper_vad_detect_speech(impl_->context, samples, static_cast<int>(count))) return out;
  auto parameters = whisper_vad_default_params();
  parameters.threshold = 0.5f;
  parameters.min_speech_duration_ms = 250;
  parameters.min_silence_duration_ms = 100;
  parameters.speech_pad_ms = 30;
  auto* segments = whisper_vad_segments_from_probs(impl_->context, parameters);
  if (!segments) return out;
  const auto release = [](whisper_vad_segments* value) { whisper_vad_free_segments(value); };
  const std::unique_ptr<whisper_vad_segments, decltype(release)> owned(segments, release);
  const int size = whisper_vad_segments_n_segments(segments);
  if (size < 0 || size > 150) return out;
  out.duration = static_cast<double>(count) / 16000;
  // Pinned Silero pads its final 512-sample probability frame. Segment output
  // is in centiseconds, with half a centisecond of rounding at that boundary.
  const double padded_end = static_cast<double>(((count + 511) / 512) * 512) / 16000 + 0.005;
  double previous_end = 0;
  for (int i = 0; i < size; ++i) {
    const double start = whisper_vad_segments_get_segment_t0(segments, i) / 100.0;
    const double end = whisper_vad_segments_get_segment_t1(segments, i) / 100.0;
    if (!std::isfinite(start) || !std::isfinite(end) || start < previous_end || end <= start || end > padded_end) {
      return {};
    }
    previous_end = end;
    if (start >= out.duration) continue;
    out.intervals.push_back({start, std::min(end, out.duration)});
  }
  out.available = true;
  return out;
}

}  // namespace livesync
