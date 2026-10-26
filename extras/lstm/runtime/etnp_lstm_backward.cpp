// etnp::lstm_backward.out — gradients for etnp::lstm.out. Scalar float32, single-
// threaded, no XNNPACK/Highway/threadpool and no call into the forward kernel (so
// it cannot perturb forward behaviour). Cost is linear in T: one forward recompute
// that saves the per-step gate activations/cell states, then one reverse sweep.
//
// Schema (see extras/lstm/extra.yaml):
//   lstm_backward.out(Tensor grad_output, Tensor? grad_hn, Tensor? grad_cn,
//                     Tensor input, Tensor h0, Tensor c0, Tensor w_ih,
//                     Tensor w_hh, Tensor? b_ih, Tensor? b_hh, *,
//                     Tensor(a!) grad_input, Tensor(b!) grad_h0, Tensor(c!) grad_c0,
//                     Tensor(d!) grad_w_ih, Tensor(e!) grad_w_hh,
//                     Tensor(f!) grad_b_ih, Tensor(g!) grad_b_hh)
//   input [T,B,I]  h0/c0 [B,H]  w_ih [4H,I]  w_hh [4H,H]  b_ih/b_hh [4H]
//   grad_output [T,B,H]  grad_hn/grad_cn [B,H] (None => zero)
//   Gate row order: i,f,g,o (PyTorch).
#include <cmath>
#include <cstring>
#include <optional>
#include <tuple>

#include <executorch/runtime/core/evalue.h>
#include <executorch/runtime/core/span.h>
#include <executorch/runtime/kernel/kernel_includes.h>
#include <executorch/runtime/kernel/operator_registry.h>

#include "etnp_lstm_schema.h"  // GENERATED — op-name constants (single source of truth)

