#!/usr/bin/env bash
# Hermetic coverage for the end-to-end OpenVINO fixture gate. The gate itself needs a built prefix
# and a vendored bundle, so what is testable without one is (a) its input validation — the part
# that decides whether a missing input fails loudly or is silently skipped — and (b) the golden
# comparison, which is the assertion the whole gate exists to make.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
gate="$here/openvino_fixture_run.sh"
cmp_py="$here/openvino/compare.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- compare.py: the correctness assertion -------------------------------------------------
# float32 little-endian writers, stdlib-only like compare.py itself.
mkfloats() { # <file> <val>...
  local f="$1"; shift
  python3 -c 'import struct,sys; open(sys.argv[1],"wb").write(struct.pack("<%df"%(len(sys.argv)-2), *map(float,sys.argv[2:])))' "$f" "$@"
}

mkfloats "$tmp/ref.bin" 1.0 2.0 3.0
mkfloats "$tmp/same.bin" 1.0 2.0 3.0
mkfloats "$tmp/close.bin" 1.00001 2.00001 3.00001
mkfloats "$tmp/far.bin" 1.0 2.0 3.5
mkfloats "$tmp/short.bin" 1.0 2.0
: > "$tmp/empty.bin"

python3 "$cmp_py" "$tmp/same.bin" "$tmp/ref.bin" >/dev/null 2>&1
assert_eq "$?" "0" "compare.py: identical values match"

python3 "$cmp_py" "$tmp/close.bin" "$tmp/ref.bin" >/dev/null 2>&1
assert_eq "$?" "0" "compare.py: within-tolerance values match"

python3 "$cmp_py" "$tmp/far.bin" "$tmp/ref.bin" >/dev/null 2>&1
assert_eq "$?" "1" "compare.py: out-of-tolerance values fail"

# A length mismatch must FAIL rather than compare the common prefix — a delegate that returns a
# truncated tensor is a real defect, and zip() would silently ignore the tail.
python3 "$cmp_py" "$tmp/short.bin" "$tmp/ref.bin" >/dev/null 2>&1
assert_eq "$?" "1" "compare.py: length mismatch fails"

# Two empty files are trivially "equal" under any tolerance. That is the shape of a vacuous pass
# (nothing ran, nothing was written), so it must fail instead.
python3 "$cmp_py" "$tmp/empty.bin" "$tmp/empty.bin" >/dev/null 2>&1
assert_eq "$?" "1" "compare.py: empty-vs-empty fails rather than passing vacuously"

python3 "$cmp_py" "$tmp/far.bin" "$tmp/ref.bin" 1.0 >/dev/null 2>&1
assert_eq "$?" "0" "compare.py: explicit loose tolerance is honoured"

python3 "$cmp_py" "$tmp/ref.bin" >/dev/null 2>&1
assert_eq "$?" "2" "compare.py: missing argument is a usage error"

# --- the bf16 tolerance, pinned by test rather than by comment -------------------------------
# OpenVINO picks inference precision from the CPU it lands on, so a bf16-capable runner computes
# the same model in bf16 and lands ~2.5e-3 from the f32 eager golden. Both answers are correct;
# this repo ships packaging, not kernels. The value below is the real diff measured when the gate
# failed on such a runner (v1.3.1-9 era, extras-gate run 31926391167).
mkfloats "$tmp/bf16.bin" 1.00249892 2.0 3.0
python3 "$cmp_py" "$tmp/bf16.bin" "$tmp/ref.bin" 1e-2 >/dev/null 2>&1
assert_eq "$?" "0" "compare.py: a bf16-magnitude diff passes at the gate's 1e-2"
python3 "$cmp_py" "$tmp/bf16.bin" "$tmp/ref.bin" 1e-4 >/dev/null 2>&1
assert_eq "$?" "1" "compare.py: the same diff fails at the old 1e-4 (the flake being fixed)"

# The tolerance only helps if the GATE actually passes it; a future edit dropping the argument
# would silently restore the flake, and only a bf16 runner draw would notice.
# shellcheck disable=SC2016  # matching the gate's literal text, including an unexpanded $refbin
if grep -qE 'compare\.py".*"\$refbin" 1e-2' "$gate"; then
  printf 'ok: gate invokes compare.py with the bf16-tolerant 1e-2\n'
