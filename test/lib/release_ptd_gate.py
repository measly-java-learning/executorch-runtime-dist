"""Structural assertions on release.yml's .ptd gate jobs.

The gate exists so every shipped prefix is proven to link, write, and reload a `.ptd` before a tag
publishes it. That guarantee is only real if each gate matrix EQUALS the build matrix it covers: a
job that silently drops `devtools`, a platform, or a CRT leg would still go green. `pin` depending
on the jobs is checked in test/release_workflow.test.sh; this file checks the matrices themselves.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WF = ROOT / ".github/workflows/release.yml"


def matrix(job):
    return job["strategy"]["matrix"]


def main() -> int:
    wf = yaml.safe_load(WF.read_text())
    jobs = wf["jobs"]
    fails = []

    for job in ("ptd-gate", "ptd-gate-windows"):
        if job not in jobs:
            fails.append(f"release.yml has no {job} job")
    if fails:
        for f in fails:
            print(f"FAIL: {f}")
        return 1

    linux = matrix(jobs["ptd-gate"])
    build = matrix(jobs["build"])
    if linux["variant"] != build["variant"]:
        fails.append(
            f"ptd-gate variants {linux['variant']} != build {build['variant']}"
        )
    if linux["combo"] != build["combo"]:
        fails.append(
            "ptd-gate platform source differs from build's; the gate would not cover "
            "the same platforms"
        )
    if jobs["ptd-gate"].get("runs-on") != jobs["build"].get("runs-on"):
        fails.append(
            "ptd-gate runs-on differs from build's (must be matrix.combo.runs_on, or an "
            "arm platform would be gated on an x86 runner)"
        )

    win = matrix(jobs["ptd-gate-windows"])
    build_win = matrix(jobs["build-windows"])
    if win["variant"] != build_win["variant"]:
        fails.append(
            f"ptd-gate-windows variants {win['variant']} != build-windows "
            f"{build_win['variant']}"
        )
    if win["platform"] != build_win["platform"]:
        fails.append(
            f"ptd-gate-windows platforms {win['platform']} != build-windows "
            f"{build_win['platform']}"
        )
    if jobs["ptd-gate-windows"].get("runs-on") != jobs["build-windows"].get("runs-on"):
        fails.append("ptd-gate-windows must run on the same runner as build-windows")

    # Each gate must download the artifact its own matrix names, or a leg would test a sibling.
    linux_steps = yaml.dump(jobs["ptd-gate"]["steps"])
    if "dist-${{ matrix.variant }}-${{ matrix.combo.platform }}" not in linux_steps:
        fails.append("ptd-gate does not download its matrix's dist artifact")
    win_steps = yaml.dump(jobs["ptd-gate-windows"]["steps"])
    if "dist-${{ matrix.variant }}-${{ matrix.platform }}" not in win_steps:
        fails.append("ptd-gate-windows does not download its matrix's dist artifact")

    # The fixture mint must sit on the leg that has torch/executorch installed, and the artifact
    # name the gates download must match what the build leg uploads.
    build_steps = jobs["build"]["steps"]
    emits = [s for s in build_steps if "emit-ptd-fixtures.py" in str(s.get("run", ""))]
    if len(emits) != 1:
        fails.append(f"build must emit the .ptd fixture exactly once, found {len(emits)}")
    else:
        cond = str(emits[0].get("if", ""))
        if "linux-x86_64" not in cond or "logging" not in cond:
            fails.append("the .ptd fixture must be minted on the linux-x86_64 logging leg")
    uploads = [
        s
        for s in build_steps
        if s.get("with", {}).get("name") == "ptd-fixtures"
    ]
    if len(uploads) != 1:
        fails.append(f"build must upload ptd-fixtures exactly once, found {len(uploads)}")

    for f in fails:
        print(f"FAIL: {f}")
    if fails:
        return 1
    print("ok: release .ptd gate matrices mirror the build matrices")
    return 0


if __name__ == "__main__":
    sys.exit(main())
