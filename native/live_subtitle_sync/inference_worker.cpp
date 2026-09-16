#include "inference_worker.h"

#include <whisper.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <utility>

#if defined(__APPLE__)
#include <pthread.h>
#elif defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace livesync {
namespace {
constexpr size_t kMaximumTextBytes = 8192;
constexpr int kMaximumSegments = 64;
constexpr int kMaximumTokens = 512;

void lower_priority() {
#if defined(__APPLE__)
  pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#elif defined(_WIN32)
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#endif
}

bool bounded_text(const char* source, size_t& budget, std::string& target) {
  if (!source) return false;
  size_t count = 0;
  while (count <= budget && source[count]) ++count;
  if (count > budget) return false;
  target.assign(source, count);
  budget -= count;
  return true;
}
}  // namespace

class InferenceWorker::Impl {
 public:
  inline static std::atomic<Impl*> owner{nullptr};
  const std::string model_path;
  const int threads;
  mutable std::mutex mutex;
  std::condition_variable wake;
  std::atomic<bool> stopped{false};
  std::atomic<bool> decoding{false};
  std::atomic<uint64_t> generation{0}, continuity{0};
  uint64_t running_generation = 0, running_continuity = 0;
  std::optional<PcmWindow> pending;
  std::optional<InferenceResult> result;
  bool active = false;
  std::thread worker;

  Impl(std::string path, int count) : model_path(std::move(path)), threads(std::clamp(count, 1, 4)) {
    static std::once_flag silence_logs;
    std::call_once(silence_logs, [] { whisper_log_set([](ggml_log_level, const char*, void*) {}, nullptr); });
    worker = std::thread([this] { run(); });
  }

  bool cancelled() const {
    return stopped.load() || generation.load() != running_generation || continuity.load() != running_continuity;
  }

  void release_slot() {
    auto* expected = this;
    owner.compare_exchange_strong(expected, nullptr);
  }

  InferenceResult transcribe(whisper_context* context, const PcmWindow& window) {
    InferenceResult out{window.generation, window.continuity, InferenceStatus::inference_failed, 0, {}};
    auto parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    parameters.n_threads = threads;
    parameters.language = "en";
    parameters.translate = false;
    parameters.no_context = true;
    parameters.print_special = parameters.print_progress = parameters.print_realtime = parameters.print_timestamps =
        false;
    parameters.token_timestamps = true;
    parameters.max_tokens = 256;
    parameters.abort_callback = [](void* data) { return static_cast<Impl*>(data)->cancelled(); };
    parameters.abort_callback_user_data = this;
    parameters.encoder_begin_callback = [](whisper_context*, whisper_state*, void* data) {
      return !static_cast<Impl*>(data)->cancelled();
    };
    parameters.encoder_begin_callback_user_data = this;
    const auto started = std::chrono::steady_clock::now();
    decoding.store(true);
    const int code = whisper_full(context, parameters, window.samples.data(), static_cast<int>(window.samples.size()));
    decoding.store(false);
    out.elapsed_seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    if (code != 0 || cancelled()) return out;
    size_t text_budget = kMaximumTextBytes;
    int token_budget = kMaximumTokens;
    const int segments = whisper_full_n_segments(context);
    if (segments < 0 || segments > kMaximumSegments) {
      out.status = InferenceStatus::output_limit;
      return out;
    }
    const double scale = window.media_seconds_per_sample * 16000;
    const double duration = static_cast<double>(window.samples.size()) / 16000;
    auto media_time = [&](int64_t ticks) { return window.media_start + static_cast<double>(ticks) * 0.01 * scale; };
    for (int index = 0; index < segments; ++index) {
      const auto t0 = whisper_full_get_segment_t0(context, index);
      const auto t1 = whisper_full_get_segment_t1(context, index);
      // Allow the decoder's final 10 ms timestamp quantum; do not invent valid
      // times for a negative or otherwise malformed segment.
      if (t0 < 0 || t1 < t0 || static_cast<double>(t1) * 0.01 > duration + 0.02) {
        // Stop at the first invalid segment. Earlier complete segments retain
        // their original text and DTW points; never clamp the bad timestamp or
        // join dialogue across the rejected region.
        out.status = out.segments.empty() ? InferenceStatus::invalid_timestamps : InferenceStatus::valid_prefix;
        return out;
      }
      TranscriptSegment segment{"", media_time(t0), media_time(t1), {}};
      const int tokens = whisper_full_n_tokens(context, index);
      if (tokens < 0 || tokens > token_budget ||
          !bounded_text(whisper_full_get_segment_text(context, index), text_budget, segment.text)) {
        out.status = InferenceStatus::output_limit;
        out.segments.clear();
        return out;
      }
      token_budget -= tokens;
      for (int token_index = 0; token_index < tokens; ++token_index) {
        const auto token = whisper_full_get_token_data(context, index, token_index);
        if (token.id >= whisper_token_eot(context)) continue;
        TranscriptToken item{"", 0, 0, token.p, false};
        if (!bounded_text(whisper_full_get_token_text(context, index, token_index), text_budget, item.text)) {
          out.status = InferenceStatus::output_limit;
          out.segments.clear();
          return out;
        }
        // DTW relates token attention to the audio. The legacy t0/t1 heuristic
        // can put a correctly recognized cue several seconds before speech.
        // Export a 20 ms alignment-point interval, not an invented word duration.
        item.has_timestamp = token.t_dtw >= 0 && static_cast<double>(token.t_dtw) * 0.01 < duration;
        if (item.has_timestamp) {
          item.media_start = media_time(token.t_dtw);
          item.media_end = std::min(media_time(token.t_dtw + 2), window.media_start + duration * scale);
        }
        segment.tokens.push_back(std::move(item));
      }
      out.segments.push_back(std::move(segment));
    }
    out.status = InferenceStatus::success;
    return out;
  }

