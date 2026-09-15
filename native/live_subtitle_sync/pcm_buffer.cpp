#include "pcm_buffer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <numeric>
#include <string>

namespace livesync {
namespace {
constexpr int kOutputRate = 16000;
constexpr size_t kCapacity = 30 * kOutputRate;
constexpr size_t kSourceCapacity = 1024;
constexpr double kPi = 3.14159265358979323846;

int sample_bytes(std::string_view format) {
  if (!format.empty() && format.back() == 'p') format.remove_suffix(1);
  if (format == "u8") return 1;
  if (format == "s16") return 2;
  if (format == "s32" || format == "float") return 4;
  if (format == "s64" || format == "double") return 8;
  return 0;
}

template <typename T>
T unaligned(const uint8_t* bytes) {
  T value;
  std::memcpy(&value, bytes, sizeof(value));
  return value;
}

double sample(const uint8_t* bytes, std::string_view format) {
  if (!format.empty() && format.back() == 'p') format.remove_suffix(1);
  if (format == "u8") return (static_cast<int>(*bytes) - 128) / 128.0;
  if (format == "s16") return unaligned<int16_t>(bytes) / 32768.0;
  if (format == "s32") return unaligned<int32_t>(bytes) / 2147483648.0;
  if (format == "s64") return static_cast<double>(unaligned<int64_t>(bytes)) / 9223372036854775808.0;
  if (format == "float") return unaligned<float>(bytes);
  return unaligned<double>(bytes);
}

bool supported_rate(int rate) {
  constexpr std::array<int, 13> rates = {8000,  11025, 12000, 16000, 22050,  24000, 32000,
                                         44100, 48000, 88200, 96000, 176400, 192000};
  return std::find(rates.begin(), rates.end(), rate) != rates.end();
}
}  // namespace

class PcmBuffer::Impl {
 public:
  std::array<float, kCapacity> ring{};
  std::array<float, kSourceCapacity> source{};
  std::vector<double> coefficients;
  uint64_t generation = 0;
  uint64_t revision = 0;
  int64_t epoch = -1;
  int rate = 0, channels = 0, radius = 0, phases = 0, taps = 0;
  std::string format;
  double speed = 1, origin = 0, expected_pts = 0;
  int64_t input_count = 0, output_tick = 0, last_tick = -1;
  size_t count = 0, head = 0;

  void clear() {
    // Erase private dialogue samples when changing streams or disabling.
    ring.fill(0);
    source.fill(0);
    count = head = 0;
    input_count = output_tick = 0;
    last_tick = -1;
    rate = 0;
    epoch = -1;
    ++revision;
  }

  void configure(const PcmPacket& p) {
    clear();
    rate = p.rate;
    channels = p.channels;
    epoch = p.epoch;
    speed = p.speed;
    format = p.format;
    origin = p.pts;
    radius = static_cast<int>(std::ceil(16.0 * std::max(1.0, rate / 16000.0)));
    taps = radius * 2 + 1;
    phases = kOutputRate / std::gcd(rate, kOutputRate);
    coefficients.resize(static_cast<size_t>(phases) * taps);
    const double cutoff = 0.45 * std::min(1.0, kOutputRate / static_cast<double>(rate));
    for (int phase = 0; phase < phases; ++phase) {
      const double fraction = phase / static_cast<double>(phases);
      double sum = 0;
      for (int index = 0; index < taps; ++index) {
        const double x = index - radius - fraction;
        const double sinc = std::abs(x) < 1e-12 ? 2 * cutoff : std::sin(2 * kPi * cutoff * x) / (kPi * x);
        const double window =
            std::abs(x) > radius ? 0 : 0.42 + 0.5 * std::cos(kPi * x / radius) + 0.08 * std::cos(2 * kPi * x / radius);
        coefficients[static_cast<size_t>(phase) * taps + index] = sinc * window;
        sum += sinc * window;
      }
      for (int index = 0; index < taps; ++index) coefficients[static_cast<size_t>(phase) * taps + index] /= sum;
    }
    // No invented history or zero padding at the start of a capture window.
    output_tick = (static_cast<int64_t>(radius) * kOutputRate + rate - 1) / rate;
  }

