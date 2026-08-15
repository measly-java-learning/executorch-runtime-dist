// Loads the published OpenVINO fixture .pte and runs it against a BUILT prefix — the
// ExecuTorch half of the OpenVINO gate, which the C-API smoke stages cannot reach.
//   ov_runner <model.pte> <in.bin> <out.bin>      (dims via OV_IN / OV_OUT)
//
// Deliberately a consumer-shaped binary (find_package + Module), not ExecuTorch's
// executor_runner: this repo does not build executor_runner on Linux (it is enabled only in the
// Windows configure base), and it synthesizes its own inputs rather than reading a file, which
// makes a golden comparison impossible.
//
// The exported model is `relu(linear(x))` with the Linear weights baked in as constants, so the
// method takes a single [1, OV_IN] input and returns a single [1, OV_OUT] output.
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
  if (argc != 4) { std::fprintf(stderr, "usage: ov_runner model in.bin out.bin\n"); return 2; }
  // getenv returns null if unset — fail cleanly instead of atoi(NULL) UB.
  auto env_int = [](const char* k) -> int {
    const char* v = std::getenv(k);
    if (!v) { std::fprintf(stderr, "env %s not set\n", k); std::exit(2); }
    return std::atoi(v);
  };
  const int n_in = env_int("OV_IN");
  const int n_out = env_int("OV_OUT");

  std::vector<float> in = read_floats(argv[2]);
  if (in.size() != static_cast<size_t>(n_in)) {
    std::fprintf(stderr, "in.bin has %zu floats, OV_IN=%d\n", in.size(), n_in);
    return 2;
  }
  auto t_in = make_tensor_ptr({1, n_in}, in.data());

  Module module(argv[1]);
  std::vector<EValue> inputs = {*t_in};
  const auto res = module.forward(inputs);
  // The interesting failure lands HERE, at method init: without OPENVINO_LIB_PATH the delegate
  // cannot dlopen libopenvino_c.so and OpenvinoBackend::init fails, so the whole load fails.
  // That is the negative control the gate script asserts on.
  if (!res.ok()) {
    std::fprintf(stderr, "forward failed (error %d)\n", static_cast<int>(res.error()));
    return 1;
  }
  const auto out = res.get()[0].toTensor();
  if (out.numel() != n_out) {
    std::fprintf(stderr, "output has %lld elements, OV_OUT=%d\n",
                 static_cast<long long>(out.numel()), n_out);
    return 1;
  }

  std::ofstream of(argv[3], std::ios::binary);
  of.write(reinterpret_cast<const char*>(out.const_data_ptr<float>()),
           static_cast<std::streamsize>(out.numel()) * sizeof(float));
  return 0;
}
