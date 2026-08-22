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
    release = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
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

    # The asset stem is ov_asset_stem's job. The Linux steps in this same workflow call it; the
    # Windows steps hardcoded "openvino-runtime-<ver>-windows-x86_64", which embeds both OV_VERSION
    # and the naming rule and goes stale on an OpenVINO bump. Same class of drift test/lib_aot.sh
    # guards for the python devel package.
    workflow_text = (ROOT / ".github/workflows/extras-gate.yml").read_text()
    if "openvino-runtime-" in workflow_text:
        fails.append(
            "extras-gate.yml spells an OpenVINO asset stem literally; derive it from "
            "ov_asset_stem in a `shell: bash` step and pass it via $GITHUB_ENV"
        )

    # Both CRT platforms must be gated at RUNTIME, not just compiled and packaged. They share one
    # bundle, so the second leg costs a runner and no new assets -- and windows-x86_64-static
    # shipped a delegate nothing had ever executed until this matrix existed.
    gate_platforms = set((job.get("strategy") or {}).get("matrix", {}).get("platform", []))
    rel_platforms = set(release["jobs"]["build-windows"]["strategy"]["matrix"]["platform"])
    if gate_platforms != rel_platforms:
        fails.append(f"runtime gate platforms {sorted(gate_platforms)} != shipped {sorted(rel_platforms)}")

    for f in fails:
        print(f"FAIL: {f}")
    if fails:
        return 1
    print(f"ok: {JOB} vendors a windows bundle and runs both gates on the packaged tarball")
    return 0


if __name__ == "__main__":
    sys.exit(main())