else
  printf 'FAIL: gate must pass 1e-2 to compare.py\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# Reporting the precision is the other half: a silent shift to bf16 must stay visible in the log
# so the next person does not re-derive it from scratch. Match the probe INVOCATION and the line
# that extracts its output, not the bare word "PRECISION" -- this file's own comments contain that
# word, so a looser grep would be satisfied by the documentation of the thing it is checking.
if grep -q 'devices_probe' "$gate"; then
  printf 'ok: gate asks the bundle (devices_probe), not /proc/cpuinfo\n'
else
  printf 'FAIL: gate must query the bundle through devices_probe\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
if grep -q 'PRECISION\\|CAPABILITIES' "$gate"; then
  printf 'ok: gate extracts the precision line from the probe output\n'
else
  printf 'FAIL: gate must print the probe PRECISION/CAPABILITIES lines\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# --- devices_probe.c compiles ----------------------------------------------------------------
# It needs no OpenVINO headers (dlopen + dlsym only), so a syntax check is hermetic. Nothing else
# compiles it without a vendored bundle, i.e. without paying for a full gate run first.
if command -v gcc >/dev/null 2>&1; then
  gcc -fsyntax-only "$here/openvino/devices_probe.c" 2>/dev/null
  assert_eq "$?" "0" "devices_probe.c compiles"
else
  printf 'FAIL: gcc is required to syntax-check devices_probe.c\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# --- gate script: input validation ----------------------------------------------------------
bash "$gate" >/dev/null 2>&1
assert_eq "$?" "1" "gate: no arguments is a usage error"

# A complete-looking fixture dir with one member missing must fail BEFORE the build, not produce a
# confusing compile or link error twenty lines later.
mkdir -p "$tmp/prefix" "$tmp/bundle/lib" "$tmp/fx"
: > "$tmp/bundle/lib/libopenvino_c.so"
: > "$tmp/fx/openvino_tiny.pte"
: > "$tmp/fx/in.bin"
: > "$tmp/fx/out.bin"
printf 'OV_IN=8\nOV_OUT=8\n' > "$tmp/fx/shape"

for missing in openvino_tiny.pte in.bin out.bin shape; do
  mv "$tmp/fx/$missing" "$tmp/$missing.stash"
  out="$(bash "$gate" "$tmp/prefix" "$tmp/bundle" "$tmp/fx" 2>&1)"
  rc=$?
  mv "$tmp/$missing.stash" "$tmp/fx/$missing"
  assert_eq "$rc" "1" "gate: missing $missing fails"
  assert_contains "$out" "$missing missing" "gate: names the missing member ($missing)"
done

mv "$tmp/bundle/lib/libopenvino_c.so" "$tmp/lib.stash"
out="$(bash "$gate" "$tmp/prefix" "$tmp/bundle" "$tmp/fx" 2>&1)"
rc=$?
mv "$tmp/lib.stash" "$tmp/bundle/lib/libopenvino_c.so"
assert_eq "$rc" "1" "gate: missing libopenvino_c.so fails"
assert_contains "$out" "libopenvino_c.so missing" "gate: names the missing bundle lib"

# A malformed shape file must fail loudly. Falling through with empty dims would export OV_IN=""
# and the runner would exit 2 on atoi of an empty string — a much harder failure to read.
printf 'OV_IN=\nOV_OUT=8\n' > "$tmp/fx/shape"
out="$(bash "$gate" "$tmp/prefix" "$tmp/bundle" "$tmp/fx" 2>&1)"
assert_eq "$?" "1" "gate: unparseable shape file fails"
assert_contains "$out" "OV_IN/OV_OUT" "gate: explains the shape-file failure"

# --- workflow wiring --------------------------------------------------------------------------
# The gate is worth nothing if no job runs it, and a rename here would not otherwise be caught.
wf="$(cat "$here/../.github/workflows/extras-gate.yml")"
assert_contains "$wf" "test/openvino_fixture_run.sh" "extras-gate full-build runs the fixture gate"

exit "$ASSERT_FAILS"
