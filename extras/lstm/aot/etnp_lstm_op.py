"""Registers etnp::lstm for torch.export so a model calling it lowers to a .pte that
references etnp::lstm.out (matching examples/custom_kernels/lstm/etnp_lstm.cpp).
Import this module before exporting. Run/validate in the ExecuTorch export venv:
  /home/corey/workspace/executorch/.venv/bin/python

Working recipe (found by iteration — see task-4-report.md for the attempts that failed):
  - Define the op with an explicit out-variant schema
    (`lstm.out(..., *, Tensor(a!) output, Tensor(b!) hn, Tensor(c!) cn) -> ...`)
    in ADDITION to the functional `lstm(...)` schema, and register a
    CompositeExplicitAutograd impl for BOTH overloads.
  - `to_edge_transform_and_lower` with NO XNNPACK partitioner passed keeps the op
    opaque. `export()` + default `to_edge_transform_and_lower(ep)` (no partitioner
    argument) never decomposes a custom op registered as CompositeExplicitAutograd
    (composite/functional decomposition only kicks in for CompositeImplicitAutograd
    ops or aten ops that have registered decompositions) — the functional overload
    `etnp::lstm.default` is preserved through to_edge, and ExecuTorch's out-variant
    pass (`ToOutVarPass`, run inside `.to_executorch()`) converts it into
    `etnp::lstm.out` automatically because we registered the `lstm.out` overload
    with a matching schema. That conversion is what makes the *.out* op show up in
    the final execution plan, matching what the C++ kernel registers.
"""
import torch
from torch.library import Library, impl, register_fake

import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))  # extras/
from generate_schema_header import load_schema
_schema = load_schema(pathlib.Path(__file__).resolve().parents[1] / "extra.yaml")
_lib = Library(_schema["namespace"], "DEF")
_lib.define(_schema["functional"])
_lib.define(_schema["out"])


def _lstm_ref(input, h0, c0, w_ih, w_hh, b_ih, b_hh):
    """Functional reference matching the C++ kernel's semantics: single-layer,
    unidirectional, batch_first=False, float32. Gate row order i,f,g,o (PyTorch).
    input [T,B,I], h0/c0 [B,H], w_ih [4H,I], w_hh [4H,H], b_ih/b_hh [4H].
    Correct enough to trace and shape-propagate; NOT the shipping AOT definition.
    """
    T, B, _ = input.shape
    H = h0.shape[1]
    h, c = h0, c0
    outs = []
    for t in range(T):
        g = input[t] @ w_ih.t() + h @ w_hh.t()
        if b_ih is not None:
            g = g + b_ih
        if b_hh is not None:
            g = g + b_hh
        i, f, gg, o = g[:, 0:H], g[:, H:2 * H], g[:, 2 * H:3 * H], g[:, 3 * H:4 * H]
        c = torch.sigmoid(f) * c + torch.sigmoid(i) * torch.tanh(gg)
        h = torch.sigmoid(o) * torch.tanh(c)
        outs.append(h)
    return torch.stack(outs, 0), h, c


@impl(_lib, "lstm", "CompositeExplicitAutograd")
def _lstm_impl(input, h0, c0, w_ih, w_hh, b_ih, b_hh):
    return _lstm_ref(input, h0, c0, w_ih, w_hh, b_ih, b_hh)


@impl(_lib, "lstm.out", "CompositeExplicitAutograd")
def _lstm_out_impl(input, h0, c0, w_ih, w_hh, b_ih, b_hh, *, output, hn, cn):
    out, h, c = _lstm_ref(input, h0, c0, w_ih, w_hh, b_ih, b_hh)
    output.copy_(out)
    hn.copy_(h)
    cn.copy_(c)
    return output, hn, cn


@register_fake("etnp::lstm")
def _lstm_fake(input, h0, c0, w_ih, w_hh, b_ih, b_hh):
    T, B, _ = input.shape
    H = h0.shape[1]
    return (input.new_empty((T, B, H)), h0.new_empty((B, H)), c0.new_empty((B, H)))


# --- backward op (same bundle, additive) ------------------------------------
# The backward is its own opaque op so a joint export (forward+backward) stays
# constant in T, symmetric with the forward. Its eager implementation recomputes
# the forward through _lstm_ref and differentiates that; no hand-written BPTT.
_backward_schema = next((e for e in _schema["extra_ops"]
                         if e["op"] == "lstm_backward"), None)
assert _backward_schema is not None, \
    "extra.yaml must declare extra_ops: lstm_backward (the AOT face depends on it)"
_lib.define(_backward_schema["functional"])
_lib.define(_backward_schema["out"])


