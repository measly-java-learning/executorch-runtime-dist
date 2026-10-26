"""AOT proof for etnp::lstm's autograd: the backward op's registration/fake,
gradcheck vs autograd-over-_lstm_ref, agreement with nn.LSTM, absent-bias
semantics, inference-export invariance, and the joint (forward+backward) export
that the training round-trip consumes.

Needs torch; the export tests additionally need the executorch python package
(the AOT env — see extras/README.md).
"""
import pathlib
import sys

import pytest

torch = pytest.importorskip("torch")

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
import extras.lstm.aot.etnp_lstm_op  # noqa: E402,F401  registers the ops
from extras.lstm.aot import lstm_case, lstm_train_case  # noqa: E402


def _rand(shape, scale=1.0):
    return (torch.randn(shape, dtype=torch.float64) * scale).requires_grad_()


def test_backward_op_registered():
    assert torch.ops.etnp.lstm_backward.default is not None
    assert torch.ops.etnp.lstm_backward.out is not None

    from torch._subclasses.fake_tensor import FakeTensorMode
    T, B, I, H = 3, 2, 2, 3
    with FakeTensorMode():
        vals = [torch.empty(T, B, H), torch.empty(T, B, I),
                torch.empty(B, H), torch.empty(B, H), torch.empty(4 * H, I),
                torch.empty(4 * H, H), torch.empty(4 * H), torch.empty(4 * H)]
        outs = torch.ops.etnp.lstm_backward(vals[0], None, None, *vals[1:])
    assert [tuple(o.shape) for o in outs] == [
        (T, B, I), (B, H), (B, H), (4 * H, I), (4 * H, H), (4 * H,), (4 * H,)]


@pytest.mark.parametrize("bias", [True, False], ids=["with-bias", "no-bias"])
@pytest.mark.parametrize("loss_on", ["output", "hn_cn"])
@pytest.mark.parametrize("T", [1, 5])
def test_gradcheck(bias, loss_on, T):
    B, I, H = 2, 2, 3
    torch.manual_seed(0)
    inp = _rand((T, B, I))
    h0, c0 = _rand((B, H)), _rand((B, H))
    w_ih, w_hh = _rand((4 * H, I), 0.5), _rand((4 * H, H), 0.5)
    if bias:
        b_ih, b_hh = _rand((4 * H,), 0.5), _rand((4 * H,), 0.5)

        def func(inp, h0, c0, w_ih, w_hh, b_ih, b_hh):
            out, hn, cn = torch.ops.etnp.lstm(inp, h0, c0, w_ih, w_hh,
                                              b_ih, b_hh)
            return out if loss_on == "output" else hn + cn
        args = (inp, h0, c0, w_ih, w_hh, b_ih, b_hh)
    else:
        def func(inp, h0, c0, w_ih, w_hh):
            out, hn, cn = torch.ops.etnp.lstm(inp, h0, c0, w_ih, w_hh,
                                              None, None)
            return out if loss_on == "output" else hn + cn
        args = (inp, h0, c0, w_ih, w_hh)
    assert torch.autograd.gradcheck(func, args)


def test_matches_nn_lstm():
    T, B, I, H = 4, 2, 2, 3
    torch.manual_seed(1)
    lstm = torch.nn.LSTM(I, H, num_layers=1, batch_first=False).double()
    w_ih, w_hh = lstm.weight_ih_l0, lstm.weight_hh_l0
    b_ih, b_hh = lstm.bias_ih_l0, lstm.bias_hh_l0
    inp, h0, c0 = _rand((T, B, I)), _rand((B, H)), _rand((B, H))

    out, hn, cn = torch.ops.etnp.lstm(inp, h0, c0, w_ih, w_hh, b_ih, b_hh)
    ref, (hn_ref, cn_ref) = lstm(inp, (h0.unsqueeze(0), c0.unsqueeze(0)))
    torch.testing.assert_close(out, ref, atol=1e-12, rtol=1e-12)
    torch.testing.assert_close(hn, hn_ref[0], atol=1e-12, rtol=1e-12)
    torch.testing.assert_close(cn, cn_ref[0], atol=1e-12, rtol=1e-12)

    gos = tuple(torch.randn_like(t) for t in (out, hn, cn))
    inputs = (inp, h0, c0, w_ih, w_hh, b_ih, b_hh)
    g_op = torch.autograd.grad((out, hn, cn), inputs, grad_outputs=gos)
    g_ref = torch.autograd.grad((ref, hn_ref[0], cn_ref[0]), inputs,
                                grad_outputs=gos)
    names = ("grad_input", "grad_h0", "grad_c0", "grad_w_ih", "grad_w_hh",
             "grad_b_ih", "grad_b_hh")
    for name, got, want in zip(names, g_op, g_ref):
        torch.testing.assert_close(got, want, atol=1e-10, rtol=1e-10,
                                   msg=lambda m, n=name: f"{n}: {m}")


def test_no_bias_grads_are_none():
    T, B, I, H = 3, 2, 2, 3
    torch.manual_seed(2)
    inp, h0, c0 = _rand((T, B, I)), _rand((B, H)), _rand((B, H))
    w_ih, w_hh = _rand((4 * H, I), 0.5), _rand((4 * H, H), 0.5)
    # Bias tensors exist but are NOT passed to the op; if autograd wrongly
    # returned a tensor gradient for an absent bias, the formula could not
    # wire it up, and an unused-input check would come back None regardless.
    b_ih, b_hh = _rand((4 * H,), 0.5), _rand((4 * H,), 0.5)

    out, hn, cn = torch.ops.etnp.lstm(inp, h0, c0, w_ih, w_hh, None, None)
    grads = torch.autograd.grad(
        (out, hn, cn), (inp, h0, c0, w_ih, w_hh, b_ih, b_hh),
        grad_outputs=tuple(torch.ones_like(t) for t in (out, hn, cn)),
        allow_unused=True)
    assert all(g is not None for g in grads[:5]), grads
    assert grads[5] is None and grads[6] is None, grads


def test_inference_export_unchanged():
    pytest.importorskip("executorch")
    # build_case asserts etnp::lstm.out is present and no lstm_backward op
    # leaked into the inference graph.
    pte, in_bytes, golden, dims = lstm_case.build_case()
    assert pte and in_bytes and golden and dims


def test_joint_export():
    pytest.importorskip("executorch")
    pte, ptd, in_bytes, golden, dims, meta = lstm_train_case.build_train_case()
    assert pte and ptd and in_bytes and golden
    params = {n for n, _ in lstm_train_case.TrainNet().named_parameters()}
    assert set(meta["grad_order"]) == params, (meta["grad_order"], params)


def test_graph_constant_in_T():
    pytest.importorskip("executorch")
    _, _, _, _, _, meta8 = lstm_train_case.build_train_case(T=8)
    _, _, _, _, _, meta32 = lstm_train_case.build_train_case(T=32)
    assert meta8["operator_count"] == meta32["operator_count"], (meta8, meta32)
