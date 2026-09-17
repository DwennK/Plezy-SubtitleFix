// This includes the generated, guarded upstream implementation, not a copy of
// its decision rule. No model or audio is required for an unsupported DTW tail.
#include <cstdlib>

#include "whisper.cpp"

int main(int argc, char** argv) {
  if (argc == 2 && std::strcmp(argv[1], "--reproduce-unguarded-filter") == 0) {
    // Separate opt-in child-process proof: the upstream filter itself aborts
    // on seven audio tokens. Ordinary CTest must never invoke this mode.
    ggml_context* context = ggml_init({1024 * 1024, nullptr, false});
    ggml_tensor* input = ggml_new_tensor_3d(context, GGML_TYPE_F32, 5, 3, 7);
    ggml_tensor* output = ggml_dup_tensor(context, input);
    median_filter_user_data filter{7};
    median_filter(output, input, 0, 1, &filter);
    ggml_free(context);
    return EXIT_FAILURE;
  }
  for (const int frames : {0, 1, 2, 7, 13, 14, 15}) {
    whisper_state state{};
    state.result_all.resize(4);
    for (auto& segment : state.result_all) {
      segment.tokens.resize(2);
      for (auto& token : segment.tokens) {
        token.id = 42;
        token.p = 0.8f;
        token.t_dtw = 123;
      }
    }
    // Only segments one and two belong to the short tail. Passing no context
    // also proves the guard exits before model/decoder/attention allocation.
    whisper_exp_compute_token_level_timestamps_dtw(nullptr, &state, {}, 1, 2, 0, frames, 7, 1);
    for (size_t i = 0; i < state.result_all.size(); ++i) {
      for (const auto& token : state.result_all[i].tokens) {
        const int64_t expected = i == 1 || i == 2 ? -1 : 123;
        if (token.t_dtw != expected || token.id != 42 || token.p != 0.8f) return EXIT_FAILURE;
      }
    }
  }
  // The first supported audio axis still runs the unmodified upstream filter.
  ggml_context* context = ggml_init({1024 * 1024, nullptr, false});
  ggml_tensor* input = ggml_new_tensor_3d(context, GGML_TYPE_F32, 5, 3, 8);
  ggml_set_f32(input, 0.5f);
  ggml_tensor* output = ggml_dup_tensor(context, input);
  median_filter_user_data filter{7};
  median_filter(output, input, 0, 1, &filter);
  for (int i = 0; i < ggml_nelements(output); ++i) {
    if (ggml_get_f32_1d(output, i) != 0.5f) return EXIT_FAILURE;
  }
  ggml_free(context);
  return EXIT_SUCCESS;
}
