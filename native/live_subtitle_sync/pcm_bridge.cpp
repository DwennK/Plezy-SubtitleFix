#include "pcm_bridge.h"

#include <algorithm>

#include "pcm_buffer.h"

void* ls_pcm_create(void) {
  try {
    return new livesync::PcmBuffer();
  } catch (...) {
    return nullptr;
  }
}

void ls_pcm_destroy(void* handle) { delete static_cast<livesync::PcmBuffer*>(handle); }

void ls_pcm_reset(void* handle, uint64_t generation) {
  if (handle) static_cast<livesync::PcmBuffer*>(handle)->reset(generation);
}

int ls_pcm_append(
    void* handle, uint64_t generation, int64_t epoch, double pts, double speed, int rate, int channels, int samples,
    int planes, const char* format, const uint8_t* bytes, size_t size) {
  if (!handle || !format) return 2;
  try {
    return static_cast<int>(static_cast<livesync::PcmBuffer*>(handle)->append(
        {generation, epoch, pts, speed, rate, channels, samples, planes, format, bytes, size}));
  } catch (...) {
    static_cast<livesync::PcmBuffer*>(handle)->reset(generation);
    return 4;
  }
}

size_t ls_pcm_snapshot(void* handle, double seconds, float* output, size_t capacity, ls_pcm_window_info* info) {
  if (!handle || !output || !info) return 0;
  try {
    const auto window = static_cast<livesync::PcmBuffer*>(handle)->recent(seconds);
    if (window.samples.size() > capacity) return 0;
    *info = {window.generation, window.continuity, window.media_start, window.media_seconds_per_sample};
    std::copy(window.samples.begin(), window.samples.end(), output);
    return window.samples.size();
  } catch (...) {
    return 0;
  }
}
