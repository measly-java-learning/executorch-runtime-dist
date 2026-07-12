"""Mint the published LSTM fixture set from lstm_case.build_case() (the same source the
live round-trip uses). Writes lstm.pte, in.bin, out.bin (golden eager output), and a
shape file (LSTM_<dim>=<n> lines) the torch-free consumer smoke reads."""
import pathlib
import sys

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/aot/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))


def shape_text(dims: dict) -> str:
    return "".join(f"LSTM_{k}={v}\n" for k, v in dims.items())


def main(outdir: pathlib.Path) -> None:
    from extras.lstm.aot import lstm_case  # torch import deferred so shape_text stays torch-free
    pte, in_bytes, golden, dims = lstm_case.build_case()
    outdir = pathlib.Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "lstm.pte").write_bytes(pte)
    (outdir / "in.bin").write_bytes(in_bytes)
    (outdir / "out.bin").write_bytes(golden)
    (outdir / "shape").write_text(shape_text(dims))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: emit_fixtures.py <outdir>\n")
        sys.exit(2)
    main(pathlib.Path(sys.argv[1]))
