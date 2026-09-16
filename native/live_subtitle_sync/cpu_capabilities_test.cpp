#include "cpu_capabilities.h"

#include <cstdlib>
#include <initializer_list>

int main() {
  constexpr uint32_t all1 = (1u << 12) | (1u << 20) | (1u << 26) | (1u << 27) | (1u << 28) | (1u << 29);
  constexpr uint32_t all7 = (1u << 5) | (1u << 8);
  if (!livesync::supports_avx2(all1, all7, 6)) return EXIT_FAILURE;
  for (int bit : {12, 20, 26, 27, 28, 29}) {
    if (livesync::supports_avx2(all1 & ~(1u << bit), all7, 6)) return EXIT_FAILURE;
  }
  for (int bit : {5, 8}) {
    if (livesync::supports_avx2(all1, all7 & ~(1u << bit), 6)) return EXIT_FAILURE;
  }
  for (uint64_t state : {0, 2, 4}) {
    if (livesync::supports_avx2(all1, all7, state)) return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}
