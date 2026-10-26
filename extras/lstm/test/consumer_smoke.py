"""Torch-free consumer smoke: build the LSTM runners against an installed prefix,
run a PUBLISHED .pte over its input fixture, and compare to the published golden.
This is the same contract the downstream numpy runtime will exercise. No torch.

Two checks:
  * forward  — unchanged: lstm.pte + in.bin vs out.bin @ 1e-4.
  * training — train.pte + train.ptd + train_in.bin vs train_out.bin (loss + every
               parameter gradient). Tier1 consumes PUBLISHED fixtures, which predate
               lstm_backward until a release mints them; absent train.pte is an
               explicit SKIP (exit 0), never a silent pass and never a failure.
"""
import os
import pathlib
import sys
import tempfile

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test._runner import (  # noqa: E402
    build_runner, run_runner, run_train_runner)


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


def parse_train_shape(path) -> dict:
    d = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        k, v = line.split("=", 1)
        d[k] = v
    return {"T": int(d["TRAIN_T"]), "B": int(d["TRAIN_B"]),
            "I": int(d["TRAIN_I"]), "H": int(d["TRAIN_H"]),
            "O": int(d["TRAIN_O"])}


def within_tol(got, ref, rtol: float = 1e-4, atol: float = 1e-4) -> bool:
    return got.shape == ref.shape and bool(np.allclose(got, ref, rtol=rtol, atol=atol))


TRAIN_MEMBERS = ("train.pte", "train.ptd", "train_in.bin", "train_out.bin",
                 "train_shape")


def train_check(fixtures_dir: pathlib.Path, prefix: pathlib.Path,
                tmp: pathlib.Path) -> str:
    """'ok' when the training fixture runs and matches, 'skip' when the fixture
    predates lstm_backward (all training members absent). A PARTIAL set is a
    hard error naming the missing members: silently skipping it would hide a
    broken package. Exits 1 on a real mismatch."""
    fixtures_dir = pathlib.Path(fixtures_dir)
    present = [m for m in TRAIN_MEMBERS if (fixtures_dir / m).exists()]
    if not present:
        return "skip"
    missing = [m for m in TRAIN_MEMBERS if m not in present]
    if missing:
        sys.stderr.write(
            f"consumer smoke FAIL training: partial training fixture set in "
            f"{fixtures_dir}; missing {', '.join(missing)}\n")
        sys.exit(1)
    dims = parse_train_shape(fixtures_dir / "train_shape")
    runner = build_runner(HERE, prefix, tmp / "rbuild_train",
                          target="lstm_train_runner")
    run_train_runner(runner, fixtures_dir / "train.pte", fixtures_dir / "train.ptd",
                     fixtures_dir / "train_in.bin", tmp / "train_out.bin", dims)
    got = np.frombuffer((tmp / "train_out.bin").read_bytes(), dtype=np.float32)
    ref = np.frombuffer((fixtures_dir / "train_out.bin").read_bytes(), dtype=np.float32)
    if not within_tol(got, ref):
        sys.stderr.write(
            "consumer smoke MISMATCH (training): the branch kernel does not reproduce "
            "the published loss/gradients. If this is an INTENTIONAL numeric change, "
            "re-bless the fixtures via the live round-trip (see docs/extras-gate.md). "
            f"max|diff|={np.abs(got - ref).max() if got.shape == ref.shape else 'shape'}\n")
        sys.exit(1)
    return "ok"


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

    status = train_check(fixtures_dir, prefix, tmp)
    if status == "skip":
        print(f"consumer smoke SKIP training: no train.pte in {fixtures_dir} "
              "(fixture predates lstm_backward)")
    else:
        print("consumer smoke OK training")


if __name__ == "__main__":
    main(pathlib.Path(os.environ["FIXTURES_DIR"]).resolve(),
         pathlib.Path(os.environ["ETNP_PREFIX"]).resolve())