  void run() {
    lower_priority();
    whisper_context* context = nullptr;
    while (true) {
      std::optional<PcmWindow> window;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [&] { return stopped.load() || pending.has_value(); });
        if (stopped.load()) break;
        window = std::move(pending);
        pending.reset();
        running_generation = window->generation;
        running_continuity = window->continuity;
      }
      InferenceResult next{window->generation, window->continuity, InferenceStatus::model_unavailable, 0, {}};
      try {
        if (!cancelled()) {
          if (!context) {
            auto options = whisper_context_default_params();
            options.use_gpu = false;
            // Both pinned models use the base.en architecture/alignment heads.
            // Flash attention silently disables DTW in this whisper revision.
            options.flash_attn = false;
            options.dtw_token_timestamps = true;
            options.dtw_aheads_preset = WHISPER_AHEADS_BASE_EN;
            options.dtw_mem_size = 128 * 1024 * 1024;
            context = whisper_init_from_file_with_params(model_path.c_str(), options);
          }
          if (context && !cancelled()) next = transcribe(context, *window);
        }
      } catch (...) {
        next.status = InferenceStatus::inference_failed;
      }
      decoding.store(false);
      std::fill(window->samples.begin(), window->samples.end(), 0.0f);
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (!cancelled()) result = std::move(next);
        active = false;
        release_slot();
      }
    }
    if (context) whisper_free(context);
  }
};

InferenceWorker::InferenceWorker(std::string model_path, int threads)
    : impl_(std::make_unique<Impl>(std::move(model_path), threads)) {}
InferenceWorker::~InferenceWorker() { stop(); }

void InferenceWorker::reset(uint64_t generation, uint64_t continuity) {
  auto& s = *impl_;
  std::lock_guard<std::mutex> lock(s.mutex);
  s.generation.store(generation);
  s.continuity.store(continuity);
  s.result.reset();
  if (s.pending) {
    std::fill(s.pending->samples.begin(), s.pending->samples.end(), 0.0f);
    s.pending.reset();
    s.active = false;
    s.release_slot();
  }
}

bool InferenceWorker::submit(PcmWindow window) {
  auto& s = *impl_;
  if (window.samples.size() < 8 * 16000 || window.samples.size() > 15 * 16000 || !std::isfinite(window.media_start) ||
      !std::isfinite(window.media_seconds_per_sample) || window.media_seconds_per_sample <= 0 ||
      window.media_seconds_per_sample > 16.0 / 16000 ||
      !std::all_of(window.samples.begin(), window.samples.end(), [](float value) {
        return std::isfinite(value) && value >= -1 && value <= 1;
      }))
    return false;
  std::lock_guard<std::mutex> lock(s.mutex);
  if (s.stopped.load() || s.active || s.result.has_value() || window.generation != s.generation.load() ||
      window.continuity != s.continuity.load())
    return false;
  Impl* expected = nullptr;
  if (!Impl::owner.compare_exchange_strong(expected, &s)) return false;
  s.pending = std::move(window);
  s.active = true;
  s.result.reset();
  s.wake.notify_one();
  return true;
}

std::optional<InferenceResult> InferenceWorker::take_result() {
  auto& s = *impl_;
  std::lock_guard<std::mutex> lock(s.mutex);
  auto result = std::move(s.result);
  s.result.reset();
  return result;
}

bool InferenceWorker::busy() const {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  return impl_->active;
}

bool InferenceWorker::inferencing() const { return impl_->decoding.load(); }

void InferenceWorker::stop() {
  auto& s = *impl_;
  s.stopped.store(true);
  s.wake.notify_one();
  if (s.worker.joinable()) s.worker.join();
  std::lock_guard<std::mutex> lock(s.mutex);
  if (s.pending) std::fill(s.pending->samples.begin(), s.pending->samples.end(), 0.0f);
  s.pending.reset();
  s.result.reset();
  s.active = false;
  s.release_slot();
}
}  // namespace livesync