def _lstm_backward_ref(grad_output, grad_hn, grad_cn,
                       input, h0, c0, w_ih, w_hh, b_ih, b_hh):
    """Eager reference backward: replay _lstm_ref on detached leaves and let
    autograd differentiate it. Returns all seven gradients in schema order.
    A None grad_hn/grad_cn means zero; an absent bias yields a zero [4H] grad
    (the op can never return None, the autograd wrapper discards it)."""
    tensors = [input.detach(), h0.detach(), c0.detach(),
               w_ih.detach(), w_hh.detach()]
    has_b_ih, has_b_hh = b_ih is not None, b_hh is not None
    if has_b_ih:
        tensors.append(b_ih.detach())
    if has_b_hh:
        tensors.append(b_hh.detach())
    with torch.enable_grad():
        for t in tensors:
            t.requires_grad_(True)
        d_input, d_h0, d_c0, d_w_ih, d_w_hh = tensors[:5]
        db_ih = tensors[5] if has_b_ih else None
        db_hh = tensors[5 + int(has_b_ih)] if has_b_hh else None

        out, hn, cn = _lstm_ref(d_input, d_h0, d_c0, d_w_ih, d_w_hh, db_ih, db_hh)
        g_hn = torch.zeros_like(hn) if grad_hn is None else grad_hn.detach()
        g_cn = torch.zeros_like(cn) if grad_cn is None else grad_cn.detach()
        grads = torch.autograd.grad(
            (out, hn, cn), tensors,
            grad_outputs=(grad_output.detach(), g_hn, g_cn),
            allow_unused=True)
        grads = [torch.zeros_like(t) if g is None else g
                 for g, t in zip(grads, tensors)]
    H = h0.shape[1]
    grad_b_ih = grads[5] if has_b_ih else w_ih.new_zeros((4 * H,))
    grad_b_hh = (grads[5 + int(has_b_ih)] if has_b_hh
                 else w_ih.new_zeros((4 * H,)))
    return (grads[0], grads[1], grads[2], grads[3], grads[4],
            grad_b_ih, grad_b_hh)


@impl(_lib, "lstm_backward", "CompositeExplicitAutograd")
def _lstm_backward_impl(grad_output, grad_hn, grad_cn, input, h0, c0,
                        w_ih, w_hh, b_ih, b_hh):
    return _lstm_backward_ref(grad_output, grad_hn, grad_cn,
                              input, h0, c0, w_ih, w_hh, b_ih, b_hh)


@impl(_lib, "lstm_backward.out", "CompositeExplicitAutograd")
def _lstm_backward_out_impl(grad_output, grad_hn, grad_cn, input, h0, c0,
                            w_ih, w_hh, b_ih, b_hh, *,
                            grad_input, grad_h0, grad_c0,
                            grad_w_ih, grad_w_hh, grad_b_ih, grad_b_hh):
    outs = _lstm_backward_ref(grad_output, grad_hn, grad_cn,
                              input, h0, c0, w_ih, w_hh, b_ih, b_hh)
    dst = (grad_input, grad_h0, grad_c0, grad_w_ih, grad_w_hh,
           grad_b_ih, grad_b_hh)
    for d, s in zip(dst, outs):
        d.copy_(s)
    return dst


@register_fake("etnp::lstm_backward")
def _lstm_backward_fake(grad_output, grad_hn, grad_cn, input, h0, c0,
                        w_ih, w_hh, b_ih, b_hh):
    H = h0.shape[1]
    shape = (4 * H,)
    # Two distinct tensors: returning the same object twice makes export's
    # tracing emit one node for both bias gradients (duplicate graph outputs).
    return (input.new_empty(input.shape), h0.new_empty(h0.shape),
            c0.new_empty(c0.shape), w_ih.new_empty(w_ih.shape),
            w_hh.new_empty(w_hh.shape), grad_output.new_empty(shape),
            grad_output.new_empty(shape))


def _lstm_setup_context(ctx, inputs, output):
    input, h0, c0, w_ih, w_hh, b_ih, b_hh = inputs
    ctx.save_for_backward(input, h0, c0, w_ih, w_hh, b_ih, b_hh)
    # Only used when an unused output's grad arrives as None (torch normally
    # materialises zeros, but do not depend on that).
    ctx.output_shape = output[0].shape


def _lstm_backward(ctx, grad_output, grad_hn, grad_cn):
    input, h0, c0, w_ih, w_hh, b_ih, b_hh = ctx.saved_tensors
    if grad_output is None:
        grad_output = torch.zeros(ctx.output_shape, dtype=input.dtype,
                                  device=input.device)
    grads = torch.ops.etnp.lstm_backward(
        grad_output, grad_hn, grad_cn, input, h0, c0, w_ih, w_hh, b_ih, b_hh)
    # Absent biases get a None gradient on the torch side (the op still fills
    # both bias outputs; ExecuTorch out-variants cannot return None).
    return (grads[0], grads[1], grads[2], grads[3], grads[4],
            grads[5] if b_ih is not None else None,
            grads[6] if b_hh is not None else None)


torch.library.register_autograd("etnp::lstm", _lstm_backward,
                                setup_context=_lstm_setup_context)
