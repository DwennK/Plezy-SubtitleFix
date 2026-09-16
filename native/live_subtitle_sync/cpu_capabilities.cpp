#include "cpu_capabilities.h"

#if defined(_WIN32) && defined(_M_X64)
#include <intrin.h>
#endif

namespace livesync {
uint32_t cpu_features() {
#if defined(_WIN32) && defined(_M_X64)
  int registers[4]{};
  __cpuid(registers, 0);
  if (registers[0] < 7) return 0;
  __cpuidex(registers, 1, 0);
  const auto ecx = static_cast<uint32_t>(registers[2]);
  // Never execute XGETBV unless CPUID says the OS enabled XSAVE.
  constexpr uint32_t xsave = (1u << 26) | (1u << 27) | (1u << 28);
  if ((ecx & xsave) != xsave) return 0;
  const uint64_t xcr0 = _xgetbv(0);
  __cpuidex(registers, 7, 0);
  return supports_avx2(ecx, static_cast<uint32_t>(registers[1]), xcr0) ? 1 : 0;
#else
  return 0;
#endif
}
}  // namespace livesync
