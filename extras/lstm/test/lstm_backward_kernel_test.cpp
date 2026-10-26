// Analytic correctness for etnp::lstm_backward.out against vectors minted from the
// float64 AOT reference (lstm_backward_vectors.h — GENERATED). Invoked through the
// operator registry, torch-free. Covers: biases, nonzero grad_hn/grad_cn, absent
// biases (grad_b_* must still be filled), and T=1 (no recurrent gradient).
#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>

#include <executorch/extension/tensor/tensor_ptr.h>
#include <executorch/runtime/core/evalue.h>
#include <executorch/runtime/core/memory_allocator.h>
#include <executorch/runtime/core/span.h>
#include <executorch/runtime/kernel/kernel_runtime_context.h>
#include <executorch/runtime/kernel/operator_registry.h>
#include <executorch/runtime/platform/runtime.h>

#include "lstm_backward_vectors.h"

using executorch::extension::make_tensor_ptr;
using executorch::runtime::EValue;
using executorch::runtime::KernelRuntimeContext;
using executorch::runtime::MemoryAllocator;
using executorch::runtime::OpFunction;
using executorch::runtime::Span;

namespace v = etnp_test_vectors;

static int compare(const char* case_name, const char* out_name,
                   const float* got, const float* want, int64_t n) {
  for (int64_t i = 0; i < n; ++i) {
    const float tol = 1e-5f + 1e-4f * std::fabs(want[i]);
    if (!(std::fabs(got[i] - want[i]) <= tol)) {
      std::fprintf(stderr, "FAIL: case=%s out=%s idx=%lld got=%g want=%g\n",
                   case_name, out_name, static_cast<long long>(i), got[i],
                   want[i]);
      return 1;
    }
  }
  return 0;
}

static int filled_not_nan(const char* case_name, const char* out_name,
                          const float* got, int64_t n) {
  for (int64_t i = 0; i < n; ++i) {
    if (std::isnan(got[i])) {
      std::fprintf(stderr, "FAIL: case=%s out=%s idx=%lld is NaN\n", case_name,
                   out_name, static_cast<long long>(i));
      return 1;
    }
  }
  return 0;
}

