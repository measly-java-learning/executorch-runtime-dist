"""Structural assertions on the Windows OpenVINO gate job.

The job only means something if it runs BOTH gate scripts against a bundle it vendored and a
prefix taken from the PACKAGED tarball. Each of those is a property a well-meaning edit could
drop while leaving the job green, so each is asserted here.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
JOB = "full-gates-windows"


def main() -> int:
    gate = yaml.safe_load((ROOT / ".github/workflows/extras-gate.yml").read_text())
    fails = []
    if JOB not in gate["jobs"]:
        print(f"FAIL: extras-gate has no {JOB} job")
        return 1
    job = gate["jobs"][JOB]
    steps = yaml.dump(job["steps"])

    if not str(job.get("runs-on", "")).startswith("windows"):
        fails.append(f"{JOB} must run on a windows runner")
    needs = job.get("needs") or []
    for n in ("full-build-windows", "full-aot"):
        if n not in needs:
            fails.append(f"{JOB} must depend on {n}")
    if "full" not in str(job.get("if", "")):
        fails.append(f"{JOB} must be gated on mode == 'full'")

    for needle, why in [
        ("openvino_smoke-windows.sh", "must run the bundle smoke gate"),
        ("openvino_fixture_run-windows.sh", "must run the end-to-end fixture gate"),
        ("vendor-openvino.sh", "must vendor the win_amd64 bundle it tests"),
        ("--platform windows-x86_64", "must vendor the WINDOWS bundle, not the linux one"),
        ("build-runtime.ps1", "gate scripts need the VS dev shell"),
        ("tar -xzf", "must test the PACKAGED tarball, not the build tree"),
    ]:
        if needle not in steps:
            fails.append(f"{JOB} {why} (missing {needle})")

    for f in fails:
        print(f"FAIL: {f}")
    if fails:
        return 1
    print(f"ok: {JOB} vendors a windows bundle and runs both gates on the packaged tarball")
    return 0


if __name__ == "__main__":
    sys.exit(main())
