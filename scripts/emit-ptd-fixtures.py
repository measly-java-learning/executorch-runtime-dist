"""Mint the fixture set for the .ptd writer round-trip gate: a tiny Linear exported with its
constants in an external-data (.ptd) file, the same weights doubled and exported the same way as a
Python-written reference, plus the eager goldens.

Writes:
  linear.pte       the model with lin.weight/lin.bias externalised
  linear.ptd       that export's external-data file (renamed from write_tensor_data_to_file's name)
  linear_x2.ptd    the same module with weight and bias * 2, exported identically. The C++ writer
                   is expected to produce the same CONTENT for the doubled tensors, so this is the
                   cross-writer reference (alignment/padding may differ, so it is compared per key)
  in.bin           float32 input [1, 3], all ones
  out_base.bin     eager float32 output for in.bin against the original weights: [6.5, 14.5]
  out_x2.bin       eager float32 output against the doubled weights: [13, 29]

The gate's C++ side links only an installed prefix, so it can neither export a model nor invent a
golden value. Everything it compares against comes from here. The expected values are asserted
below so a fixture drift fails here instead of in a consumer test.

Requires the AOT venv: torch and the executorch python package built from the SAME pinned ET source,
with flatc on PATH (the exporter shells out to it).
"""
import io
import pathlib
import sys
import tempfile

WEIGHTS = ((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
BIAS = (0.5, -0.5)
IN_SHAPE = (1, 3)


def _model(scale: float):
    import torch

    class Linear(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.lin = torch.nn.Linear(3, 2)
            with torch.no_grad():
                self.lin.weight.copy_(torch.tensor(WEIGHTS) * scale)
                self.lin.bias.copy_(torch.tensor(BIAS) * scale)

        def forward(self, x):
            return self.lin(x)

    return Linear().eval()


def _export(model, example):
    """Returns (pte bytes, ptd bytes). Keeps the exporter's naming out of the caller's way."""
    import torch
    from executorch.exir import ExecutorchBackendConfig, to_edge

    exported = torch.export.export(model, example)
    program = to_edge(exported).to_executorch(
        ExecutorchBackendConfig(external_constants=True)
    )

    pte = io.BytesIO()
    program.write_to_file(pte)

    # write_tensor_data_to_file names the file after the export's data-store key, not after the
    # .pte, and can in principle write several. This fixture has exactly one, named by us.
    with tempfile.TemporaryDirectory() as d:
        program.write_tensor_data_to_file(d)
        produced = sorted(pathlib.Path(d).glob("*.ptd"))
        if len(produced) != 1:
            raise SystemExit(
                f"emit-ptd-fixtures: expected one external-data file, got {[p.name for p in produced]}"
            )
        ptd = produced[0].read_bytes()
    return pte.getvalue(), ptd


def main(outdir: pathlib.Path) -> None:
    import torch

    base = _model(1.0)
    doubled = _model(2.0)
    example = (torch.ones(IN_SHAPE, dtype=torch.float32),)

    with torch.no_grad():
        out_base = base(*example)
        out_x2 = doubled(*example)

    # Pin the goldens here: a silently changed model (or a torch default flip) must fail the
    # fixture mint, not the consumer gate built from it.
    if not torch.equal(out_base, torch.tensor([[6.5, 14.5]])):
        raise SystemExit(f"emit-ptd-fixtures: base golden drifted: {out_base.tolist()}")
    if not torch.equal(out_x2, torch.tensor([[13.0, 29.0]])):
        raise SystemExit(f"emit-ptd-fixtures: x2 golden drifted: {out_x2.tolist()}")

    pte, ptd = _export(base, example)
    _, ptd_x2 = _export(doubled, example)

    # Externalisation and key identity are asserted on the C++ side (ptd_roundtrip's
    # `expected_keys` and `cross_writer_content`), through the installed public reader. Listing the
    # keys here would mean importing ET's private `Cord` module just to deserialize, which breaks
    # fixture minting on any pin bump that renames it. What this script can cheaply guarantee is
    # that both exports actually produced an external-data file.
    if not pte or not ptd or not ptd_x2:
        raise SystemExit(
            f"emit-ptd-fixtures: empty output (pte={len(pte)}, ptd={len(ptd)}, x2={len(ptd_x2)})"
        )

    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "linear.pte").write_bytes(pte)
    (outdir / "linear.ptd").write_bytes(ptd)
    (outdir / "linear_x2.ptd").write_bytes(ptd_x2)
    inbin = example[0].contiguous().numpy().tobytes()
    basebin = out_base.contiguous().numpy().tobytes()
    x2bin = out_x2.contiguous().numpy().tobytes()
    if (len(inbin), len(basebin), len(x2bin)) != (12, 8, 8):
        raise SystemExit(
            f"emit-ptd-fixtures: unexpected binary sizes {len(inbin)}/{len(basebin)}/{len(x2bin)}"
        )
    (outdir / "in.bin").write_bytes(inbin)
    (outdir / "out_base.bin").write_bytes(basebin)
    (outdir / "out_x2.bin").write_bytes(x2bin)

    print(
        f"emit-ptd-fixtures: wrote {len(pte)} byte .pte and {len(ptd)}/{len(ptd_x2)} byte .ptd "
        f"files to {outdir}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: emit-ptd-fixtures.py <outdir>\n")
        sys.exit(2)
    main(pathlib.Path(sys.argv[1]))
