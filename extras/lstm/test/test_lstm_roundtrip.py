"""Live round-trip: nn.LSTM -> export+lower through etnp::lstm -> run vs a C++
runner built against the installed tarball -> compare to torch eager @ 1e-4.
Requires: torch, a built+installed prefix (ETNP_PREFIX), cmake, a C++ compiler.
Replaces the MVP committed-golden workaround.

NOTE on input arity: `Wrap` stores the LSTM weights as plain tensor attributes
(not graph inputs). torch.export traces `self.wih` etc. as closed-over tensors
and lifts them as CONSTANTS baked into the .pte (not part of forward's argument
list), rather than as extra graph inputs. The exported/lowered `forward` method
therefore takes only the 3 runtime tensors (x, h0, c0) — verified empirically by
inspecting `ep.graph_signature`/`pte` and by running the C++ runner. The 4 weight
tensors are NOT part of in.bin and are NOT passed to `module.forward`.
"""
import os, pathlib, struct, subprocess, sys, tempfile
import numpy as np
import torch

HERE = pathlib.Path(__file__).resolve().parent
PREFIX = pathlib.Path(os.environ["ETNP_PREFIX"]).resolve()

sys.path.insert(0, str(HERE.parents[2]))          # repo root, for extras.*
import extras.lstm.aot.etnp_lstm_op  # noqa: F401  registers the op

T, B, I, H = 5, 2, 4, 3


def _weights(lstm):
    # torch.nn.LSTM single-layer names: weight_ih_l0 [4H,I], weight_hh_l0 [4H,H],
    # bias_ih_l0/bias_hh_l0 [4H]. Gate order i,f,g,o matches the kernel.
    return (lstm.weight_ih_l0.detach(), lstm.weight_hh_l0.detach(),
            lstm.bias_ih_l0.detach(), lstm.bias_hh_l0.detach())


class Wrap(torch.nn.Module):
    def __init__(self, wih, whh, bih, bhh):
        super().__init__()
        self.wih, self.whh, self.bih, self.bhh = wih, whh, bih, bhh

    def forward(self, x, h0, c0):
        return torch.ops.etnp.lstm(x, h0, c0, self.wih, self.whh, self.bih, self.bhh)


def _build_runner(build_dir):
    subprocess.run(["cmake", "-B", str(build_dir), "-S", str(HERE), "-G", "Ninja",
                    f"-DCMAKE_PREFIX_PATH={PREFIX}", f"-DETNP_PREFIX={PREFIX}"], check=True)
    subprocess.run(["cmake", "--build", str(build_dir), "--target", "lstm_runner"], check=True)
    return build_dir / "lstm_runner"


def test_roundtrip_matches_eager():
    torch.manual_seed(0)
    lstm = torch.nn.LSTM(I, H, num_layers=1, batch_first=False)
    wih, whh, bih, bhh = _weights(lstm)
    x = torch.randn(T, B, I)
    h0 = torch.zeros(B, H); c0 = torch.zeros(B, H)

    # eager reference (nn.LSTM wants h/c as [num_layers, B, H])
    eager_out, _ = lstm(x, (h0.unsqueeze(0), c0.unsqueeze(0)))

    # export + lower (no partitioner -> op stays opaque -> ToOutVarPass -> lstm.out)
    from executorch.exir import to_edge_transform_and_lower
    ep = torch.export.export(Wrap(wih, whh, bih, bhh), (x, h0, c0))

    # The 4 weight tensors are plain (non-Parameter) attributes closed over by
    # forward, so torch.export lifts them as constants, NOT graph inputs. Assert
    # the observed arity so a future torch/export-recipe change that flips this
    # back to lifting weights as inputs fails loudly here instead of silently
    # mismatching the runner's 3-input contract.
    user_inputs = [
        s for s in ep.graph_signature.input_specs
        if s.kind == torch.export.graph_signature.InputKind.USER_INPUT
    ]
    assert len(user_inputs) == 3, (
        f"expected export to bake weights as constants (3 user inputs: x,h0,c0), "
        f"got {len(user_inputs)}: {[s.arg.name for s in user_inputs]}")

    pte = to_edge_transform_and_lower(ep).to_executorch()
    tmp = pathlib.Path(tempfile.mkdtemp())
    model = tmp / "lstm.pte"
    model.write_bytes(pte.buffer)

    # sanity: the lowered program references exactly our out op. The flatbuffer
    # stores the op name ("etnp::lstm") and overload ("out") as separate string
    # fields (verified via executorch_program.execution_plan[0].operators), so
    # they are NOT one contiguous "etnp::lstm.out" byte run in pte.buffer --
    # check via the structured API instead of a raw substring search.
    ops = pte.executorch_program.execution_plan[0].operators
    assert any(op.name == "etnp::lstm" and op.overload == "out" for op in ops), ops

    # flat inputs, runtime tensors only (x, h0, c0) -- schema order for what's
    # actually left as a forward() argument after weight-baking.
    def flat(*ts):
        return b"".join(struct.pack(f"{t.numel()}f", *t.flatten().tolist()) for t in ts)
    (tmp / "in.bin").write_bytes(flat(x, h0, c0))

    runner = _build_runner(tmp / "rbuild")
    env = {**os.environ, "LSTM_T": str(T), "LSTM_B": str(B),
           "LSTM_I": str(I), "LSTM_H": str(H)}
    subprocess.run([str(runner), str(model), str(tmp / "in.bin"), str(tmp / "out.bin")],
                   check=True, env=env)

    got = np.frombuffer((tmp / "out.bin").read_bytes(), dtype=np.float32).reshape(T, B, H)
    ref = eager_out.detach().numpy()
    assert np.allclose(got, ref, rtol=1e-4, atol=1e-4), np.abs(got - ref).max()
