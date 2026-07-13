// Loads a .pte using etnp::lstm.out and runs it against the BUILT tarball —
// the first real exercise of the shipped consumer contract (whole-archived via
// ETNPExtras.cmake). Reads flat little-endian float32 inputs, writes float32 output.
//   lstm_runner <model.pte> <inputs.bin> <out.bin>
// inputs.bin = concat of input,h0,c0 (row-major). The exported .pte bakes the LSTM
// weights (w_ih, w_hh, b_ih, b_hh) as CONSTANTS (they are plain tensor attributes on
// the traced nn.Module, not graph inputs) — torch.export lifts them out of forward's
// argument list, so the exported method takes only (x, h0, c0). Verified empirically:
// the brief originally assumed a 7-input forward (weights passed at runtime); that
// is wrong for this export recipe and is corrected here to the observed 3-input arity.
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
  if (argc != 4) { std::fprintf(stderr, "usage: lstm_runner model inputs out\n"); return 2; }
  // Shapes are fixed by the test that generates inputs.bin (see the .py).
  // T,B,I,H are passed via env to keep the runner tiny and shape-agnostic.
  // getenv returns null if unset — fail cleanly instead of atoi(NULL) UB.
  auto env_int = [](const char* k) -> int {
    const char* v = std::getenv(k);
    if (!v) { std::fprintf(stderr, "env %s not set\n", k); std::exit(2); }
    return std::atoi(v);
  };
  const int T = env_int("LSTM_T");
  const int B = env_int("LSTM_B");
  const int I = env_int("LSTM_I");
  const int H = env_int("LSTM_H");

  std::vector<float> blob = read_floats(argv[2]);
  size_t off = 0;
  auto take = [&](size_t n) { const float* p = blob.data() + off; off += n; return p; };
  auto in  = take((size_t)T * B * I);
  auto h0  = take((size_t)B * H);
  auto c0  = take((size_t)B * H);

  auto t_in  = make_tensor_ptr({T, B, I}, const_cast<float*>(in));
  auto t_h0  = make_tensor_ptr({B, H},   const_cast<float*>(h0));
  auto t_c0  = make_tensor_ptr({B, H},   const_cast<float*>(c0));

  Module module(argv[1]);
  std::vector<EValue> inputs = {*t_in, *t_h0, *t_c0};
  const auto res = module.forward(inputs);
  if (!res.ok()) { std::fprintf(stderr, "forward failed\n"); return 1; }
  const auto out = res.get()[0].toTensor();  // output [T,B,H]

  std::ofstream of(argv[3], std::ios::binary);
  of.write(reinterpret_cast<const char*>(out.const_data_ptr<float>()),
           (std::streamsize)out.numel() * sizeof(float));
  return 0;
}
