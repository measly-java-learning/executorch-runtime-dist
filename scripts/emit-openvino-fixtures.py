"""Mint the published OpenVINO fixture set: a trivial fully-delegated model plus its golden
output. Writes openvino_tiny.pte, in.bin, out.bin (golden EAGER output for in.bin), and a
shape file the torch-free consumer smoke reads.

Requires the AOT venv: torch, the executorch python package built from the SAME pinned ET
source, openvino, and nncf. nncf is needed even though we never quantize -- importing
executorch.backends.openvino.partitioner executes the package __init__, which imports
OpenVINOQuantizer, which imports nncf at module level.
"""
import pathlib
import sys

DIM = 8


def main(outdir: pathlib.Path) -> None:
    import torch
    from executorch.backends.openvino.partitioner import OpenvinoPartitioner
    from executorch.exir import to_edge_transform_and_lower
    from executorch.exir.backend.backend_details import CompileSpec

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
    # "device" CompileSpec picks the OpenVINO device; CPU is the only plugin we ship.
    partitioner = OpenvinoPartitioner([CompileSpec("device", b"CPU")])
    lowered = to_edge_transform_and_lower(exported, partitioner=[partitioner])
    pte = lowered.to_executorch().buffer

    # Prove the delegate was actually applied. Without this, a partitioner that silently declined
    # every node would still produce a valid .pte -- one that tests nothing but portable CPU.
    if b"OpenvinoBackend" not in pte:
        raise SystemExit("emit-openvino-fixtures: .pte contains no OpenvinoBackend delegate")

    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "openvino_tiny.pte").write_bytes(pte)
    (outdir / "in.bin").write_bytes(example[0].contiguous().numpy().tobytes())
    (outdir / "out.bin").write_bytes(golden.contiguous().numpy().tobytes())
    (outdir / "shape").write_text(f"OV_IN={DIM}\nOV_OUT={DIM}\n")
    print(f"emit-openvino-fixtures: wrote {len(pte)} byte .pte to {outdir}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: emit-openvino-fixtures.py <outdir>\n")
        sys.exit(2)
    main(pathlib.Path(sys.argv[1]))
