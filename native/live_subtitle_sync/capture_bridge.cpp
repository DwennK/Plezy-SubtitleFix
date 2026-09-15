#include "capture_bridge.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <thread>

#include "pcm_buffer.h"

#if defined(__APPLE__)
#include <pthread.h>
#elif defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace {
std::atomic<bool> capture_owned{false};

const mpv_node& field(const mpv_node& map, const char* key, mpv_format format) {
  if (map.format != MPV_FORMAT_NODE_MAP || !map.u.list || map.u.list->num < 0 || map.u.list->num > 32 ||
      !map.u.list->keys || !map.u.list->values)
    throw std::invalid_argument("packet map");
  const mpv_node* found = nullptr;
  for (int i = 0; i < map.u.list->num; ++i) {
    if (map.u.list->keys[i] && std::strcmp(map.u.list->keys[i], key) == 0) {
      if (found) throw std::invalid_argument("duplicate packet field");
      found = &map.u.list->values[i];
    }
  }
  if (!found || found->format != format) throw std::invalid_argument("packet field");
  return *found;
}

int number(const mpv_node& map, const char* key) {
  const int64_t value = field(map, key, MPV_FORMAT_INT64).u.int64;
  if (value < 0 || value > std::numeric_limits<int>::max()) throw std::invalid_argument("packet integer");
  return static_cast<int>(value);
}

class Capture {
 public:
  Capture(mpv_handle* client, const ls_mpv_api& api, uint64_t generation) : client_(client), api_(api) {
    buffer_.reset(generation);
    generation_ = generation;
    thread_ = std::thread([this] { run(); });
  }

  ~Capture() {
    stopping_ = true;
    wake_.notify_all();
    thread_.join();
    capture_owned = false;
  }

  bool reset(uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == 4 || generation < generation_) return false;
    generation_ = generation;
    buffer_.reset(generation);
    flush_ = true;
    state_ = 1;
    wake_.notify_all();
    return true;
  }

  ls_capture_info info() {
    std::lock_guard<std::mutex> lock(mutex_);
    return {generation_, buffer_.continuity(), buffer_.size(), state_};
  }

  livesync::PcmWindow snapshot(double seconds) {
    std::lock_guard<std::mutex> lock(mutex_);
    return buffer_.recent(seconds);
  }

 private:
  void append(const mpv_node& node, uint64_t generation) {
    if (number(node, "version") != 1) throw std::invalid_argument("capture version");
    const int64_t epoch = field(node, "epoch", MPV_FORMAT_INT64).u.int64;
    const auto* frames = field(node, "frames", MPV_FORMAT_NODE_ARRAY).u.list;
    if (epoch < 0 || !frames || frames->num < 0 || frames->num > 64 || (frames->num && !frames->values))
      throw std::invalid_argument("capture frames");
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation != generation_) return;
    if (epoch != epoch_) {
      buffer_.reset(generation_);
      epoch_ = epoch;
    }
    size_t total = 0;
    for (int i = 0; i < frames->num; ++i) {
      const auto& frame = frames->values[i];
      const auto* bytes = field(frame, "pcm", MPV_FORMAT_BYTE_ARRAY).u.ba;
      const char* format = field(frame, "format", MPV_FORMAT_STRING).u.string;
      if (!bytes || !format || !bytes->data || bytes->size > 64 * 1024 || total + bytes->size > 256 * 1024)
        throw std::invalid_argument("capture bytes");
      total += bytes->size;
      const auto result = buffer_.append(
          {generation, epoch, field(frame, "pts", MPV_FORMAT_DOUBLE).u.double_,
           field(frame, "speed", MPV_FORMAT_DOUBLE).u.double_, number(frame, "rate"), number(frame, "channels"),
           number(frame, "samples"), number(frame, "planes"), format, static_cast<const uint8_t*>(bytes->data),
           bytes->size});
      if (result != livesync::PcmResult::accepted) {
        buffer_.reset(generation_);
        state_ = result == livesync::PcmResult::unsupported_layout ? 3 : 2;
        return;
      }
      state_ = 0;
    }
  }

  void run() noexcept {
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#elif defined(_WIN32)
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#endif
    bool enabled = false;
    while (!stopping_) {
      bool shutdown = false;
      for (int i = 0; i < 32; ++i) {
        const auto* event = api_.wait_event(client_, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) break;
        if (event->event_id == MPV_EVENT_SHUTDOWN) {
          shutdown = true;
          break;
        }
        if (event->event_id == MPV_EVENT_START_FILE || event->event_id == MPV_EVENT_END_FILE ||
            event->event_id == MPV_EVENT_SEEK) {
          std::lock_guard<std::mutex> lock(mutex_);
          buffer_.reset(generation_);
          // The mpv tap already flushes and advances its epoch on seeks.
          // Disabling it again here would discard the newly decoded lead-in.
          if (event->event_id != MPV_EVENT_SEEK) flush_ = true;
          state_ = 1;
        }
      }
      if (shutdown) break;
      uint64_t generation;
      bool flush;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        generation = generation_;
        flush = flush_;
        flush_ = false;
      }
      if (flush) {
        api_.set_property_string(client_, "livesync-enabled", "no");
        enabled = false;
      }
      if (!enabled) enabled = api_.set_property_string(client_, "livesync-enabled", "yes") >= 0;
      if (enabled) {
        mpv_node node{};
        if (api_.get_property(client_, "livesync-pcm", MPV_FORMAT_NODE, &node) >= 0) {
          try {
            append(node, generation);
          } catch (...) {
            std::lock_guard<std::mutex> lock(mutex_);
            buffer_.reset(generation_);
            state_ = 2;
          }
          api_.free_node_contents(&node);
        } else {
          std::lock_guard<std::mutex> lock(mutex_);
          buffer_.reset(generation_);
          state_ = 1;
          enabled = false;
        }
      }
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait_for(lock, std::chrono::milliseconds(enabled ? 25 : 200), [this] { return stopping_ || flush_; });
    }
    api_.set_property_string(client_, "livesync-enabled", "no");
    api_.destroy(client_);
    std::lock_guard<std::mutex> lock(mutex_);
    buffer_.reset(generation_);
    state_ = 4;
  }

  mpv_handle* client_;
  ls_mpv_api api_;
  livesync::PcmBuffer buffer_;
  uint64_t generation_ = 0;
  int64_t epoch_ = -1;
  uint32_t state_ = 1;
  bool flush_ = true;
  std::atomic<bool> stopping_{false};
  std::mutex mutex_;
  std::condition_variable wake_;
  std::thread thread_;
};
}  // namespace

