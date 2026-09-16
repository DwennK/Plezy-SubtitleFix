#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string_view>
#include <vector>

namespace livesync {

// Worker-owned: no method may run on the audio callback or UI thread.
// Analysis averages every channel with equal weight, independent of speaker
// order. This deliberately does not implement a speaker-specific output mix.
// Mono through eight-channel PCM are accepted; audible playback is untouched.
struct PcmPacket {
  uint64_t generation;
  int64_t epoch;
  double pts;
  double speed;
  int rate;
  int channels;
  int samples;
  int planes;
  std::string_view format;
  const uint8_t* bytes;
  size_t size;
};

enum class PcmResult { accepted = 0, stale = 1, invalid = 2, unsupported_layout = 3 };

struct PcmWindow {
  uint64_t generation;
  uint64_t continuity;
  double media_start;
  double media_seconds_per_sample;
  std::vector<float> samples;
};

// Float32 mono 16 kHz, at most 30 seconds. Time refers to the filter center
// in the input media, never the arrival time or inference completion time.
class PcmBuffer {
 public:
  PcmBuffer();
  ~PcmBuffer();
  PcmBuffer(const PcmBuffer&) = delete;
  PcmBuffer& operator=(const PcmBuffer&) = delete;

  void reset(uint64_t generation);
  PcmResult append(const PcmPacket& packet);
  PcmWindow recent(double seconds) const;
  size_t size() const;
  uint64_t continuity() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace livesync
