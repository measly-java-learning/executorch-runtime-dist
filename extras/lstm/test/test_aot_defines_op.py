import torch  # noqa: F401  (registers the dispatcher)

def test_import_registers_lstm_out():
    import extras.lstm.aot.etnp_lstm_op  # noqa: F401  side-effect: defines the op
    # The .out overload must exist under the frozen name, else exports won't lower.
    assert hasattr(torch.ops.etnp, "lstm")
    # functional fake shape-propagates
    T, B, I, H = 3, 2, 4, 5
    inp = torch.randn(T, B, I)
    h0 = torch.zeros(B, H); c0 = torch.zeros(B, H)
    w_ih = torch.randn(4 * H, I); w_hh = torch.randn(4 * H, H)
    out, hn, cn = torch.ops.etnp.lstm(inp, h0, c0, w_ih, w_hh, None, None)
    assert tuple(out.shape) == (T, B, H)
    assert tuple(hn.shape) == (B, H) and tuple(cn.shape) == (B, H)
