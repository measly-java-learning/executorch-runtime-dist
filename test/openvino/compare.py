"""Compare two flat little-endian float32 files within a tolerance.

    compare.py <got.bin> <ref.bin> [tolerance]

Stdlib only, on purpose: this runs in the gate job to check a DELEGATED result against the eager
golden, and pulling numpy (let alone torch) into that path would make the check depend on the AOT
environment it is supposed to be independent of. Exits 0 on match, 1 on mismatch, 2 on bad usage.
"""
import pathlib
import struct
import sys

DEFAULT_TOL = 1e-4


def read_floats(path: pathlib.Path) -> list:
    raw = path.read_bytes()
    if len(raw) % 4:
        raise SystemExit(f"compare.py: {path} is {len(raw)} bytes, not a whole number of float32")
    return list(struct.unpack(f"<{len(raw) // 4}f", raw))


def compare(got: list, ref: list) -> float:
    """Return the max absolute difference. Raises SystemExit(1) on a length mismatch."""
    if len(got) != len(ref):
        sys.stderr.write(f"compare.py: length mismatch: got {len(got)}, expected {len(ref)}\n")
        raise SystemExit(1)
    if not ref:
        sys.stderr.write("compare.py: refusing to compare empty tensors (nothing was produced)\n")
        raise SystemExit(1)
    return max(abs(a - b) for a, b in zip(got, ref))


def main(argv: list) -> int:
    if len(argv) not in (3, 4):
        sys.stderr.write("usage: compare.py <got.bin> <ref.bin> [tolerance]\n")
        return 2
    tol = float(argv[3]) if len(argv) == 4 else DEFAULT_TOL
    got = read_floats(pathlib.Path(argv[1]))
    ref = read_floats(pathlib.Path(argv[2]))
    worst = compare(got, ref)
    if worst > tol:
        sys.stderr.write(f"compare.py: max abs diff {worst:g} exceeds tolerance {tol:g}\n")
        return 1
    print(f"compare.py: {len(ref)} values match (max abs diff {worst:g}, tol {tol:g})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
