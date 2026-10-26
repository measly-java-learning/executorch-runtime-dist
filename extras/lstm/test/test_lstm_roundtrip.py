"""Live round-trip: nn.LSTM -> export+lower through etnp::lstm -> run vs a C++ runner
built against the installed prefix -> compare to torch eager @ 1e-4.
Requires: torch + executorch (AOT), a built/installed prefix (ETNP_PREFIX), cmake, ninja.
The case (dims/seed/weights/assertions) lives once in lstm_case.py — the same source the
published fixtures are minted from, so live and frozen paths cannot drift."""
import os
import pathlib
import sys
import tempfile

import numpy as np

# Imports work from ANY cwd and each module has ONE canonical identity: put the repo root on
# sys.path and import both helpers by their FULL package path (never bare `_runner`/`lstm_case`,
# which only resolve when the containing dir happens to be on the path). `_runner` is the
# torch-free test helper under test/; `lstm_case` is AOT-side under aot/ (a change to it
# triggers tier2 — see scripts/classify-gate.sh).
HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test._runner import (  # noqa: E402
    build_runner, run_runner, run_train_runner)
from extras.lstm.aot import lstm_case, lstm_train_case  # noqa: E402


def test_roundtrip_matches_eager():
    prefix = pathlib.Path(os.environ["ETNP_PREFIX"]).resolve()
    pte, in_bytes, golden, dims = lstm_case.build_case()

    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "lstm.pte").write_bytes(pte)
    (tmp / "in.bin").write_bytes(in_bytes)

    runner = build_runner(HERE, prefix, tmp / "rbuild")
    run_runner(runner, tmp / "lstm.pte", tmp / "in.bin", tmp / "out.bin", dims)

    got = np.frombuffer((tmp / "out.bin").read_bytes(), dtype=np.float32)
    ref = np.frombuffer(golden, dtype=np.float32)
    assert got.shape == ref.shape and np.allclose(got, ref, rtol=1e-4, atol=1e-4), \
        np.abs(got - ref).max()


def _assert_train_outputs(got, ref, meta):
    assert got.shape == ref.shape, (got.shape, ref.shape)
    bad = np.flatnonzero(np.abs(got - ref) > 1e-5 + 1e-4 * np.abs(ref))
    if not bad.size:
        return
    i = int(bad[0])
    per_step = 1 + len(meta["grad_order"])
    step, off = divmod(i, per_step)
    name = "loss" if off == 0 else f"gradient {meta['grad_order'][off - 1]}"
    raise AssertionError(
        f"training round-trip mismatch at step {step + 1} {name} "
        f"(output index {i}): got {got[i]} want {ref[i]} "
        f"(max|diff|={np.abs(got - ref).max():.3g})")


def test_training_roundtrip_matches_eager():
    """Joint forward+backward .pte + external .ptd through the C++ runner: loss and
    every parameter gradient vs torch eager @ float32 tolerance. This is the gate
    (goal 2): the backward kernel, the external-weight load, and the op's placement
    in the joint graph are all proven together."""
    prefix = pathlib.Path(os.environ["ETNP_PREFIX"]).resolve()
    pte, ptd, in_bytes, golden, dims, meta = lstm_train_case.build_train_case()

    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "train.pte").write_bytes(pte)
    (tmp / "train.ptd").write_bytes(ptd)
    (tmp / "train_in.bin").write_bytes(in_bytes)

    runner = build_runner(HERE, prefix, tmp / "rbuild_train",
                          target="lstm_train_runner")
    run_train_runner(runner, tmp / "train.pte", tmp / "train.ptd",
                     tmp / "train_in.bin", tmp / "train_out.bin", dims)

    got = np.frombuffer((tmp / "train_out.bin").read_bytes(), dtype=np.float32)
    ref = np.frombuffer(golden, dtype=np.float32)
    _assert_train_outputs(got, ref, meta)


def test_two_training_steps_after_inplace_update():
    """Two executes in ONE process with a dense in-place SGD update between them.

    This pins the training pattern against the forward op's pointer-keyed
    XNNPACK packing cache: a dense update changes the sampled weights, so the
    next `etnp::lstm.out` must repack rather than run stale weights (which would
    silently disagree with the backward op's recompute)."""
    prefix = pathlib.Path(os.environ["ETNP_PREFIX"]).resolve()
    pte, ptd, in_bytes, golden, dims, meta = lstm_train_case.build_train_case(
        steps=2, lr=0.05)

    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "train.pte").write_bytes(pte)
    (tmp / "train.ptd").write_bytes(ptd)
    (tmp / "train_in.bin").write_bytes(in_bytes)

    runner = build_runner(HERE, prefix, tmp / "rbuild_train2",
                          target="lstm_train_runner")
    run_train_runner(runner, tmp / "train.pte", tmp / "train.ptd",
                     tmp / "train_in.bin", tmp / "train_out.bin", dims,
                     steps=2, lr=0.05)

    got = np.frombuffer((tmp / "train_out.bin").read_bytes(), dtype=np.float32)
    ref = np.frombuffer(golden, dtype=np.float32)
    _assert_train_outputs(got, ref, meta)