namespace etnp {
namespace {
using executorch::aten::ScalarType;
using executorch::aten::SizesType;
using executorch::aten::Tensor;
using executorch::runtime::Error;
using executorch::runtime::EValue;
using executorch::runtime::KernelRuntimeContext;

inline float sigmoidf(float x) { return 1.0f / (1.0f + std::exp(-x)); }

std::tuple<Tensor&, Tensor&, Tensor&, Tensor&, Tensor&, Tensor&, Tensor&>
lstm_backward_out(
    KernelRuntimeContext& ctx,
    const Tensor& grad_output, const std::optional<Tensor>& grad_hn,
    const std::optional<Tensor>& grad_cn,
    const Tensor& input, const Tensor& h0, const Tensor& c0,
    const Tensor& w_ih, const Tensor& w_hh,
    const std::optional<Tensor>& b_ih, const std::optional<Tensor>& b_hh,
    Tensor& grad_input, Tensor& grad_h0, Tensor& grad_c0,
    Tensor& grad_w_ih, Tensor& grad_w_hh,
    Tensor& grad_b_ih, Tensor& grad_b_hh) {
  auto ret = std::tie(grad_input, grad_h0, grad_c0, grad_w_ih, grad_w_hh,
                      grad_b_ih, grad_b_hh);

  ET_KERNEL_CHECK(ctx, input.dim() == 3 && h0.dim() == 2, InvalidArgument, ret);
  const int64_t T = input.size(0);
  const int64_t B = input.size(1);
  const int64_t I = input.size(2);
  const int64_t H = h0.size(1);

  ET_KERNEL_CHECK(ctx, input.scalar_type() == ScalarType::Float, InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx, grad_output.scalar_type() == ScalarType::Float,
                  InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx, h0.scalar_type() == ScalarType::Float &&
                          c0.scalar_type() == ScalarType::Float &&
                          w_ih.scalar_type() == ScalarType::Float &&
                          w_hh.scalar_type() == ScalarType::Float,
                  InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
                  grad_output.dim() == 3 && grad_output.size(0) == T &&
                      grad_output.size(1) == B && grad_output.size(2) == H,
                  InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
                  h0.dim() == 2 && h0.size(0) == B && c0.dim() == 2 &&
                      c0.size(0) == B && c0.size(1) == H,
                  InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx, w_ih.dim() == 2 && w_ih.size(0) == 4 * H &&
                          w_ih.size(1) == I,
                  InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx, w_hh.dim() == 2 && w_hh.size(0) == 4 * H &&
                          w_hh.size(1) == H,
                  InvalidArgument, ret);
  if (grad_hn.has_value()) {
    ET_KERNEL_CHECK(ctx, grad_hn->scalar_type() == ScalarType::Float &&
                            grad_hn->dim() == 2 && grad_hn->size(0) == B &&
                            grad_hn->size(1) == H,
                    InvalidArgument, ret);
  }
  if (grad_cn.has_value()) {
    ET_KERNEL_CHECK(ctx, grad_cn->scalar_type() == ScalarType::Float &&
                            grad_cn->dim() == 2 && grad_cn->size(0) == B &&
                            grad_cn->size(1) == H,
                    InvalidArgument, ret);
  }
  if (b_ih.has_value()) {
    ET_KERNEL_CHECK(ctx, b_ih->scalar_type() == ScalarType::Float &&
                            b_ih->dim() == 1 && b_ih->size(0) == 4 * H,
                    InvalidArgument, ret);
  }
  if (b_hh.has_value()) {
    ET_KERNEL_CHECK(ctx, b_hh->scalar_type() == ScalarType::Float &&
                            b_hh->dim() == 1 && b_hh->size(0) == 4 * H,
                    InvalidArgument, ret);
  }
  // The kernel writes every output as float; a non-fp32 output buffer would
  // abort inside mutable_data_ptr<float>() (or write at the wrong stride).
  ET_KERNEL_CHECK(ctx,
                  grad_input.scalar_type() == ScalarType::Float &&
                      grad_h0.scalar_type() == ScalarType::Float &&
                      grad_c0.scalar_type() == ScalarType::Float &&
                      grad_w_ih.scalar_type() == ScalarType::Float &&
                      grad_w_hh.scalar_type() == ScalarType::Float &&
                      grad_b_ih.scalar_type() == ScalarType::Float &&
                      grad_b_hh.scalar_type() == ScalarType::Float,
                  InvalidArgument, ret);

  const SizesType gi_sz[3] = {static_cast<SizesType>(T),
                              static_cast<SizesType>(B),
                              static_cast<SizesType>(I)};
  const SizesType bh_sz[2] = {static_cast<SizesType>(B),
                              static_cast<SizesType>(H)};
  const SizesType wih_sz[2] = {static_cast<SizesType>(4 * H),
                               static_cast<SizesType>(I)};
  const SizesType whh_sz[2] = {static_cast<SizesType>(4 * H),
                               static_cast<SizesType>(H)};
  const SizesType b_sz[1] = {static_cast<SizesType>(4 * H)};
  ET_KERNEL_CHECK(ctx,
      executorch::runtime::resize_tensor(grad_input, {gi_sz, 3}) == Error::Ok,
      InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
      executorch::runtime::resize_tensor(grad_h0, {bh_sz, 2}) == Error::Ok,
      InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
      executorch::runtime::resize_tensor(grad_c0, {bh_sz, 2}) == Error::Ok,
      InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
      executorch::runtime::resize_tensor(grad_w_ih, {wih_sz, 2}) == Error::Ok,
      InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
      executorch::runtime::resize_tensor(grad_w_hh, {whh_sz, 2}) == Error::Ok,
      InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
      executorch::runtime::resize_tensor(grad_b_ih, {b_sz, 1}) == Error::Ok,
      InvalidArgument, ret);
  ET_KERNEL_CHECK(ctx,
      executorch::runtime::resize_tensor(grad_b_hh, {b_sz, 1}) == Error::Ok,
      InvalidArgument, ret);

  const size_t BH = static_cast<size_t>(B) * static_cast<size_t>(H);
  const size_t TBH = static_cast<size_t>(T) * BH;
  const size_t col = 4 * static_cast<size_t>(H);
  // Scratch: h_prev[T], c_prev[T], i,f,g,o (post-activation) [T], tanh(c_t)[T],
  // then dh [B,H], dc [B,H], dgate [B,4H], db [4H].
  const size_t scratch_floats =
      7 * TBH + 2 * BH + static_cast<size_t>(B) * col + col;
  auto scratch_r = ctx.allocate_temp(scratch_floats * sizeof(float));
  ET_KERNEL_CHECK(ctx, scratch_r.ok(), MemoryAllocationFailed, ret);
  float* scratch = static_cast<float*>(scratch_r.get());
  float* h_prev = scratch;                 // h_{t-1}, h_prev[0] = h0
  float* c_prev = h_prev + TBH;            // c_{t-1}, c_prev[0] = c0
  float* gate_i = c_prev + TBH;
  float* gate_f = gate_i + TBH;
  float* gate_g = gate_f + TBH;
  float* gate_o = gate_g + TBH;
  float* tanh_c = gate_o + TBH;            // tanh(c_t), reused by the sweep
  float* dh = tanh_c + TBH;
  float* dc = dh + BH;
  float* dgate = dc + BH;
  float* db = dgate + static_cast<size_t>(B) * col;

  const float* in = input.const_data_ptr<float>();
  const float* wi = w_ih.const_data_ptr<float>();
  const float* wh = w_hh.const_data_ptr<float>();
  const float* bi = b_ih.has_value() ? b_ih->const_data_ptr<float>() : nullptr;
  const float* bh = b_hh.has_value() ? b_hh->const_data_ptr<float>() : nullptr;
  const float* go = grad_output.const_data_ptr<float>();

  // ---- forward recompute (same semantics/layout as etnp::lstm.out) ----------
  std::memcpy(h_prev, h0.const_data_ptr<float>(), BH * sizeof(float));
  std::memcpy(c_prev, c0.const_data_ptr<float>(), BH * sizeof(float));
  for (int64_t t = 0; t < T; ++t) {
    const float* x_t = in + static_cast<size_t>(t) * B * I;
    const float* hp = h_prev + static_cast<size_t>(t) * BH;
    const float* cp = c_prev + static_cast<size_t>(t) * BH;
    float* i_t = gate_i + static_cast<size_t>(t) * BH;
    float* f_t = gate_f + static_cast<size_t>(t) * BH;
    float* g_t = gate_g + static_cast<size_t>(t) * BH;
    float* o_t = gate_o + static_cast<size_t>(t) * BH;
    float* tc_t = tanh_c + static_cast<size_t>(t) * BH;
    float* h_next = (t + 1 < T) ? h_prev + static_cast<size_t>(t + 1) * BH
                                : nullptr;
    float* c_next = (t + 1 < T) ? c_prev + static_cast<size_t>(t + 1) * BH
                                : nullptr;
    for (int64_t b = 0; b < B; ++b) {
      const float* xb = x_t + b * I;
      const float* hb = hp + b * H;
      const float* cb = cp + b * H;
      const size_t ob = static_cast<size_t>(b) * H;
      for (int64_t j = 0; j < H; ++j) {
        const size_t row = static_cast<size_t>(j);
        float si = bi ? bi[row] : 0.0f;
        float sf = bi ? bi[H + row] : 0.0f;
        float sg = bi ? bi[2 * H + row] : 0.0f;
        float so = bi ? bi[3 * H + row] : 0.0f;
        if (bh) {
          si += bh[row];
          sf += bh[H + row];
          sg += bh[2 * H + row];
          so += bh[3 * H + row];
        }
        for (int64_t k = 0; k < I; ++k) {
          const float xk = xb[k];
          si += wi[row * I + k] * xk;
          sf += wi[(H + row) * I + k] * xk;
          sg += wi[(2 * H + row) * I + k] * xk;
          so += wi[(3 * H + row) * I + k] * xk;
        }
        for (int64_t k = 0; k < H; ++k) {
          const float hk = hb[k];
          si += wh[row * H + k] * hk;
          sf += wh[(H + row) * H + k] * hk;
          sg += wh[(2 * H + row) * H + k] * hk;
          so += wh[(3 * H + row) * H + k] * hk;
        }
        const float iv = sigmoidf(si);
        const float fv = sigmoidf(sf);
        const float gv = std::tanh(sg);
        const float ov = sigmoidf(so);
        const float cv = fv * cb[j] + iv * gv;
        const float tc = std::tanh(cv);
        i_t[ob + j] = iv;
        f_t[ob + j] = fv;
        g_t[ob + j] = gv;
        o_t[ob + j] = ov;
        tc_t[ob + j] = tc;
        if (h_next) {
          h_next[ob + j] = ov * tc;
          c_next[ob + j] = cv;
        }
      }
    }
  }

  // ---- reverse sweep --------------------------------------------------------
  float* gwih = grad_w_ih.mutable_data_ptr<float>();
  float* gwhh = grad_w_hh.mutable_data_ptr<float>();
  float* gin = grad_input.mutable_data_ptr<float>();
  float* gb = db;   // bias sum; written out only for the biases that exist
  std::memset(gwih, 0, col * I * sizeof(float));
  std::memset(gwhh, 0, col * H * sizeof(float));
  std::memset(gb, 0, col * sizeof(float));

  if (grad_hn.has_value()) {
    std::memcpy(dh, grad_hn->const_data_ptr<float>(), BH * sizeof(float));
  } else {
    std::memset(dh, 0, BH * sizeof(float));
  }
  if (grad_cn.has_value()) {
    std::memcpy(dc, grad_cn->const_data_ptr<float>(), BH * sizeof(float));
  } else {
    std::memset(dc, 0, BH * sizeof(float));
  }

  for (int64_t t = T - 1; t >= 0; --t) {
    const float* x_t = in + static_cast<size_t>(t) * B * I;
    const float* hp = h_prev + static_cast<size_t>(t) * BH;
    const float* cp = c_prev + static_cast<size_t>(t) * BH;
    const float* i_t = gate_i + static_cast<size_t>(t) * BH;
    const float* f_t = gate_f + static_cast<size_t>(t) * BH;
    const float* g_t = gate_g + static_cast<size_t>(t) * BH;
    const float* o_t = gate_o + static_cast<size_t>(t) * BH;
    const float* tc_t = tanh_c + static_cast<size_t>(t) * BH;
    const float* go_t = go + static_cast<size_t>(t) * BH;
    float* gin_t = gin + static_cast<size_t>(t) * B * I;

    for (size_t idx = 0; idx < BH; ++idx) {
      dh[idx] += go_t[idx];
    }
    for (int64_t b = 0; b < B; ++b) {
      const size_t ob = static_cast<size_t>(b) * H;
      for (int64_t j = 0; j < H; ++j) {
        const size_t p = ob + j;
        const float iv = i_t[p], fv = f_t[p], gv = g_t[p], ov = o_t[p];
        const float tc = tc_t[p];
        const float d_o = dh[p] * tc * ov * (1.0f - ov);
        dc[p] += dh[p] * ov * (1.0f - tc * tc);
        const float d_i = dc[p] * gv * iv * (1.0f - iv);
        const float d_f = dc[p] * cp[p] * fv * (1.0f - fv);
        const float d_g = dc[p] * iv * (1.0f - gv * gv);
        const size_t r = static_cast<size_t>(b) * col + j;
        dgate[r] = d_i;
        dgate[r + H] = d_f;
        dgate[r + 2 * H] = d_g;
        dgate[r + 3 * H] = d_o;
        // Gradient wrt c_{t-1} flows through the forget gate.
        dc[p] *= fv;
      }
    }

    // Weight/bias gradients: dW_ih += dgate^T x_t, dW_hh += dgate^T h_{t-1},
    // db += sum_b dgate.
    for (int64_t b = 0; b < B; ++b) {
      const size_t base = static_cast<size_t>(b) * col;
      const float* xb = x_t + b * I;
      const float* hb = hp + b * H;
      for (size_t r = 0; r < col; ++r) {
        const float d = dgate[base + r];
        float* wr = gwih + r * I;
        for (int64_t k = 0; k < I; ++k) {
          wr[k] += d * xb[k];
        }
        float* hr = gwhh + r * H;
        for (int64_t k = 0; k < H; ++k) {
          hr[k] += d * hb[k];
        }
        gb[r] += d;
      }
    }

    // grad_input_t = dgate @ W_ih and dh_{t-1} = dgate @ W_hh.
    for (int64_t b = 0; b < B; ++b) {
      const size_t base = static_cast<size_t>(b) * col;
      float* xb = gin_t + b * I;
      for (int64_t k = 0; k < I; ++k) {
        float s = 0.0f;
        for (size_t r = 0; r < col; ++r) {
          s += dgate[base + r] * wi[r * I + k];
        }
        xb[k] = s;
      }
      float* hb = dh + b * H;
      for (int64_t k = 0; k < H; ++k) {
        float s = 0.0f;
        for (size_t r = 0; r < col; ++r) {
          s += dgate[base + r] * wh[r * H + k];
        }
        hb[k] = s;
      }
    }
  }

  std::memcpy(grad_h0.mutable_data_ptr<float>(), dh, BH * sizeof(float));
  std::memcpy(grad_c0.mutable_data_ptr<float>(), dc, BH * sizeof(float));
  // b_ih and b_hh enter the pre-activation identically, so a *present* bias gets
  // the same sum. An absent bias gets zeros, matching the AOT reference (the
  // autograd wrapper discards it either way, but a direct .pte reader sees the
  // same numbers eager torch would).
  float* gbih_out = grad_b_ih.mutable_data_ptr<float>();
  if (b_ih.has_value()) {
    std::memcpy(gbih_out, gb, col * sizeof(float));
  } else {
    std::memset(gbih_out, 0, col * sizeof(float));
  }
  float* gbhh_out = grad_b_hh.mutable_data_ptr<float>();
  if (b_hh.has_value()) {
    std::memcpy(gbhh_out, gb, col * sizeof(float));
  } else {
    std::memset(gbhh_out, 0, col * sizeof(float));
  }
  return ret;
}

// Boxed trampoline: the pinned runtime's auto-unboxing macro caps outputs at 1, so
// register directly. Stack order matches the schema (17 EValues).
void lstm_backward_boxed(KernelRuntimeContext& ctx,
                         executorch::runtime::Span<EValue*> stack) {
  auto opt = [](EValue* e) -> std::optional<Tensor> {
    return e->isNone() ? std::optional<Tensor>{}
                       : std::optional<Tensor>(e->toTensor());
  };
  lstm_backward_out(
      ctx, stack[0]->toTensor(), opt(stack[1]), opt(stack[2]),
      stack[3]->toTensor(), stack[4]->toTensor(), stack[5]->toTensor(),
      stack[6]->toTensor(), stack[7]->toTensor(), opt(stack[8]), opt(stack[9]),
      stack[10]->toTensor(), stack[11]->toTensor(), stack[12]->toTensor(),
      stack[13]->toTensor(), stack[14]->toTensor(), stack[15]->toTensor(),
      stack[16]->toTensor());
}

// File-scope registrar -> dynamic-init TU `_GLOBAL__sub_I_etnp_lstm_backward.cpp`
// (whole-archived + nm-guarded).
const auto etnp_lstm_backward_registrar = executorch::runtime::register_kernel(
    executorch::runtime::Kernel(etnp::schema::kLstmBackwardOutName,
                                lstm_backward_boxed));
}  // namespace
}  // namespace etnp
