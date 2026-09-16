#include "pcm_buffer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>

using livesync::PcmBuffer;
using livesync::PcmPacket;
using livesync::PcmResult;
constexpr double pi = 3.14159265358979323846;

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void tone(
    PcmBuffer& buffer, int rate, double frequency, double seconds, double start = 0, uint64_t generation = 7,
    int64_t epoch = 1, double speed = 1, bool planar = false, int chunk = 1000) {
  const int total = static_cast<int>(seconds * rate);
  for (int index = 0; index < total; index += chunk) {
    const int count = std::min(chunk, total - index);
    std::vector<float> pcm(static_cast<size_t>(count) * 2);
    for (int i = 0; i < count; ++i) {
      // Distinct channel amplitudes: their mean must be exactly 0.5 * sin.
      const float value = static_cast<float>(std::sin(2 * pi * frequency * (index + i) / rate));
      pcm[planar ? i : 2 * i] = value * 0.25f;
      pcm[planar ? count + i : 2 * i + 1] = value * 0.75f;
    }
    PcmPacket packet{
        generation,
        epoch,
        start + index * speed / rate,
        speed,
        rate,
        2,
        count,
        planar ? 2 : 1,
        planar ? "floatp" : "float",
        reinterpret_cast<const uint8_t*>(pcm.data()),
        pcm.size() * sizeof(float)};
    require(buffer.append(packet) == PcmResult::accepted, "valid tone rejected");
  }
}

void resampling_and_timestamps() {
  for (int rate : {8000, 11025, 16000, 44100, 48000, 96000, 192000}) {
    for (bool planar : {false, true}) {
      PcmBuffer buffer;
      buffer.reset(7);
      tone(buffer, rate, 731, 1.0, 123.5, 7, 1, 1.5, planar);
      const auto window = buffer.recent(15);
      require(window.samples.size() > 15900, "unexpected sample count");
      require(std::abs(window.media_seconds_per_sample - 1.5 / 16000) < 1e-12, "speed timebase lost");
      double error = 0;
      for (size_t i = 0; i < window.samples.size(); ++i) {
        const double input_time = (window.media_start - 123.5) / 1.5 + i / 16000.0;
        error = std::max(error, std::abs(window.samples[i] - 0.5 * std::sin(2 * pi * 731 * input_time)));
      }
      require(error < 0.001, "resampled signal or filter-center timestamp incorrect");
      require(window.media_start > 123.5 && window.media_start < 123.51, "startup history was invented");
    }
  }
}

void anti_alias_and_packet_boundaries() {
  PcmBuffer a, b, high;
  for (auto* buffer : {&a, &b, &high}) buffer->reset(7);
  tone(a, 44100, 1000, 1, 0, 7, 1, 1, false, 997);
  tone(b, 44100, 1000, 1, 0, 7, 1, 1, true, 317);
  require(a.recent(15).samples == b.recent(15).samples, "packetization changed resampling");
  tone(high, 48000, 12000, 1);
  double energy = 0;
  for (const float value : high.recent(15).samples) energy += value * value;
  require(std::sqrt(energy / high.size()) < 0.001, "out-of-band audio aliases into speech");
}

void bounded_storage_and_generation() {
  PcmBuffer buffer;
  buffer.reset(7);
  tone(buffer, 48000, 731, 32);
  require(buffer.size() == 480000, "30 second ring is not bounded");
  const auto window = buffer.recent(100);
  require(window.samples.size() == 240000, "inference snapshot exceeds 15 seconds");
  require(window.media_start > 16.99 && window.media_start < 17.01, "wrapped ring timestamp incorrect");
  const auto revision = buffer.continuity();
  float zero = 0;
  PcmPacket stale{6, 1, 90, 1, 16000, 1, 1, 1, "float", reinterpret_cast<uint8_t*>(&zero), sizeof(zero)};
  require(buffer.append(stale) == PcmResult::stale, "stale generation accepted");
  require(buffer.continuity() == revision && buffer.size() == 480000, "stale packet destroyed current audio");
  tone(buffer, 48000, 731, 0.1, 100, 7, 1);
  require(buffer.continuity() > revision && buffer.size() < 1600, "PTS gap did not discard old audio");
  auto before = buffer.continuity();
  tone(buffer, 48000, 731, 0.1, 100.1, 7, 2);
  require(buffer.continuity() > before, "overflow epoch did not invalidate prior window");
  before = buffer.continuity();
  tone(buffer, 44100, 731, 0.1, 100.2, 7, 2);
  require(buffer.continuity() > before, "rate change did not invalidate prior window");
  buffer.reset(8);
  require(buffer.size() == 0 && buffer.recent(15).generation == 8, "reset retained dialogue");
}

