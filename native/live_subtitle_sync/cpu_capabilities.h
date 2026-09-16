#pragma once

#include <cstdint>

namespace livesync {
// Exact requirements of the packaged ggml AVX2 profile, including OS state.
constexpr bool supports_avx2(uint32_t leaf1_ecx, uint32_t leaf7_ebx, uint64_t xcr0) {
  constexpr uint32_t required1 = (1u << 12) | (1u << 20) | (1u << 26) | (1u << 27) | (1u << 28) | (1u << 29);
  constexpr uint32_t required7 = (1u << 5) | (1u << 8);
  return (leaf1_ecx & required1) == required1 && (leaf7_ebx & required7) == required7 && (xcr0 & 6) == 6;
}
uint32_t cpu_features();
}  // namespace livesync