uint32_t ls_capture_abi_version(void) { return 1; }
size_t ls_capture_api_size(void) { return sizeof(ls_mpv_api); }
size_t ls_capture_info_size(void) { return sizeof(ls_capture_info); }

void* ls_capture_create(mpv_handle* weak_client, const ls_mpv_api* api, uint64_t generation) {
  if (!weak_client || !api || api->version != 1 || !api->get_property || !api->set_property_string ||
      !api->free_node_contents || !api->wait_event || !api->destroy || !generation)
    return nullptr;
  bool expected = false;
  if (!capture_owned.compare_exchange_strong(expected, true)) return nullptr;
  try {
    return new Capture(weak_client, *api, generation);
  } catch (...) {
    capture_owned = false;
    return nullptr;
  }
}

void ls_capture_destroy(void* capture) { delete static_cast<Capture*>(capture); }

int ls_capture_reset(void* capture, uint64_t generation) {
  if (!capture || !generation) return -1;
  try {
    return static_cast<Capture*>(capture)->reset(generation) ? 0 : -1;
  } catch (...) {
    return -1;
  }
}

int ls_capture_get_info(void* capture, ls_capture_info* info, size_t size) {
  if (!capture || !info || size != sizeof(*info)) return -1;
  try {
    *info = static_cast<Capture*>(capture)->info();
    return 0;
  } catch (...) {
    return -1;
  }
}

size_t ls_capture_snapshot(void* capture, double seconds, float* output, size_t capacity, ls_pcm_window_info* info) {
  if (!capture || !output || !info || !std::isfinite(seconds) || seconds < 0 || seconds > 15) return 0;
  try {
    auto window = static_cast<Capture*>(capture)->snapshot(seconds);
    if (window.samples.empty() || window.samples.size() > capacity) return 0;
    std::memcpy(output, window.samples.data(), window.samples.size() * sizeof(float));
    *info = {window.generation, window.continuity, window.media_start, window.media_seconds_per_sample};
    return window.samples.size();
  } catch (...) {
    return 0;
  }
}