  void feed(float value) {
    source[static_cast<size_t>(input_count) % kSourceCapacity] = value;
    ++input_count;
    while (true) {
      const int64_t numerator = output_tick * rate;
      const int64_t center = numerator / kOutputRate;
      if (center + radius >= input_count) break;
      const int phase = static_cast<int>((numerator % kOutputRate) * phases / kOutputRate);
      double filtered = 0;
      for (int index = 0; index < taps; ++index) {
        const size_t source_index = static_cast<size_t>(center - radius + index) % kSourceCapacity;
        filtered += source[source_index] * coefficients[static_cast<size_t>(phase) * taps + index];
      }
      ring[head] = static_cast<float>(std::clamp(filtered, -1.0, 1.0));
      head = (head + 1) % kCapacity;
      count = std::min(count + 1, kCapacity);
      last_tick = output_tick++;
    }
  }
};

PcmBuffer::PcmBuffer() : impl_(std::make_unique<Impl>()) {}
PcmBuffer::~PcmBuffer() { impl_->clear(); }

void PcmBuffer::reset(uint64_t generation) {
  impl_->generation = generation;
  impl_->clear();
}

PcmResult PcmBuffer::append(const PcmPacket& p) {
  auto& s = *impl_;
  if (p.generation != s.generation) return PcmResult::stale;
  if (p.channels > 2) {
    s.clear();
    return PcmResult::unsupported_layout;
  }
  const int width = sample_bytes(p.format);
  const bool planar = !p.format.empty() && p.format.back() == 'p';
  if (!supported_rate(p.rate) || p.channels < 1 || p.samples <= 0 || p.samples > 65536 || !width || !p.bytes ||
      p.size > 65536 || p.size != static_cast<size_t>(p.samples) * p.channels * width ||
      p.planes != (planar ? p.channels : 1) || !std::isfinite(p.pts) || std::abs(p.pts) > 1e9 ||
      !std::isfinite(p.speed) || p.speed <= 0 || p.speed > 16 || p.epoch < 0) {
    s.clear();
    return PcmResult::invalid;
  }
  if (p.epoch != s.epoch || p.rate != s.rate || p.channels != s.channels || p.format != s.format ||
      p.speed != s.speed || std::abs(p.pts - s.expected_pts) > 2.0 * p.speed / p.rate) {
    s.configure(p);
  }
  for (int index = 0; index < p.samples; ++index) {
    double mono = 0;
    for (int channel = 0; channel < p.channels; ++channel) {
      const size_t offset =
          static_cast<size_t>(planar ? channel * p.samples + index : index * p.channels + channel) * width;
      const double value = sample(p.bytes + offset, p.format);
      if (!std::isfinite(value)) {
        s.clear();
        return PcmResult::invalid;
      }
      mono += std::clamp(value, -1.0, 1.0) / p.channels;
    }
    s.feed(static_cast<float>(mono));
  }
  s.expected_pts = s.origin + static_cast<double>(s.input_count) * s.speed / s.rate;
  return PcmResult::accepted;
}

PcmWindow PcmBuffer::recent(double seconds) const {
  const auto& s = *impl_;
  const size_t requested =
      std::isfinite(seconds) && seconds > 0 ? static_cast<size_t>(std::min(seconds, 15.0) * kOutputRate) : 0;
  const size_t count = std::min(s.count, requested);
  PcmWindow result{
      s.generation, s.revision,
      count ? s.origin + static_cast<double>(s.last_tick + 1 - static_cast<int64_t>(count)) * s.speed / kOutputRate : 0,
      s.speed / kOutputRate, std::vector<float>(count)};
  for (size_t index = 0; index < count; ++index) {
    result.samples[index] = s.ring[(s.head + kCapacity - count + index) % kCapacity];
  }
  return result;
}

size_t PcmBuffer::size() const { return impl_->count; }
uint64_t PcmBuffer::continuity() const { return impl_->revision; }
}  // namespace livesync
