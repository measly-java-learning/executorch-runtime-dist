// Loads a TRAINING .pte with external mutable weights (.ptd) and runs the joint
// forward+backward method once, writing the loss and parameter gradients as flat
// float32. Torch-free; the weights/config come from the same case module the live
// Python round-trip and the fixture emitter use.
//   lstm_train_runner <train.pte> <train.ptd> <train_in.bin> <out.bin>
// Dims via env TRAIN_T/B/I/O. train_in.bin = x[T,B,I] ++ target[B,O].
// Outputs = the program's outputs [0, parameter_start) — loss, then gradients in
// the order the joint graph declares (the Python side records the FQNs).
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

int main(int argc, char** argv) {
  if (argc != 5) {
    std::fprintf(stderr, "usage: lstm_train_runner model.pte weights.ptd in.bin out.bin\n");
    return 2;
  }
  auto env_int = [](const char* k) -> int {
    const char* v = std::getenv(k);
    if (!v) { std::fprintf(stderr, "env %s not set\n", k); std::exit(2); }
    return std::atoi(v);
  };
  const int T = env_int("TRAIN_T");
  const int B = env_int("TRAIN_B");
  const int I = env_int("TRAIN_I");
  const int O = env_int("TRAIN_O");

  std::vector<float> blob = read_floats(argv[3]);
  size_t off = 0;
  auto take = [&](size_t n) { const float* p = blob.data() + off; off += n; return p; };
  auto x = take(static_cast<size_t>(T) * B * I);
  auto target = take(static_cast<size_t>(B) * O);

  auto t_x = make_tensor_ptr({T, B, I}, const_cast<float*>(x));
  auto t_target = make_tensor_ptr({B, O}, const_cast<float*>(target));

  // External weights: the .pte holds none of the trainable parameters.
  Module module(argv[1], argv[2]);

  // Where do the parameter (weight) outputs start? Gradients run up to here; the
  // metadata method is emitted for every joint graph.
  auto idx_res = module.get("__et_training_parameters_index_forward");
  if (!idx_res.ok()) {
    std::fprintf(stderr,
                 "training metadata missing (__et_training_parameters_index_forward) "
                 "— is this a joint forward+backward .pte?\n");
    return 1;
  }
  const int64_t param_start = idx_res.get().toInt();

  auto res = module.forward({EValue(*t_x), EValue(*t_target)});
  if (!res.ok()) { std::fprintf(stderr, "forward failed\n"); return 1; }
  const std::vector<EValue>& outs = res.get();
  if (param_start <= 0 || static_cast<size_t>(param_start) > outs.size()) {
    std::fprintf(stderr, "bad gradient boundary %lld (outputs=%zu)\n",
                 static_cast<long long>(param_start), outs.size());
    return 1;
  }

  std::ofstream of(argv[4], std::ios::binary);
  for (int64_t i = 0; i < param_start; ++i) {
    const auto& t = outs[static_cast<size_t>(i)].toTensor();
    of.write(reinterpret_cast<const char*>(t.const_data_ptr<float>()),
             static_cast<std::streamsize>(t.numel()) * sizeof(float));
  }
  return 0;
}
