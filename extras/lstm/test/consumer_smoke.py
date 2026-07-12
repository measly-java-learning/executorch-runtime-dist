"""Torch-free consumer smoke: build lstm_runner against an installed prefix, run a
PUBLISHED .pte over its in.bin, and compare to the published golden out.bin @ 1e-4.
This is the same contract the downstream numpy runtime will exercise. No torch."""
import os
import pathlib
import sys
import tempfile

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test._runner import build_runner, run_runner  # noqa: E402


def parse_shape(path) -> dict:
    d = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        k, v = line.split("=", 1)
        d[k] = v
    return {"T": int(d["LSTM_T"]), "B": int(d["LSTM_B"]),
            "I": int(d["LSTM_I"]), "H": int(d["LSTM_H"])}


def within_tol(got, ref, rtol: float = 1e-4, atol: float = 1e-4) -> bool:
    return got.shape == ref.shape and bool(np.allclose(got, ref, rtol=rtol, atol=atol))


def main(fixtures_dir: pathlib.Path, prefix: pathlib.Path) -> None:
    dims = parse_shape(fixtures_dir / "shape")
    tmp = pathlib.Path(tempfile.mkdtemp())
    runner = build_runner(HERE, prefix, tmp / "rbuild")
    run_runner(runner, fixtures_dir / "lstm.pte", fixtures_dir / "in.bin", tmp / "out.bin", dims)

    got = np.frombuffer((tmp / "out.bin").read_bytes(), dtype=np.float32)
    ref = np.frombuffer((fixtures_dir / "out.bin").read_bytes(), dtype=np.float32)
    if not within_tol(got, ref):
        sys.stderr.write(
            "consumer smoke MISMATCH: the branch kernel does not reproduce the published "
            "golden. If this is an INTENTIONAL numeric change, re-bless the fixtures via the "
            f"live round-trip (see docs/extras-gate.md). max|diff|={np.abs(got - ref).max()}\n")
        sys.exit(1)
    print("consumer smoke OK")


if __name__ == "__main__":
    main(pathlib.Path(os.environ["FIXTURES_DIR"]).resolve(),
         pathlib.Path(os.environ["ETNP_PREFIX"]).resolve())
