#include "inference_bridge.h"

#include <cstring>
#include <stdexcept>

#include "inference_worker.h"

uint32_t ls_inference_abi_version(void) { return 2; }
size_t ls_inference_result_size(void) { return sizeof(ls_inference_result); }
uint32_t ls_inference_backend(void* handle) {
  return handle ? static_cast<uint32_t>(static_cast<livesync::InferenceWorker*>(handle)->backend()) : 0;
}

void* ls_inference_create(const char* model_path, int threads) {
  if (!model_path || !model_path[0]) return nullptr;
  try {
    return new livesync::InferenceWorker(model_path, threads);
  } catch (...) {
    return nullptr;
  }
}

void ls_inference_destroy(void* handle) { delete static_cast<livesync::InferenceWorker*>(handle); }

int ls_inference_reset(void* handle, uint64_t generation, uint64_t continuity) {
  if (!handle) return -1;
  try {
    static_cast<livesync::InferenceWorker*>(handle)->reset(generation, continuity);
    return 0;
  } catch (...) {
    return -1;
  }
}

int ls_inference_submit(
    void* handle, uint64_t generation, uint64_t continuity, double media_start, double media_seconds_per_sample,
    const float* samples, size_t count) {
  if (!handle || !samples || count < 8 * 16000 || count > 15 * 16000) return -1;
  try {
    return static_cast<livesync::InferenceWorker*>(handle)->submit(
               {generation, continuity, media_start, media_seconds_per_sample, {samples, samples + count}})
               ? 1
               : 0;
  } catch (...) {
    return -1;
  }
}

int ls_inference_take_result(void* handle, ls_inference_result* output, size_t size) {
  if (!handle || !output || size != sizeof(*output)) return -1;
  std::memset(output, 0, sizeof(*output));
  try {
    auto result = static_cast<livesync::InferenceWorker*>(handle)->take_result();
    if (!result) return 0;
    output->generation = result->generation;
    output->continuity = result->continuity;
    output->elapsed_seconds = result->elapsed_seconds;
    output->status = static_cast<uint32_t>(result->status);
    auto copy_text = [&](const std::string& text, uint32_t& offset, uint32_t& length) {
      if (text.size() > sizeof(output->text) - output->text_bytes) throw std::length_error("text limit");
      offset = output->text_bytes;
      length = static_cast<uint32_t>(text.size());
      std::memcpy(output->text + offset, text.data(), length);
      output->text_bytes += length;
    };
    for (const auto& segment : result->segments) {
      if (output->segment_count >= 64) throw std::length_error("segment limit");
      auto& destination = output->segments[output->segment_count++];
      destination.media_start = segment.media_start;
      destination.media_end = segment.media_end;
      copy_text(segment.text, destination.text_offset, destination.text_length);
      destination.token_offset = output->token_count;
      for (const auto& token : segment.tokens) {
        if (output->token_count >= 512) throw std::length_error("token limit");
        auto& target = output->tokens[output->token_count++];
        target.media_start = token.media_start;
        target.media_end = token.media_end;
        target.recognition_score = token.recognition_score;
        target.has_timestamp = token.has_timestamp ? 1 : 0;
        target.speech_support = static_cast<uint32_t>(token.speech_support);
        copy_text(token.text, target.text_offset, target.text_length);
        ++destination.token_count;
      }
    }
    return 1;
  } catch (...) {
    std::memset(output, 0, sizeof(*output));
    return -1;
  }
}
