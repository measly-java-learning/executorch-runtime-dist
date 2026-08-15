// Proves the workspace-size backend option works end to end against a BUILT prefix: reads 0 before
// any model loads (the arena is created lazily during delegate init), rejects a write, and reads
// > 0 after loading an XNNPACK-delegated .pte. The before-reading is not decoration — without it a
// stub that always returned a constant would pass.
//   workspace_probe <model.pte> <in.bin>      (dims via env XNN_IN_DIMS, e.g. "1 3 16 16")
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

// The option is derived state, so set_option MUST reject it. This is worth asserting rather than
// assuming: the backend's set_option is a strcmp chain whose final `else` is an implicit no-op
// SUCCESS, so a key that is simply unhandled reports Error::Ok and a consumer's write looks like it
// worked. Called after the first get_option, so a failure here cannot be the backend merely being
// unregistered — that would already have failed above.
static void assert_set_option_rejected() {
  BackendOption opt{};
  std::snprintf(opt.key, sizeof(opt.key), "%s", kKey);
  opt.value = 4096; // any value; the KEY alone must be refused
  Span<BackendOption> span(&opt, 1);
  const auto err = executorch::ET_RUNTIME_NAMESPACE::set_option(kBackend, span);
  if (err != executorch::runtime::Error::InvalidArgument) {
    std::fprintf(
        stderr,
        "set_option on %s returned error %d; expected InvalidArgument (%d)\n",
        kKey,
        static_cast<int>(err),
        static_cast<int>(executorch::runtime::Error::InvalidArgument));
    std::exit(1);
  }
  std::printf("ok: set_option on %s rejected with InvalidArgument\n", kKey);
}

// Parse a space-separated dims string (e.g. "1 3 16 16") from the environment.
static std::vector<executorch::aten::SizesType> parse_dims(const char* env_name) {
  const char* env = std::getenv(env_name);
  if (!env || !*env) {
    std::fprintf(stderr, "env %s not set\n", env_name);
    std::exit(2);
  }
  std::vector<executorch::aten::SizesType> dims;
  const char* p = env;
  while (*p) {
    char* end = nullptr;
    const long v = std::strtol(p, &end, 10);
    if (end == p || v <= 0) {
      std::fprintf(stderr, "env %s has a malformed or non-positive dim\n", env_name);
      std::exit(2);
    }
    dims.push_back(static_cast<executorch::aten::SizesType>(v));
    p = end;
    while (*p == ' ') {
      ++p;
    }
  }
  return dims;
}

int main(int argc, char** argv) {
  if (argc != 3) { std::fprintf(stderr, "usage: workspace_probe model in.bin\n"); return 2; }
  const std::vector<executorch::aten::SizesType> dims = parse_dims("XNN_IN_DIMS");
  size_t n_in = 1;
  for (const auto d : dims) {
    n_in *= static_cast<size_t>(d);
  }

  const int before = read_workspace_size();
  std::printf("workspace before load: %d\n", before);
  if (before != 0) {
    std::fprintf(stderr, "expected 0 before any model loads, got %d\n", before);
    return 1;
  }

  assert_set_option_rejected();
  // A rejected write must also leave the value alone. Today the figure is computed on each read
  // rather than stored, so this cannot fail — it is here for the implementation that caches it
  // later and lets a "rejected" write mutate the cache anyway.
  const int after_rejected_write = read_workspace_size();
  if (after_rejected_write != before) {
    std::fprintf(
        stderr,
        "a rejected set_option changed the reported size: %d -> %d\n",
        before,
        after_rejected_write);
    return 1;
  }

  std::ifstream f(argv[2], std::ios::binary | std::ios::ate);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", argv[2]); return 2; }
  const std::streamsize n = f.tellg(); f.seekg(0);
  if (n % static_cast<std::streamsize>(sizeof(float)) != 0) {
    std::fprintf(stderr, "in.bin size %zu is not a multiple of float\n", static_cast<size_t>(n));
    return 2;
  }
  std::vector<float> in(static_cast<size_t>(n) / sizeof(float));
  f.read(reinterpret_cast<char*>(in.data()), n);
  if (in.size() != n_in) {
    std::fprintf(stderr, "in.bin has %zu floats, expected %zu\n", in.size(), n_in);
    return 2;
  }

  auto t_in = make_tensor_ptr(dims, in.data());
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
