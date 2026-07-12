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
from extras.lstm.test._runner import build_runner, run_runner  # noqa: E402
from extras.lstm.aot import lstm_case  # noqa: E402


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
