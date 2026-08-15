"""Mint an XNNPACK-DELEGATED fixture for the workspace-size gate: a trivial model plus its golden
eager output. Writes xnnpack_tiny.pte, in.bin, out.bin, and a shape file.

This exists because the LSTM fixture is NOT XNNPACK-delegated -- it lowers to the etnp::lstm custom
op, whose XNNPACK use is inside our own kernel rather than the delegate. Its delegate workspace
reads 0, so a workspace-size test built on it would pass against a completely broken accessor.

Requires the AOT venv: torch and the executorch python package built from the SAME pinned ET source.
"""
import pathlib
import sys

DIM = 8


def main(outdir: pathlib.Path) -> None:
    import torch
    from executorch.backends.xnnpack.partition.xnnpack_partitioner import XnnpackPartitioner
    from executorch.exir import to_edge_transform_and_lower

    class Tiny(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.lin = torch.nn.Linear(DIM, DIM)

        def forward(self, x):
            return torch.relu(self.lin(x))

    # Fixed seed: the fixture must be reproducible across releases for the same versions.
    torch.manual_seed(0)
    model = Tiny().eval()
    example = (torch.randn(1, DIM),)

    with torch.no_grad():
        golden = model(*example)

    exported = torch.export.export(model, example)
    lowered = to_edge_transform_and_lower(exported, partitioner=[XnnpackPartitioner()])
    pte = lowered.to_executorch().buffer

    # Prove the delegate was actually applied. Without this, a partitioner that silently declined
    # every node would still produce a valid .pte -- one that allocates no workspace at all, which
    # is precisely the vacuous pass this fixture exists to prevent.
    if b"XnnpackBackend" not in pte:
        raise SystemExit("emit-xnnpack-fixtures: .pte contains no XnnpackBackend delegate")

    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "xnnpack_tiny.pte").write_bytes(pte)
    (outdir / "in.bin").write_bytes(example[0].contiguous().numpy().tobytes())
    (outdir / "out.bin").write_bytes(golden.contiguous().numpy().tobytes())
    (outdir / "shape").write_text(f"XNN_IN={DIM}\nXNN_OUT={DIM}\n")
    print(f"emit-xnnpack-fixtures: wrote {len(pte)} byte .pte to {outdir}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: emit-xnnpack-fixtures.py <outdir>\n")
        sys.exit(2)
    main(pathlib.Path(sys.argv[1]))