int main() {
  executorch::runtime::runtime_init();
  static constexpr char kOp[] = "etnp::lstm_backward.out";
  if (!executorch::runtime::registry_has_op_function(kOp)) {
    std::fprintf(stderr, "FAIL: %s not registered\n", kOp);
    return 1;
  }
  auto fn_r = executorch::runtime::get_op_function_from_registry(kOp, {});
  if (!fn_r.ok()) {
    std::fprintf(stderr, "FAIL: lookup\n");
    return 1;
  }
  OpFunction fn = fn_r.get();

  const float nan = std::numeric_limits<float>::quiet_NaN();
  int failures = 0;
  for (int c = 0; c < v::num_cases; ++c) {
    const v::Case& cs = v::cases[c];
    const int T = static_cast<int>(cs.T), B = static_cast<int>(cs.B),
        I = static_cast<int>(cs.I), H = static_cast<int>(cs.H);
    const int n_in = T * B * I, n_bh = B * H, n_b = 4 * H;

    auto cpy = [](const float* p, int64_t n) {
      return std::vector<float>(p, p + n);
    };
    auto input = cpy(cs.input, n_in);
    auto h0 = cpy(cs.h0, n_bh), c0 = cpy(cs.c0, n_bh);
    auto w_ih = cpy(cs.w_ih, n_b * I), w_hh = cpy(cs.w_hh, n_b * H);
    auto grad_output = cpy(cs.grad_output, T * B * H);
    std::vector<float> b_ih, b_hh, grad_hn, grad_cn;
    if (cs.has_bias) {
      b_ih = cpy(cs.b_ih, n_b);
      b_hh = cpy(cs.b_hh, n_b);
    }
    if (cs.has_grad_state) {
      grad_hn = cpy(cs.grad_hn, n_bh);
      grad_cn = cpy(cs.grad_cn, n_bh);
    }
    // Absent optionals still need a tensor pointer (content/shape unused: the
    // stack slot is passed as None).
    std::vector<float> dummy_bh(n_bh, 0.0f), dummy_b(n_b, 0.0f);

    std::vector<float> grad_input(n_in, nan), grad_h0(n_bh, nan),
        grad_c0(n_bh, nan), grad_w_ih(n_b * I, nan), grad_w_hh(n_b * H, nan),
        grad_b_ih(n_b, nan), grad_b_hh(n_b, nan);

    auto t_in = make_tensor_ptr({T, B, I}, input.data());
    auto t_h0 = make_tensor_ptr({B, H}, h0.data());
    auto t_c0 = make_tensor_ptr({B, H}, c0.data());
    auto t_wih = make_tensor_ptr({n_b, I}, w_ih.data());
    auto t_whh = make_tensor_ptr({n_b, H}, w_hh.data());
    auto t_go = make_tensor_ptr({T, B, H}, grad_output.data());
    auto t_ghn = make_tensor_ptr(
        {B, H}, grad_hn.empty() ? dummy_bh.data() : grad_hn.data());
    auto t_gcn = make_tensor_ptr(
        {B, H}, grad_cn.empty() ? dummy_bh.data() : grad_cn.data());
    auto t_bih = make_tensor_ptr(
        {n_b}, b_ih.empty() ? dummy_b.data() : b_ih.data());
    auto t_bhh = make_tensor_ptr(
        {n_b}, b_hh.empty() ? dummy_b.data() : b_hh.data());
    auto t_gin = make_tensor_ptr({T, B, I}, grad_input.data());
    auto t_gh0 = make_tensor_ptr({B, H}, grad_h0.data());
    auto t_gc0 = make_tensor_ptr({B, H}, grad_c0.data());
    auto t_gwih = make_tensor_ptr({n_b, I}, grad_w_ih.data());
    auto t_gwhh = make_tensor_ptr({n_b, H}, grad_w_hh.data());
    auto t_gbih = make_tensor_ptr({n_b}, grad_b_ih.data());
    auto t_gbhh = make_tensor_ptr({n_b}, grad_b_hh.data());

    EValue ev[] = {
        EValue(*t_go),
        cs.has_grad_state ? EValue(*t_ghn) : EValue(),
        cs.has_grad_state ? EValue(*t_gcn) : EValue(),
        EValue(*t_in), EValue(*t_h0), EValue(*t_c0),
        EValue(*t_wih), EValue(*t_whh),
        cs.has_bias ? EValue(*t_bih) : EValue(),
        cs.has_bias ? EValue(*t_bhh) : EValue(),
        EValue(*t_gin), EValue(*t_gh0), EValue(*t_gc0),
        EValue(*t_gwih), EValue(*t_gwhh), EValue(*t_gbih), EValue(*t_gbhh)};
    EValue* args[17];
    for (int i = 0; i < 17; ++i) {
      args[i] = &ev[i];
    }

    std::vector<uint8_t> temp_buf(4 * 1024 * 1024);
    MemoryAllocator temp_alloc(
        static_cast<uint32_t>(temp_buf.size()), temp_buf.data());
    KernelRuntimeContext ctx(/*event_tracer=*/nullptr, &temp_alloc);
    fn(ctx, Span<EValue*>(args, 17));

    failures |= compare(cs.name, "grad_input", grad_input.data(),
                        cs.grad_input, n_in);
    failures |= compare(cs.name, "grad_h0", grad_h0.data(), cs.grad_h0, n_bh);
    failures |= compare(cs.name, "grad_c0", grad_c0.data(), cs.grad_c0, n_bh);
    failures |= compare(cs.name, "grad_w_ih", grad_w_ih.data(), cs.grad_w_ih,
                        n_b * I);
    failures |= compare(cs.name, "grad_w_hh", grad_w_hh.data(), cs.grad_w_hh,
                        n_b * H);
    if (cs.has_bias) {
      failures |= compare(cs.name, "grad_b_ih", grad_b_ih.data(), cs.grad_b_ih,
                          n_b);
      failures |= compare(cs.name, "grad_b_hh", grad_b_hh.data(), cs.grad_b_hh,
                          n_b);
    } else {
      // Absent bias => the op still has to fill these (always-finite outputs).
      failures |= filled_not_nan(cs.name, "grad_b_ih", grad_b_ih.data(), n_b);
      failures |= filled_not_nan(cs.name, "grad_b_hh", grad_b_hh.data(), n_b);
    }
  }

  if (failures == 0) {
    std::printf("OK: etnp::lstm_backward.out\n");
  }
  return failures == 0 ? 0 : 1;
}