void invalid_pcm() {
  PcmBuffer buffer;
  buffer.reset(7);
  float bad = std::numeric_limits<float>::quiet_NaN();
  PcmPacket packet{7, 1, 0, 1, 16000, 1, 1, 1, "float", reinterpret_cast<uint8_t*>(&bad), sizeof(bad)};
  require(buffer.append(packet) == PcmResult::invalid, "NaN accepted");
  packet.channels = 9;
  require(buffer.append(packet) == PcmResult::unsupported_layout, "unbounded channel layout accepted");
  packet.channels = 1;
  packet.size = 1;
  require(buffer.append(packet) == PcmResult::invalid, "truncated sample accepted");
  require(buffer.size() == 0, "invalid data retained");
}

template <typename T>
void constant_format(const char* format, T left, T right, bool planar) {
  PcmBuffer buffer;
  buffer.reset(7);
  std::vector<T> samples(2048);
  for (int i = 0; i < 1024; ++i) {
    samples[planar ? i : 2 * i] = left;
    samples[planar ? 1024 + i : 2 * i + 1] = right;
  }
  PcmPacket packet{
      7,
      1,
      0,
      1,
      16000,
      2,
      1024,
      planar ? 2 : 1,
      format,
      reinterpret_cast<const uint8_t*>(samples.data()),
      samples.size() * sizeof(T)};
  require(buffer.append(packet) == PcmResult::accepted, "sample representation rejected");
  const auto window = buffer.recent(15);
  require(window.samples.size() > 900, "format produced no samples");
  for (float value : window.samples) require(std::abs(value - 0.375f) < 1e-6, "sample scaling or channel order wrong");
}

void sample_representations() {
  constant_format<uint8_t>("u8", 160, 192, false);
  constant_format<uint8_t>("u8p", 160, 192, true);
  constant_format<int16_t>("s16", 8192, 16384, false);
  constant_format<int16_t>("s16p", 8192, 16384, true);
  constant_format<int32_t>("s32", 536870912, 1073741824, false);
  constant_format<int32_t>("s32p", 536870912, 1073741824, true);
  constant_format<int64_t>("s64", INT64_C(2305843009213693952), INT64_C(4611686018427387904), false);
  constant_format<int64_t>("s64p", INT64_C(2305843009213693952), INT64_C(4611686018427387904), true);
  constant_format<double>("double", 0.25, 0.5, false);
  constant_format<double>("doublep", 0.25, 0.5, true);
}

void multichannel_analysis() {
  // A dialogue signal in ANY channel must survive analysis, without assuming
  // that a particular index denotes the center speaker. Test both storage
  // layouts and verify the supplied PCM remains byte-for-byte unchanged.
  for (int channels : {3, 6, 8}) {
    for (bool planar : {false, true}) {
      for (int active = 0; active < channels; ++active) {
        PcmBuffer buffer;
        buffer.reset(7);
        constexpr int count = 1024;
        std::vector<float> samples(count * channels, 0);
        for (int i = 0; i < count; ++i) samples[planar ? active * count + i : i * channels + active] = 0.75f;
        const auto original = samples;
        PcmPacket packet{
            7,
            1,
            123,
            1,
            16000,
            channels,
            count,
            planar ? channels : 1,
            planar ? "floatp" : "float",
            reinterpret_cast<const uint8_t*>(samples.data()),
            samples.size() * sizeof(float)};
        require(buffer.append(packet) == PcmResult::accepted, "multichannel PCM rejected");
        const auto window = buffer.recent(15);
        require(window.samples.size() > 900, "multichannel analysis missing");
        for (float value : window.samples)
          require(std::abs(value - 0.75f / channels) < 1e-6, "dialogue channel lost or misweighted");
        require(samples == original, "analysis modified source PCM");
        require(window.media_start >= 123 && window.media_start < 123.01, "multichannel PTS lost");
      }
    }
  }
}

int main() {
  try {
    const auto started = std::chrono::steady_clock::now();
    resampling_and_timestamps();
    anti_alias_and_packet_boundaries();
    bounded_storage_and_generation();
    invalid_pcm();
    sample_representations();
    multichannel_analysis();
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    std::cout << "PCM consumer tests passed in " << seconds << " seconds\n";
    return EXIT_SUCCESS;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
