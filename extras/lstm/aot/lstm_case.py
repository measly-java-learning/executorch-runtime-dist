"""Single source of truth for the LSTM QA case: dims, seed, weights, export recipe,
and the arity / op-name assertions. Both the live round-trip and the published-fixture
emitter call build_case(), so the .pte/golden the gate consumes can never drift from
what the live test would produce.

NOTE on input arity: the 4 LSTM weights are plain (non-Parameter) attributes closed
over by forward, so torch.export lifts them as CONSTANTS baked into the .pte, NOT graph
inputs. The exported forward therefore takes only (x, h0, c0). build_case() asserts this
so a future export-recipe change that flips it back fails loudly here.
"""
import pathlib
import struct
import sys

import torch

HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/aot/ -> repo root, for extras.*
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
import extras.lstm.aot.etnp_lstm_op  # noqa: E402,F401  registers torch.ops.etnp.lstm

DIMS = {"T": 5, "B": 2, "I": 4, "H": 3}


class Wrap(torch.nn.Module):
    def __init__(self, wih, whh, bih, bhh):
        super().__init__()
        self.wih, self.whh, self.bih, self.bhh = wih, whh, bih, bhh

    def forward(self, x, h0, c0):
        return torch.ops.etnp.lstm(x, h0, c0, self.wih, self.whh, self.bih, self.bhh)


def _flat(*ts) -> bytes:
    return b"".join(struct.pack(f"{t.numel()}f", *t.flatten().tolist()) for t in ts)


def build_case():
    """(pte_bytes, in_bytes, golden_bytes, dims). golden = eager nn.LSTM output."""
    from executorch.exir import to_edge_transform_and_lower
    T, B, I, H = DIMS["T"], DIMS["B"], DIMS["I"], DIMS["H"]
    torch.manual_seed(0)
    lstm = torch.nn.LSTM(I, H, num_layers=1, batch_first=False)
    wih, whh = lstm.weight_ih_l0.detach(), lstm.weight_hh_l0.detach()
    bih, bhh = lstm.bias_ih_l0.detach(), lstm.bias_hh_l0.detach()
    x = torch.randn(T, B, I)
    h0 = torch.zeros(B, H)
    c0 = torch.zeros(B, H)

    eager_out, _ = lstm(x, (h0.unsqueeze(0), c0.unsqueeze(0)))

    ep = torch.export.export(Wrap(wih, whh, bih, bhh), (x, h0, c0))
    user_inputs = [s for s in ep.graph_signature.input_specs
                   if s.kind == torch.export.graph_signature.InputKind.USER_INPUT]
    assert len(user_inputs) == 3, (
        f"expected 3 user inputs (x,h0,c0) with weights baked as constants, "
        f"got {len(user_inputs)}: {[s.arg.name for s in user_inputs]}")

    pte = to_edge_transform_and_lower(ep).to_executorch()
    ops = pte.executorch_program.execution_plan[0].operators
    assert any(op.name == "etnp::lstm" and op.overload == "out" for op in ops), ops

    return (pte.buffer, _flat(x, h0, c0),
            _flat(eager_out.detach()), dict(DIMS))
