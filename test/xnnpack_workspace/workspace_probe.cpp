// Proves the workspace-size backend option works end to end against a BUILT prefix: reads 0 before
// any model loads (the arena is created lazily during delegate init), and > 0 after loading an
// XNNPACK-delegated .pte. The before-reading is not decoration — without it a stub that always
// returned a constant would pass.
//   workspace_probe <model.pte> <in.bin>      (dims via XNN_IN)
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>

#include <executorch/extension/module/module.h>
#include <executorch/extension/tensor/tensor_ptr.h>
#include <executorch/runtime/backend/interface.h>
#include <executorch/runtime/backend/options.h>

using executorch::extension::Module;
using executorch::extension::make_tensor_ptr;
using executorch::runtime::BackendOption;
using executorch::runtime::EValue;
using executorch::runtime::Span;

// Hardcoded, not included: XNNPACKBackend.h is not an installed header, so a consumer names these
// by string exactly as this probe does. That makes the probe a real test of the published contract.
static constexpr const char* kBackend = "XnnpackBackend";
static constexpr const char* kKey = "workspace_size_bytes";

static int read_workspace_size() {
  BackendOption opt{};
  std::snprintf(opt.key, sizeof(opt.key), "%s", kKey);
  Span<BackendOption> span(&opt, 1);
  const auto err = executorch::ET_RUNTIME_NAMESPACE::get_option(kBackend, span);
  if (err != executorch::runtime::Error::Ok) {
    std::fprintf(stderr, "get_option failed (error %d)\n", static_cast<int>(err));
    std::exit(1);
  }
  auto* val = std::get_if<int>(&opt.value);
  if (!val) {
    std::fprintf(stderr, "workspace_size_bytes is not an int\n");
    std::exit(1);
  }
  return *val;
}

int main(int argc, char** argv) {
  if (argc != 3) { std::fprintf(stderr, "usage: workspace_probe model in.bin\n"); return 2; }
  const char* dim_env = std::getenv("XNN_IN");
  if (!dim_env) { std::fprintf(stderr, "env XNN_IN not set\n"); return 2; }
  const int n_in = std::atoi(dim_env);

  const int before = read_workspace_size();
  std::printf("workspace before load: %d\n", before);
  if (before != 0) {
    std::fprintf(stderr, "expected 0 before any model loads, got %d\n", before);
    return 1;
  }

  std::ifstream f(argv[2], std::ios::binary | std::ios::ate);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", argv[2]); return 2; }
  const std::streamsize n = f.tellg(); f.seekg(0);
  std::vector<float> in(static_cast<size_t>(n) / sizeof(float));
  f.read(reinterpret_cast<char*>(in.data()), n);
  if (in.size() != static_cast<size_t>(n_in)) {
    std::fprintf(stderr, "in.bin has %zu floats, XNN_IN=%d\n", in.size(), n_in);
    return 2;
  }

  auto t_in = make_tensor_ptr({1, n_in}, in.data());
  Module module(argv[1]);
  std::vector<EValue> inputs = {*t_in};
  const auto res = module.forward(inputs);
  if (!res.ok()) {
    std::fprintf(stderr, "forward failed (error %d)\n", static_cast<int>(res.error()));
    return 1;
  }

  const int after = read_workspace_size();
  std::printf("workspace after load: %d\n", after);
  if (after <= 0) {
    std::fprintf(stderr, "expected a non-zero workspace after loading a delegated model\n");
    return 1;
  }
  std::printf("PROBE PASS: workspace grew from 0 to %d bytes\n", after);
  return 0;
}
