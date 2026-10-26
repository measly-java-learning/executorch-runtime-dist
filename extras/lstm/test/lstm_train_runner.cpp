// Loads a TRAINING .pte with external mutable weights (.ptd) and runs the joint
// forward+backward method, writing the loss and parameter gradients as flat
// float32. Torch-free; the weights/config come from the same case module the live
// Python round-trip and the fixture emitter use.
//   lstm_train_runner <train.pte> <train.ptd> <train_in.bin> <out.bin>
// Dims via env TRAIN_T/B/I/O. train_in.bin = x[T,B,I] ++ target[B,O].
// Optional TRAIN_STEPS (default 1) and TRAIN_LR (default 0): between steps the
// runner applies a dense in-place SGD update to the parameter outputs, which alias
// the external weight buffers. Step k>0 therefore exercises the forward op's
// packed-weight cache with MUTATED weights — the training pattern.
// Outputs = per step, the program's outputs [0, parameter_start): loss, then
// gradients in the order the joint graph declares (the Python side records FQNs).
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>

#include <executorch/extension/module/module.h>
#include <executorch/extension/tensor/tensor_ptr.h>

using executorch::extension::Module;
using executorch::extension::make_tensor_ptr;
using executorch::runtime::EValue;

static std::vector<float> read_floats(const char* p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p); std::exit(2); }
  const std::streamsize n = f.tellg(); f.seekg(0);
  std::vector<float> v(static_cast<size_t>(n) / sizeof(float));
  f.read(reinterpret_cast<char*>(v.data()), n);
  return v;
}

// Positive env int. A missing value uses `fallback`; `fallback < 0` makes the
// variable required. Malformed values are an error, never a silent 0.
static int env_int(const char* k, int fallback) {
  const char* v = std::getenv(k);
  if (v == nullptr || *v == '\0') {
    if (fallback >= 0) return fallback;
    std::fprintf(stderr, "env %s not set\n", k);
    std::exit(2);
  }
  errno = 0;
  char* end = nullptr;
  const long n = std::strtol(v, &end, 10);
  if (errno != 0 || end == v || *end != '\0' || n <= 0 || n > 1000000) {
    std::fprintf(stderr, "env %s invalid: %s\n", k, v);
    std::exit(2);
  }
  return static_cast<int>(n);
}

static float env_float(const char* k, float fallback) {
  const char* v = std::getenv(k);
  if (v == nullptr || *v == '\0') return fallback;
  errno = 0;
  char* end = nullptr;
  const float f = std::strtof(v, &end);
  if (errno != 0 || end == v || *end != '\0' || !(f >= 0.0f)) {
    std::fprintf(stderr, "env %s invalid: %s\n", k, v);
    std::exit(2);
  }
  return f;
}

int main(int argc, char** argv) {
  if (argc != 5) {
    std::fprintf(stderr,
                 "usage: lstm_train_runner model.pte weights.ptd in.bin out.bin\n");
    return 2;
  }
  const int T = env_int("TRAIN_T", -1);
  const int B = env_int("TRAIN_B", -1);
  const int I = env_int("TRAIN_I", -1);
  const int O = env_int("TRAIN_O", -1);
  const int steps = env_int("TRAIN_STEPS", 1);
  const float lr = env_float("TRAIN_LR", 0.0f);

  std::vector<float> blob = read_floats(argv[3]);
  const int64_t expected =
      static_cast<int64_t>(T) * B * I + static_cast<int64_t>(B) * O;
  if (static_cast<int64_t>(blob.size()) != expected) {
    std::fprintf(stderr,
                 "train_in.bin has %zu floats, expected %lld for "
                 "TRAIN_T/B/I/O=%d/%d/%d/%d\n",
                 blob.size(), static_cast<long long>(expected), T, B, I, O);
    return 2;
  }
  const float* x = blob.data();
  const float* target = blob.data() + static_cast<size_t>(T) * B * I;

  auto t_x = make_tensor_ptr({T, B, I}, const_cast<float*>(x));
  auto t_target = make_tensor_ptr({B, O}, const_cast<float*>(target));

  // External weights: the .pte holds none of the trainable parameters.
  Module module(argv[1], argv[2]);

  // Where do the parameter (weight) outputs start, and the gradients? The
  // metadata methods are emitted for every joint graph.
  auto gaindx = module.get("__et_training_gradients_index_forward");
  auto idx_res = module.get("__et_training_parameters_index_forward");
  if (!gaindx.ok() || !idx_res.ok()) {
    std::fprintf(stderr,
                 "training metadata missing (__et_training_*_index_forward) — "
                 "is this a joint forward+backward .pte?\n");
    return 1;
  }
  const int64_t grad_start = gaindx.get().toInt();
  const int64_t param_start = idx_res.get().toInt();

  std::vector<EValue> outs;
  std::ofstream of(argv[4], std::ios::binary);
  for (int step = 0; step < steps; ++step) {
    if (step > 0) {
      const int64_t n_params =
          static_cast<int64_t>(outs.size()) - param_start;
      if (lr == 0.0f || n_params <= 0 ||
          grad_start + n_params != param_start) {
        std::fprintf(stderr,
                     "cannot update: grad_start=%lld param_start=%lld "
                     "outputs=%zu\n",
                     static_cast<long long>(grad_start),
                     static_cast<long long>(param_start), outs.size());
        return 1;
      }
      // Dense in-place SGD on the parameter outputs (they alias the external
      // weight buffers, so the next execute reads the updated weights).
      for (int64_t i = 0; i < n_params; ++i) {
        auto p = outs[static_cast<size_t>(param_start + i)].toTensor();
        auto g = outs[static_cast<size_t>(grad_start + i)].toTensor();
        float* pd = p.mutable_data_ptr<float>();
        const float* gd = g.const_data_ptr<float>();
        for (int64_t k = 0; k < p.numel(); ++k) {
          pd[k] -= lr * gd[k];
        }
      }
    }

    auto res = module.forward({EValue(*t_x), EValue(*t_target)});
    if (!res.ok()) {
      std::fprintf(stderr, "forward failed (step %d)\n", step);
      return 1;
    }
    outs = res.get();
    if (param_start <= 0 ||
        static_cast<size_t>(param_start) > outs.size()) {
      std::fprintf(stderr, "bad parameter boundary %lld (outputs=%zu)\n",
                   static_cast<long long>(param_start), outs.size());
      return 1;
    }
    for (int64_t i = 0; i < param_start; ++i) {
      const auto& t = outs[static_cast<size_t>(i)].toTensor();
      of.write(reinterpret_cast<const char*>(t.const_data_ptr<float>()),
               static_cast<std::streamsize>(t.numel()) * sizeof(float));
    }
  }
  return 0;
}
