#!/usr/bin/env bash
# Structural guard for the three-way split of the `full` gate.
#
# The split only pays off if the two heavy jobs stay INDEPENDENT: full-build (the C++ recipe) and
# full-aot (ExecuTorch's python package + fixtures) must not depend on each other, or they
# serialise again and the ~11min saving silently disappears — with nothing failing to say so.
# It is also only CORRECT if full-gates waits for both, and if the fixtures it consumes are the
# fresh ones from full-aot rather than published ones.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
wf="$here/../.github/workflows/extras-gate.yml"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

python3 - "$wf" <<'PY'
import sys, yaml
fails = 0

def ok(cond, msg):
    global fails
    if cond:
        print(f"ok: {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        fails += 1

jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]

for j in ("full-build", "full-aot", "full-gates"):
    ok(j in jobs, f"job {j} exists")

def needs(j):
    n = jobs[j].get("needs", [])
    return [n] if isinstance(n, str) else n

# The whole point: the two expensive jobs must be able to start at the same time.
ok("full-aot" not in needs("full-build"), "full-build does not wait on full-aot")
ok("full-build" not in needs("full-aot"), "full-aot does not wait on full-build")
ok(set(needs("full-gates")) >= {"full-build", "full-aot"}, "full-gates waits for both halves")

# Every one of the three must be gated on `full`, or a tier1 PR starts a 15-minute job.
for j in ("full-build", "full-aot", "full-gates"):
    ok("mode == 'full'" in str(jobs[j].get("if", "")), f"{j} runs only in full mode")

def steps(j):
    return "\n".join(str(s.get("run", "")) for s in jobs[j]["steps"])

# full-aot must not touch the prefix -- that is what keeps it independent. `--prefix` would mean
# somebody reintroduced a build there; `$PWD/out` would mean it expects full-build's tree.
aot = steps("full-aot")
ok("build-runtime.sh" not in aot, "full-aot does not build the recipe")
ok("$PWD/out" not in aot, "full-aot does not reference the built prefix")

# full-gates must consume the FRESH fixtures. If these ever became published downloads, the job
# would still pass while no longer testing the branch's AOT -- the exact vacuous-gate failure
# mode this repo keeps hitting.
gates = steps("full-gates")
for needle, msg in (
    ("fixtures-dryrun/lstm", "gates run the round-trip against fresh LSTM fixtures"),
    ("fixtures-dryrun/openvino", "gates run the OpenVINO end-to-end against fresh fixtures"),
    ("fixtures-dryrun/xnnpack", "gates run the workspace probe against fresh fixtures"),
    ("consumer_smoke.py", "gates run the round-trip verify half"),
    ("test/openvino_smoke.sh", "gates run the OpenVINO bundle smoke"),
    ("test/openvino_fixture_run.sh", "gates run the OpenVINO end-to-end"),
    ("test/xnnpack_workspace_run.sh", "gates run the workspace-size probe"),
):
    ok(needle in gates, msg)

# The prefix has to actually cross the job boundary.
ok("tar -czf prefix.tar.gz" in steps("full-build"), "full-build packs the prefix")
ok("tar -xzf prefix.tar.gz" in gates, "full-gates unpacks the prefix")

# extras_members needs a prefix, so it belongs in full-build, not in the artifact-only job.
ok("test/extras_members.sh" in steps("full-build"), "full-build still runs the extras members gate")

sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || ASSERT_FAILS=$((ASSERT_FAILS+1))
exit "$ASSERT_FAILS"
