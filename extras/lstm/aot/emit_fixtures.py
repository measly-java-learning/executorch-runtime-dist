"""Mint the published LSTM fixture set from lstm_case.build_case() (the same source the
live round-trip uses). Writes lstm.pte, in.bin, out.bin (golden eager output), and a
shape file (LSTM_<dim>=<n> lines) the torch-free consumer smoke reads.

Also mints the TRAINING set from lstm_train_case.build_train_case(): train.pte,
train.ptd (external mutable weights), train_in.bin (x ++ target), train_out.bin
(loss ++ parameter gradients) and train_shape (TRAIN_<dim>=<n> + TRAIN_NOUT)."""
import pathlib
import sys

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/aot/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

TRAIN_DIMS = ("T", "B", "I", "H", "O")


def shape_text(dims: dict) -> str:
    return "".join(f"LSTM_{k}={v}\n" for k, v in dims.items())


def train_shape_text(dims: dict, nout: int) -> str:
    return ("".join(f"TRAIN_{k}={dims[k]}\n" for k in TRAIN_DIMS) +
            f"TRAIN_NOUT={nout}\n")


def main(outdir: pathlib.Path) -> None:
    from extras.lstm.aot import lstm_case  # torch import deferred so shape_text stays torch-free
    from extras.lstm.aot import lstm_train_case
    pte, in_bytes, golden, dims = lstm_case.build_case()
    (tpte, tptd, t_in, t_golden, tdims, _meta) = lstm_train_case.build_train_case()
    outdir = pathlib.Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "lstm.pte").write_bytes(pte)
    (outdir / "in.bin").write_bytes(in_bytes)
    (outdir / "out.bin").write_bytes(golden)
    (outdir / "shape").write_text(shape_text(dims))
    (outdir / "train.pte").write_bytes(tpte)
    (outdir / "train.ptd").write_bytes(tptd)
    (outdir / "train_in.bin").write_bytes(t_in)
    (outdir / "train_out.bin").write_bytes(t_golden)
    (outdir / "train_shape").write_text(
        train_shape_text(tdims, len(t_golden) // 4))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: emit_fixtures.py <outdir>\n")
        sys.exit(2)
    main(pathlib.Path(sys.argv[1]))
