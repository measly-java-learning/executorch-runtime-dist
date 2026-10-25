#!/usr/bin/env bash
# Guards the release job graph: the OpenVINO asset must be built, smoke-tested, attested, and
# reach `pin` (which needs its sha) and `release`. A dropped `needs` edge would silently publish
# a release whose pin omits OpenVINO.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
wf="$here/../.github/workflows/release.yml"

assert_contains "$(cat "$wf")" "  openvino:" "openvino job exists"
assert_contains "$(cat "$wf")" "vendor-openvino.sh" "openvino job runs the vendoring script"
assert_contains "$(cat "$wf")" "test/openvino_smoke.sh" "openvino job runs the runtime smoke gate"
assert_contains "$(cat "$wf")" "name: dist-openvino" "openvino job uploads dist-openvino"
assert_contains "$(cat "$wf")" "--openvino-row" "pin job passes the openvino sha per platform"

# pin must depend on the openvino job, else it may run before the asset exists.
needs_line="$(grep -A1 '^  pin:' "$wf" | grep 'needs:')"
assert_contains "$needs_line" "openvino" "pin depends on the openvino job"

command -v python3 >/dev/null 2>&1 && python3 -c "
import sys,yaml
yaml.safe_load(open('$wf'))
print('ok: release.yml parses as YAML')
" || echo "SKIP: python3/pyyaml unavailable for YAML parse check"

assert_contains "$(cat "$wf")" "emit-openvino-fixtures.py" "release emits the OpenVINO fixture"
assert_contains "$(cat "$wf")" "package-openvino-fixtures.sh" "release packages the OpenVINO fixture"

# .ptd writer: the fixture is minted in the linux-x86_64/logging build leg, and every shipped
# prefix is gated by a job `pin` waits on -- otherwise a release could publish a tarball whose
# writer does not build or whose output the runtime cannot read.
assert_contains "$(cat "$wf")" "emit-ptd-fixtures.py" "release emits the .ptd fixture"
assert_contains "$(cat "$wf")" "name: ptd-fixtures" "release uploads the .ptd fixture artifact"
assert_contains "$(cat "$wf")" "  ptd-gate:" "linux .ptd gate job exists"
assert_contains "$(cat "$wf")" "  ptd-gate-windows:" "windows .ptd gate job exists"
assert_contains "$(cat "$wf")" "test/ptd_writer_run.sh" "linux gate runs the gate script"
assert_contains "$(cat "$wf")" "test/ptd_writer_run-windows.sh" "windows gate runs the gate script"
assert_contains "$needs_line" "ptd-gate" "pin depends on the linux .ptd gate"
assert_contains "$needs_line" "ptd-gate-windows" "pin depends on the windows .ptd gate"
exit "$ASSERT_FAILS"
