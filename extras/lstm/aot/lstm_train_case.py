"""Single source of truth for the LSTM TRAINING case: dims, seed, model, loss,
joint (forward+backward) export recipe, and its own assertions. Both the live
training round-trip and the published-fixture emitter call build_train_case(),
so the .pte/.ptd/golden the gate consumes can never drift from what the live
test would produce — same rule as lstm_case.py for inference.

The model is Linear -> etnp::lstm -> Linear with the LSTM weights as real
nn.Parameters (NOT closed-over constants, unlike the inference case), so the
joint graph carries external mutable weights in a .ptd. The exported program's
outputs are [loss, <parameter gradients>, <parameters>]; the gradient order is
recorded in `meta` so a mismatching round-trip can name the offending FQN.
"""
import pathlib
import struct
import sys
import tempfile

import torch

HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/aot/ -> repo root, for extras.*
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
import extras.lstm.aot.etnp_lstm_op  # noqa: E402,F401  registers the forward + backward ops

DIMS = {"T": 8, "B": 2, "I": 4, "H": 16, "O": 1}


class TrainNet(torch.nn.Module):
    def __init__(self):
        super().__init__()
        T, B, I, H, O = (DIMS[k] for k in ("T", "B", "I", "H", "O"))
        self.pre = torch.nn.Linear(I, I)
        self.w_ih = torch.nn.Parameter(torch.empty(4 * H, I))
        self.w_hh = torch.nn.Parameter(torch.empty(4 * H, H))
        self.b_ih = torch.nn.Parameter(torch.empty(4 * H))
        self.b_hh = torch.nn.Parameter(torch.empty(4 * H))
        self.post = torch.nn.Linear(H, O)
        k = 1.0 / (H ** 0.5)                       # nn.LSTM's init range
        for p in (self.w_ih, self.w_hh, self.b_ih, self.b_hh):
            torch.nn.init.uniform_(p, -k, k)
        # Zero state is part of the model, not a user input: the sample starts
        # every batch from zeros, so the joint graph has only (x, target).
        self.register_buffer("h0", torch.zeros(B, H))
        self.register_buffer("c0", torch.zeros(B, H))

    def forward(self, x, target):
        y = self.pre(x)
        out, _, _ = torch.ops.etnp.lstm(
            y, self.h0, self.c0, self.w_ih, self.w_hh, self.b_ih, self.b_hh)
        return torch.nn.functional.mse_loss(self.post(out[-1]), target)


def _flat(*ts) -> bytes:
    return b"".join(struct.pack(f"{t.numel()}f", *t.flatten().tolist()) for t in ts)


def build_train_case(T: int = None, steps: int = 1, lr: float = 0.05):
    """(pte_bytes, ptd_bytes, in_bytes, golden_bytes, dims, meta).

    in_bytes = x[T,B,I] ++ target[B,O].
    golden_bytes = per step: loss ++ every parameter gradient, in the joint
    graph's gradient-output order (meta["grad_order"] names each one, by FQN).
    With steps > 1 the remaining steps apply the same dense in-place SGD update
    the C++ runner performs between executes, and their loss+gradients are
    appended — this is what pins the training pattern against the forward
    op's packed-weight cache.
    """
    from executorch.exir import ExecutorchBackendConfig, to_edge
    from torch.export.experimental import _export_forward_backward
    from torch.export.exported_program import OutputKind

    T = DIMS["T"] if T is None else T
    B, I, H, O = (DIMS[k] for k in ("B", "I", "H", "O"))

    torch.manual_seed(0)
    net = TrainNet()
    x = torch.randn(T, B, I)
    target = torch.randn(B, O)

    losses, step_grads = [], []

    def eager_step():
        net.zero_grad(set_to_none=True)
        loss = net(x, target)
        loss.backward()
        losses.append(loss.detach())
        step_grads.append({n: p.grad.detach().clone()
                           for n, p in net.named_parameters()})

    eager_step()

    ep = torch.export.export(net, (x, target))   # initial weights
    joint = _export_forward_backward(ep)
    edge = to_edge(joint)
    emit = edge.to_executorch(
        config=ExecutorchBackendConfig(external_mutable_weights=True))

    plan = emit.executorch_program.execution_plan[0]
    ops = {(op.name, op.overload) for op in plan.operators}
    assert ("etnp::lstm", "out") in ops, ops
    # The whole point: the backward stays an opaque, T-independent op.
    assert ("etnp::lstm_backward", "out") in ops, ops

    specs = emit.exported_program().graph_signature.output_specs
    grad_order = [s.target for s in specs
                  if s.kind == OutputKind.GRADIENT_TO_PARAMETER]
    param_grads = step_grads[0]
    assert set(grad_order) == set(param_grads), (grad_order, sorted(param_grads))

    # The runner's dense in-place SGD, simulated in torch for the golden.
    for _ in range(steps - 1):
        with torch.no_grad():
            for n, p in net.named_parameters():
                p -= lr * step_grads[-1][n]
        eager_step()

    # Reading .buffer triggers serialization, which populates the manager's
    # tensor-data map; write_tensor_data_to_file is the public accessor for it.
    pte = emit.buffer
    with tempfile.TemporaryDirectory() as td:
        emit.write_tensor_data_to_file(td)
        ptd_files = sorted(pathlib.Path(td).glob("*.ptd"))
        assert len(ptd_files) == 1, [p.name for p in ptd_files]
        ptd = ptd_files[0].read_bytes()
    assert ptd, "external weights .ptd is empty"

    parts = []
    for s in range(steps):
        parts.append(losses[s])
        parts.extend(step_grads[s][n] for n in grad_order)
    golden = _flat(*parts)
    meta = {"grad_order": grad_order, "operator_count": len(plan.operators),
            "steps": steps, "lr": lr}
    return (pte, ptd, _flat(x, target), golden,
            dict(DIMS, T=T), meta)
