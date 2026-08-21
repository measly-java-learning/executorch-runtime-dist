"""Structural assertions on extras-gate's Windows job.

The job exists to prove that a `full` PR will not break the Windows release tag. That guarantee is
only real if the job mirrors release.yml's build-windows: same two platforms, same entrypoint, and
a package step -- because package.sh carries the OpenVINO archive assertion, and a build-only job
would let a packaging regression ship.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
JOB = "full-build-windows"


def main() -> int:
    gate = yaml.safe_load((ROOT / ".github/workflows/extras-gate.yml").read_text())
    release = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
    fails = []

    if JOB not in gate["jobs"]:
        print(f"FAIL: extras-gate has no {JOB} job")
        return 1
    job = gate["jobs"][JOB]

    if not str(job.get("runs-on", "")).startswith("windows"):
        fails.append(f"{JOB} must run on a windows runner, got {job.get('runs-on')!r}")

    # Same platform axis as the release job, or the gate proves less than it claims.
    gate_platforms = set(job["strategy"]["matrix"]["platform"])
    rel_platforms = set(release["jobs"]["build-windows"]["strategy"]["matrix"]["platform"])
    if gate_platforms != rel_platforms:
        fails.append(f"platform matrix {sorted(gate_platforms)} != release {sorted(rel_platforms)}")

    if job.get("needs") != "classify" and "classify" not in (job.get("needs") or []):
        fails.append(f"{JOB} must depend on classify")
    if "full" not in str(job.get("if", "")):
        fails.append(f"{JOB} must be gated on mode == 'full'")

    steps = yaml.dump(job["steps"])
    for needle, why in [
        ("build-runtime.ps1", "must build through the same entrypoint release.yml uses"),
        ("scripts/package.sh", "must package: package.sh carries the OpenVINO archive assertion"),
        ("checkout-executorch", "must check out the pinned ExecuTorch source"),
    ]:
        if needle not in steps:
            fails.append(f"{JOB} {why} (missing {needle})")

    for f in fails:
        print(f"FAIL: {f}")
    if fails:
        return 1
    print(f"ok: {JOB} mirrors release build-windows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
