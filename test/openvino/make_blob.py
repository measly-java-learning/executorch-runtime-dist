"""Emit a precompiled OpenVINO CPU blob for the bundle smoke gate.

Deliberately TORCH-FREE: it builds a graph with the OpenVINO opset directly, so the gate that
proves the shipped bundle can deserialize a blob costs one `pip install openvino` rather than the
multi-GB AOT stack. The blob format is the same one ExecuTorch's delegate embeds in a .pte --
both come from compiled_model.export_model() and are consumed by ov_core_import_model.

Run with the SAME openvino version the bundle pins, so the gate tests the bundle rather than a
version-skew artifact.

    make_blob.py <out-blob-path>
"""
import sys


def main(out: str) -> None:
    import numpy as np
    import openvino as ov

    print(f"make_blob: openvino {ov.__version__}")

    param = ov.opset13.parameter([1, 8], ov.Type.f32, name="x")
    weights = ov.opset13.constant(np.eye(8, dtype=np.float32))
    matmul = ov.opset13.matmul(param, weights, False, False)
    model = ov.Model([ov.opset13.relu(matmul)], [param], "smoke")

    blob = ov.Core().compile_model(model, "CPU").export_model().getvalue()
    if not blob:
        raise SystemExit("make_blob: export_model produced an empty blob")
    with open(out, "wb") as fh:
        fh.write(blob)
    print(f"make_blob: wrote {len(blob)} byte blob to {out}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: make_blob.py <out-blob-path>\n")
        sys.exit(2)
    main(sys.argv[1])
