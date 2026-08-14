# OpenVINO on linux-x86_64 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the ExecuTorch OpenVINO delegate in all three Linux `x86_64` variants, and publish the OpenVINO CPU runtime as a separate hash-pinned release asset with handover docs for the Python and JNI consumers.

**Architecture:** One cmake flag (`EXECUTORCH_BUILD_OPENVINO=ON`, platform-gated) turns on a 43 KB static backend that resolves OpenVINO via `dlopen` at runtime — no build-time SDK. A new `scripts/vendor-openvino.sh` assembles the CPU-only OpenVINO runtime from the Apache-2.0 PyPI wheel into a flat, `$ORIGIN`-resolving bundle published as `openvino-runtime-<ovver>-linux-x86_64.tar.gz` (contract C10). All naming, versions, and member lists live in one new SSOT library, `scripts/lib/openvino.sh`.

**Tech Stack:** bash (`set -euo pipefail`), cmake, GitHub Actions, `quay.io/pypa/manylinux_2_28_x86_64`, OpenVINO 2025.4.1, oneTBB 2021.13.1, hwloc 2.8.0.

**Spec:** `docs/superpowers/specs/2026-08-14-openvino-linux-x86_64-design.md`

## Global Constraints

- **Platform scope is `linux-x86_64` only.** No Windows (no `dlopen`; upstream's extra is `platform_system == 'Linux'`), no `linux-aarch64` (Intel CPU plugin is x86-64), no macOS.
- **Shell scripts run under `set -euo pipefail`.** `grep` exits 1 on no-match, which aborts under `set -e`/`pipefail` — guard with `|| true`, matching existing code.
- **All scripts must be idempotent** — re-runs must not fail on already-patched sources or existing trees.
- **Pinned versions (exact, copied verbatim):**
  - OpenVINO `2025.4.1`, ABI soname suffix `2541`, wheel build `20426`
  - Wheel SHA-256 `88f074286d420c1a1a95e7f2ba11109a899f2f3b3fd818cfe1e47ead22cc7e45`
  - hwloc `2.8.0`, license URL `https://raw.githubusercontent.com/open-mpi/hwloc/hwloc-2.8.0/COPYING`
  - oneTBB `2021.13.1` (bundled by the wheel; no separate pin)
- **Supported consumer range** to document: `openvino>=2025.1.0,<2026.0.0`, with the rule **runtime version ≥ export version**.
- **`OPENVINO_LIB_PATH` is a full path to the `libopenvino_c.so` *file*, not a directory.** It is read at `dlopen` time under `std::call_once` — a first failure is permanent for the process.
- **License passthrough is a hard gate.** A bundle missing any license file must fail the build, mirroring the existing Google Highway treatment.
- New unit tests are `test/<name>.test.sh` (auto-discovered by `test/run.sh`, must be hermetic — no build, no container, no network). Tests needing a container or real artifacts are `test/<name>_smoke.sh` / `test/<name>.sh` and are **not** auto-discovered.
- Work happens on branch `feature/openvino-linux-x86_64` (already created); land via PR.

---

### Task 1: OpenVINO SSOT library

Creates the single source of truth for the OpenVINO version, ABI suffix, member lists, and asset naming — consumed by the vendoring script, the packaging tests, the pin generator, and CI. Nothing else may hardcode these values.

**Files:**
- Create: `scripts/lib/openvino.sh`
- Test: `test/lib_openvino.test.sh`

**Interfaces:**
- Consumes: nothing (leaf library).
- Produces, all sourced by later tasks:
  - Variables: `OV_VERSION` (`2025.4.1`), `OV_ABI` (`2541`), `OV_WHEEL_SHA256`, `OV_WHEEL_PYTAG` (`cp312`), `OV_HWLOC_VERSION` (`2.8.0`), `OV_HWLOC_LICENSE_URL`
  - `ov_lib_members()` → newline-separated list of `lib/` basenames (6 entries, no symlink)
  - `ov_license_members()` → newline-separated list of `licenses/` basenames (5 entries)
  - `ov_asset_stem <platform>` → `openvino-runtime-<OV_VERSION>-<platform>`
  - `ov_tarball_name <platform>` → `<stem>.tar.gz`
  - `ov_sha_name <platform>` → `<stem>.tar.gz.sha256`

- [ ] **Step 1: Write the failing test**

Create `test/lib_openvino.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"

assert_eq "$OV_VERSION" "2025.4.1" "pinned OpenVINO version"
assert_eq "$OV_ABI"     "2541"     "pinned OpenVINO soname suffix"
assert_eq "${#OV_WHEEL_SHA256}" "64" "wheel sha256 is 64 hex chars"
assert_eq "$OV_HWLOC_VERSION" "2.8.0" "pinned hwloc version"
assert_contains "$OV_HWLOC_LICENSE_URL" "hwloc-2.8.0/COPYING" "hwloc license URL is version-pinned"

assert_eq "$(ov_asset_stem linux-x86_64)"  "openvino-runtime-2025.4.1-linux-x86_64"            "asset stem"
assert_eq "$(ov_tarball_name linux-x86_64)" "openvino-runtime-2025.4.1-linux-x86_64.tar.gz"     "tarball name"
assert_eq "$(ov_sha_name linux-x86_64)"     "openvino-runtime-2025.4.1-linux-x86_64.tar.gz.sha256" "sha name"

# The lib member list is the contract the bundle test and vendor script share.
libs="$(ov_lib_members)"
assert_eq "$(printf '%s\n' "$libs" | wc -l)" "6" "six runtime libs"
for m in "libopenvino_c.so.2541" "libopenvino.so.2541" "libopenvino_intel_cpu_plugin.so" \
         "libtbb.so.12" "libtbbbind_2_5.so.3" "libhwloc.so.15"; do
  assert_contains "$libs" "$m" "lib member: $m"
done
# The unversioned symlink is CREATED by the vendor script, not copied from the wheel,
# so it must NOT appear in the member list. grep -x anchors the whole line, so the
# versioned libopenvino_c.so.2541 does not false-positive here.
if printf '%s\n' "$libs" | grep -qx 'libopenvino_c.so'; then
  printf 'FAIL: unversioned symlink must not be a wheel member\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: unversioned symlink is not a wheel member\n'
fi

lics="$(ov_license_members)"
assert_eq "$(printf '%s\n' "$lics" | wc -l)" "5" "five license files"
for m in "LICENSE" "runtime-third-party-programs.txt" "onetbb_third-party-programs.txt" \
         "onednn_third-party-programs.txt" "hwloc-COPYING"; do
  assert_contains "$lics" "$m" "license member: $m"
done

ov_asset_stem >/dev/null 2>&1; assert_eq "$?" "2" "missing platform returns 2"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_openvino.test.sh`
Expected: FAIL — `scripts/lib/openvino.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/openvino.sh`:

```bash
#!/usr/bin/env bash
# OpenVINO runtime bundle: pinned version + members + asset naming (contract C10).
# SINGLE SOURCE OF TRUTH — sourced by scripts/vendor-openvino.sh (assembly), scripts/gen-pin.sh
# (pin rows), the bundle/smoke tests, and CI. Never re-derive any of these at a call site.
#
# We vendor from the PyPI wheel, not Intel's toolkit archive, for two reasons:
#   1. LICENSING. The archive's runtime/lib/* is under the Intel OpenVINO Distribution License
#      (its docs/licensing/readme.txt says only headers/samples/python are Apache 2.0), and its
#      redist.txt does not list Linux TBB. The wheel is Apache 2.0 end to end.
#   2. RELOCATABILITY. The wheel's libs already carry RPATH=$ORIGIN, so a flat directory
#      self-resolves with no LD_LIBRARY_PATH and no patchelf (i.e. no binary modification).
# Source me.

OV_VERSION="2025.4.1"
# soname suffix: libopenvino.so.<OV_ABI>. Derived from OV_VERSION by upstream (2025.4.1 -> 2541)
# but NOT computable from it in general, so it is pinned explicitly and asserted in tests.
OV_ABI="2541"
OV_WHEEL_PYTAG="cp312"
OV_WHEEL_SHA256="88f074286d420c1a1a95e7f2ba11109a899f2f3b3fd818cfe1e47ead22cc7e45"

# hwloc is BSD-3-Clause and is NOT attributed anywhere in the wheel's license material (verified:
# zero matches for "hwloc"/"Portable Hardware Locality" across LICENSE and all three
# *-third-party-programs.txt). Shipping libhwloc.so.15 therefore requires fetching its notice
# ourselves — same hard-gate treatment as Google Highway in build_extras. The release string is
# stripped from the binary; 2.8.0 was determined by calling hwloc_get_api_version() (0x020800).
OV_HWLOC_VERSION="2.8.0"
OV_HWLOC_LICENSE_URL="https://raw.githubusercontent.com/open-mpi/hwloc/hwloc-${OV_HWLOC_VERSION}/COPYING"

# CPU-only runtime set. Deliberately EXCLUDES the GPU/NPU plugins and every model frontend
# (ONNX/TF/PyTorch/Paddle/JAX): we import a precompiled blob via ov_core_import_model and never
# parse a model format. libtbbbind/libhwloc are included because libtbb dlopens tbbbind BY NAME
# (it is not a NEEDED entry), which pulls hwloc via its own NEEDED + $ORIGIN — verified under
# LD_DEBUG=libs. Omitting them is safe (TBB degrades gracefully) but loses NUMA-aware binding.
ov_lib_members() {
  cat <<EOF
libopenvino_c.so.${OV_ABI}
libopenvino.so.${OV_ABI}
libopenvino_intel_cpu_plugin.so
libtbb.so.12
libtbbbind_2_5.so.3
libhwloc.so.15
EOF
}

# hwloc-COPYING is fetched separately (see above); the other four are declared License-Files in
# the wheel and are copied straight out of its dist-info.
ov_license_members() {
  cat <<'EOF'
LICENSE
runtime-third-party-programs.txt
onetbb_third-party-programs.txt
onednn_third-party-programs.txt
hwloc-COPYING
EOF
}

ov_asset_stem() { # <platform>
  [ $# -ge 1 ] && [ -n "${1:-}" ] || { echo "ov_asset_stem: platform required" >&2; return 2; }
  printf 'openvino-runtime-%s-%s' "$OV_VERSION" "$1"
}
ov_tarball_name() { printf '%s.tar.gz' "$(ov_asset_stem "$@")"; }
ov_sha_name()     { printf '%s.sha256' "$(ov_tarball_name "$@")"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_openvino.test.sh`
Expected: PASS — every `ok:` line, exit 0.

Also run the whole suite to confirm nothing regressed: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (note: `extras_members.test.sh` requires a built prefix; if it was already failing in this checkout it will still fail — that is pre-existing and unrelated).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/openvino.sh test/lib_openvino.test.sh
git commit -m "feat: add OpenVINO SSOT library (version, members, C10 naming)"
```

---

### Task 2: Enable the backend on `linux-x86_64`

Adds `EXECUTORCH_BUILD_OPENVINO=ON` to the common flags, platform-gated. This is the change that actually makes the delegate exist in our tarballs.

**Files:**
- Modify: `scripts/lib/cmakeflags.sh` (`common_cmake_flags`, `effective_cmake_flags`)
- Test: `test/lib_cmakeflags.test.sh` (create)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `common_cmake_flags <platform>` — **signature change**, now takes a platform argument. Verified safe: `common_cmake_flags` has **no callers outside `scripts/lib/cmakeflags.sh`**; `build-runtime.sh` and `scripts/package.sh` both go through `effective_cmake_flags "$PLATFORM" "$VARIANT"`, which already has the platform.

- [ ] **Step 1: Write the failing test**

Create `test/lib_cmakeflags.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/configure-base.sh"
. "$here/../scripts/lib/variants.sh"
. "$here/../scripts/lib/cmakeflags.sh"

# OpenVINO is linux-x86_64 ONLY: the backend uses dlopen/CMAKE_DL_LIBS and -frtti/-fexceptions
# (GCC spelling), and the Intel CPU plugin is x86-64.
assert_contains "$(common_cmake_flags linux-x86_64)" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
  "openvino enabled on linux-x86_64"
case "$(common_cmake_flags linux-aarch64)" in
  *OPENVINO*) printf 'FAIL: openvino must not be enabled on linux-aarch64\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: openvino absent on linux-aarch64\n' ;;
esac
case "$(common_cmake_flags windows-x86_64)" in
  *OPENVINO*) printf 'FAIL: openvino must not be enabled on windows\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: openvino absent on windows-x86_64\n' ;;
esac

# Variant-independent: present for all three Linux variants.
for v in bare logging devtools; do
  assert_contains "$(effective_cmake_flags linux-x86_64 "$v")" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
    "effective flags carry openvino for variant $v"
done
# Windows composition is untouched.
case "$(effective_cmake_flags windows-x86_64-static logging)" in
  *OPENVINO*) printf 'FAIL: windows effective flags must not carry openvino\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: windows effective flags clean\n' ;;
esac
# Pre-existing invariants must survive the signature change.
assert_contains "$(common_cmake_flags linux-x86_64)" "-DEXECUTORCH_BUILD_XNNPACK=ON" "xnnpack still present"
assert_contains "$(common_cmake_flags linux-x86_64)" "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" "PIC still present"
assert_eq "$(printf '%s\n' $(effective_cmake_flags windows-x86_64 logging) | grep -c -- '-DCMAKE_BUILD_TYPE=Release')" \
  "1" "dedup still collapses repeats"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_cmakeflags.test.sh`
Expected: FAIL — `openvino enabled on linux-x86_64` missing (`common_cmake_flags` currently ignores its argument and emits no OPENVINO flag).

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib/cmakeflags.sh`, replace the `common_cmake_flags` function with:

```bash
# Common (variant-independent) cmake flags — SINGLE SOURCE OF TRUTH shared by the build
# (build-runtime.sh) and the recorded provenance (package.sh -> BUILDINFO cmake_flags, C5), so the
# two can never drift. Excludes only genuinely machine-specific flags (-DCMAKE_INSTALL_PREFIX), which
# the build sets separately and which are deliberately not recorded.
#
# Takes a PLATFORM because EXECUTORCH_BUILD_OPENVINO is linux-x86_64 only: the backend uses
# dlopen/${CMAKE_DL_LIBS} and compiles with -frtti/-fexceptions (GCC/Clang spelling, breaks MSVC),
# and the Intel CPU plugin it dlopens is x86-64. Upstream gates its own extra the same way
# (platform_system == 'Linux'). The backend adds no build-time dependency: it resolves the OpenVINO
# C API at RUNTIME via dlopen, so no SDK is needed in the build container.
# Source me.
common_cmake_flags() { # <platform>
  local flags='-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON'
  case "${1:-}" in
    linux-x86_64) flags="$flags -DEXECUTORCH_BUILD_OPENVINO=ON" ;;
  esac
  printf -- '%s' "$flags"
}
```

Then in `effective_cmake_flags`, pass the platform through — change the final line from
`_dedupe_flags "$base $variant $(common_cmake_flags)"` to:

```bash
  _dedupe_flags "$base $variant $(common_cmake_flags "$1")"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_cmakeflags.test.sh`
Expected: PASS.

Confirm the existing suite still passes (`build_cli.test.sh` and `package.test.sh` assert with `assert_contains`, so an added flag does not break them):

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo the pre-existing `extras_members` prefix dependency).

Verify the real composition by hand:

Run: `./build-runtime.sh --print-flags --variant logging`
Expected: output contains `-DEXECUTORCH_BUILD_OPENVINO=ON`

Run: `./build-runtime.sh --print-flags --variant logging --platform windows-x86_64-static`
Expected: output contains **no** `OPENVINO`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/cmakeflags.sh test/lib_cmakeflags.test.sh
git commit -m "feat: enable EXECUTORCH_BUILD_OPENVINO on linux-x86_64"
```

---

### Task 3: Vendoring script + hermetic bundle test

Assembles the C10 bundle from the wheel. The test synthesizes a fake wheel so it stays hermetic (no network, no 50 MB download); Task 4 exercises the real thing.

**Files:**
- Create: `scripts/vendor-openvino.sh`
- Test: `test/openvino_bundle.test.sh`

**Interfaces:**
- Consumes: `scripts/lib/openvino.sh` (Task 1) — all variables and functions listed there.
- Produces: `scripts/vendor-openvino.sh --out <dir> [--wheel <path>] [--hwloc-license <path>]`, which creates `<dir>/<ov_asset_stem linux-x86_64>/{lib,licenses,BUILDINFO}` and prints the created directory path on stdout. `--wheel` and `--hwloc-license` skip the corresponding download (used by tests and by air-gapped builds).

- [ ] **Step 1: Write the failing test**

Create `test/openvino_bundle.test.sh`:

```bash
#!/usr/bin/env bash
# Hermetic: builds a SYNTHETIC wheel + license file, runs the vendor script against them, and
# asserts the bundle's shape. No network, no container, no real OpenVINO. The real wheel is
# exercised by test/openvino_smoke.sh, which needs a container.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"

command -v zip >/dev/null 2>&1 || { echo "SKIP: zip not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- synthesize a wheel with exactly the members the script expects ---
wheelsrc="$tmp/wheelsrc"
mkdir -p "$wheelsrc/openvino/libs" "$wheelsrc/openvino-${OV_VERSION}.dist-info/licenses/licensing"
while read -r m; do printf 'ELF-STUB %s\n' "$m" > "$wheelsrc/openvino/libs/$m"; done <<EOF
$(ov_lib_members)
EOF
printf 'Apache License 2.0 stub\n' > "$wheelsrc/openvino-${OV_VERSION}.dist-info/licenses/LICENSE"
for f in runtime-third-party-programs.txt onetbb_third-party-programs.txt onednn_third-party-programs.txt; do
  printf 'notice stub %s\n' "$f" > "$wheelsrc/openvino-${OV_VERSION}.dist-info/licenses/licensing/$f"
done
wheel="$tmp/openvino-${OV_VERSION}-${OV_WHEEL_PYTAG}-${OV_WHEEL_PYTAG}-manylinux2014_x86_64.whl"
( cd "$wheelsrc" && zip -q -r "$wheel" . )
printf 'hwloc BSD-3-Clause stub\n' > "$tmp/hwloc-COPYING"

out="$tmp/out"
bundle="$(bash "$here/../scripts/vendor-openvino.sh" --out "$out" \
  --wheel "$wheel" --hwloc-license "$tmp/hwloc-COPYING")" \
  || { echo "FAIL: vendor-openvino.sh exited non-zero"; exit 1; }

assert_eq "$(basename "$bundle")" "$(ov_asset_stem linux-x86_64)" "bundle dir is the asset stem"

while read -r m; do
  [ -f "$bundle/lib/$m" ] && printf 'ok: lib member %s\n' "$m" \
    || { printf 'FAIL: missing lib member %s\n' "$m" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done <<EOF
$(ov_lib_members)
EOF

while read -r m; do
  [ -f "$bundle/licenses/$m" ] && printf 'ok: license %s\n' "$m" \
    || { printf 'FAIL: missing license %s\n' "$m" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done <<EOF
$(ov_license_members)
EOF

# The unversioned symlink is what makes the backend's DEFAULT dlopen name resolvable; the wheel
# does not ship it, so the script must create it.
[ -L "$bundle/lib/libopenvino_c.so" ] && printf 'ok: unversioned symlink created\n' \
  || { printf 'FAIL: libopenvino_c.so symlink missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_eq "$(readlink "$bundle/lib/libopenvino_c.so")" "libopenvino_c.so.${OV_ABI}" "symlink is relative to sibling"

# Nothing from the excluded set may leak in (GPU/NPU plugins, frontends).
for bad in libopenvino_intel_gpu_plugin.so libopenvino_intel_npu_plugin.so libopenvino_onnx_frontend.so; do
  [ -e "$bundle/lib/$bad" ] && { printf 'FAIL: excluded member leaked: %s\n' "$bad" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } \
    || printf 'ok: excluded %s\n' "$bad"
done

binfo="$(cat "$bundle/BUILDINFO")"
assert_contains "$binfo" "ov_version=${OV_VERSION}"      "BUILDINFO records ov_version"
assert_contains "$binfo" "ov_abi=${OV_ABI}"              "BUILDINFO records ov_abi"
assert_contains "$binfo" "hwloc_version=${OV_HWLOC_VERSION}" "BUILDINFO records hwloc_version"
assert_contains "$binfo" "platform=linux-x86_64"         "BUILDINFO records platform"

# HARD GATE: a missing license must abort, never ship unattributed binaries.
out2="$tmp/out2"
bash "$here/../scripts/vendor-openvino.sh" --out "$out2" --wheel "$wheel" \
  --hwloc-license "$tmp/definitely-missing" >/dev/null 2>&1
assert_eq "$?" "1" "missing hwloc license aborts the bundle"

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/openvino_bundle.test.sh`
Expected: FAIL — `scripts/vendor-openvino.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/vendor-openvino.sh` (and `chmod +x` it):

```bash
#!/usr/bin/env bash
# Assemble the C10 OpenVINO CPU runtime bundle from the Apache-2.0 PyPI wheel.
#
#   vendor-openvino.sh --out <dir> [--wheel <path>] [--hwloc-license <path>]
#
# Produces <dir>/openvino-runtime-<ovver>-linux-x86_64/{lib,licenses,BUILDINFO} and prints that
# directory. The layout is deliberately FLAT: every wheel lib carries RPATH=$ORIGIN, so one
# directory self-resolves the whole graph (libopenvino_c -> libopenvino -> tbb; tbb dlopens
# tbbbind -> hwloc) with NO LD_LIBRARY_PATH and NO patchelf — i.e. no modification of the
# redistributed binaries.
#
# We ADD the unversioned libopenvino_c.so symlink: the wheel ships only the SONAME-versioned file,
# so ExecuTorch's default dlopen("libopenvino_c.so") would fail against a bare wheel install.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/openvino.sh"

PLATFORM="linux-x86_64"
OUT=""; WHEEL=""; HWLOC_LICENSE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)            OUT="$2"; shift 2 ;;
    --wheel)          WHEEL="$2"; shift 2 ;;
    --hwloc-license)  HWLOC_LICENSE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:?--out required}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- obtain the wheel ----
if [ -z "$WHEEL" ]; then
  echo ">> downloading openvino==$OV_VERSION wheel" >&2
  pip download "openvino==$OV_VERSION" --no-deps --only-binary :all: \
    --python-version "${OV_WHEEL_PYTAG#cp}" --platform manylinux2014_x86_64 -d "$WORK/dl" >&2
  WHEEL="$(ls "$WORK"/dl/openvino-*.whl)"
  # Verify the pin only for a downloaded wheel; a caller-supplied --wheel is trusted (tests use a
  # synthetic one). A mismatch here means the pinned version was re-uploaded or we resolved wrong.
  actual="$(sha256sum "$WHEEL" | cut -d' ' -f1)"
  [ "$actual" = "$OV_WHEEL_SHA256" ] || {
    echo "vendor-openvino.sh: wheel sha256 mismatch" >&2
    echo "  expected: $OV_WHEEL_SHA256" >&2
    echo "  actual:   $actual" >&2
    exit 1
  }
fi
[ -f "$WHEEL" ] || { echo "vendor-openvino.sh: wheel '$WHEEL' not found" >&2; exit 1; }

# ---- obtain the hwloc notice (BSD-3-Clause; NOT bundled in the wheel) ----
if [ -z "$HWLOC_LICENSE" ]; then
  HWLOC_LICENSE="$WORK/hwloc-COPYING"
  echo ">> fetching hwloc $OV_HWLOC_VERSION COPYING" >&2
  curl -fsSL "$OV_HWLOC_LICENSE_URL" -o "$HWLOC_LICENSE" || {
    echo "vendor-openvino.sh: could not fetch hwloc license from $OV_HWLOC_LICENSE_URL" >&2
    echo "  Refusing to ship libhwloc.so.15 unattributed. Supply --hwloc-license, or drop" >&2
    echo "  libtbbbind/libhwloc from ov_lib_members (losing NUMA binding) — never ship without it." >&2
    exit 1
  }
fi
[ -s "$HWLOC_LICENSE" ] || {
  echo "vendor-openvino.sh: hwloc license '$HWLOC_LICENSE' missing or empty" >&2; exit 1; }

# ---- extract ----
unzip -q "$WHEEL" -d "$WORK/x"
STEM="$(ov_asset_stem "$PLATFORM")"
BUNDLE="$OUT/$STEM"
# Idempotent: a re-run replaces any previous bundle rather than merging into it.
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/lib" "$BUNDLE/licenses"

src="$WORK/x/openvino/libs"
while read -r m; do
  [ -f "$src/$m" ] || { echo "vendor-openvino.sh: wheel is missing expected lib '$m'" >&2; exit 1; }
  cp -a "$src/$m" "$BUNDLE/lib/$m"
done <<EOF
$(ov_lib_members)
EOF

# Relative symlink so the bundle stays relocatable.
ln -sfn "libopenvino_c.so.${OV_ABI}" "$BUNDLE/lib/libopenvino_c.so"

lic="$WORK/x/openvino-${OV_VERSION}.dist-info/licenses"
cp -a "$lic/LICENSE" "$BUNDLE/licenses/LICENSE"
for f in runtime-third-party-programs.txt onetbb_third-party-programs.txt onednn_third-party-programs.txt; do
  [ -f "$lic/licensing/$f" ] || { echo "vendor-openvino.sh: wheel is missing license '$f'" >&2; exit 1; }
  cp -a "$lic/licensing/$f" "$BUNDLE/licenses/$f"
done
cp -a "$HWLOC_LICENSE" "$BUNDLE/licenses/hwloc-COPYING"

# Hard gate: every declared license member must exist before we call this a bundle.
while read -r m; do
  [ -s "$BUNDLE/licenses/$m" ] || { echo "vendor-openvino.sh: license '$m' missing/empty" >&2; exit 1; }
done <<EOF
$(ov_license_members)
EOF

cat > "$BUNDLE/BUILDINFO" <<EOF
ov_version=$OV_VERSION
ov_abi=$OV_ABI
platform=$PLATFORM
hwloc_version=$OV_HWLOC_VERSION
source_wheel=$(basename "$WHEEL")
source_wheel_sha256=$(sha256sum "$WHEEL" | cut -d' ' -f1)
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

printf '%s\n' "$BUNDLE"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/vendor-openvino.sh && bash test/openvino_bundle.test.sh`
Expected: PASS — every member, the symlink, BUILDINFO keys, and the missing-license hard gate.

- [ ] **Step 5: Commit**

```bash
git add scripts/vendor-openvino.sh test/openvino_bundle.test.sh
git commit -m "feat: add vendor-openvino.sh producing the C10 bundle"
```

---

### Task 4: Real-artifact runtime smoke test

Proves the assembled bundle actually works: dlopen by absolute path with `LD_LIBRARY_PATH` **unset**, then enumerate devices. This is the only test that catches a broken `$ORIGIN`, a missing plugin, or missing TBB — a file-listing test cannot see any of those.

**Files:**
- Create: `test/openvino/devices_probe.c`
- Create: `test/openvino_smoke.sh`

**Interfaces:**
- Consumes: a bundle directory produced by `scripts/vendor-openvino.sh` (Task 3).
- Produces: `bash test/openvino_smoke.sh <bundle-dir>` — exit 0 iff `CPU` is enumerated. Called by CI in Task 8.

- [ ] **Step 1: Write the failing test**

Create `test/openvino/devices_probe.c`:

```c
// Mirrors exactly what ExecuTorch's OpenvinoBackend::ensure_loaded does:
//   dlopen(path, RTLD_NOW|RTLD_LOCAL) then dlsym the C API.
// Enumerating devices is the real test: it forces OpenVINO to locate and load its PLUGIN .so
// files, which is the part a flat-bundle layout can get wrong. A dlopen that merely succeeds
// proves nothing about the plugins.
#include <dlfcn.h>
#include <stdio.h>
#include <stddef.h>

typedef struct ov_core ov_core_t;
typedef struct { char** devices; size_t size; } ov_available_devices_t;
typedef int (*fn_core_create)(ov_core_t**);
typedef int (*fn_core_free)(ov_core_t*);
typedef int (*fn_devices)(const ov_core_t*, ov_available_devices_t*);

int main(int argc, char** argv) {
  if (argc < 2) { printf("usage: devices_probe <libopenvino_c.so>\n"); return 2; }
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { printf("DLOPEN FAIL: %s\n", dlerror()); return 1; }

  fn_core_create create = (fn_core_create)dlsym(h, "ov_core_create");
  fn_core_free   freec  = (fn_core_free)dlsym(h, "ov_core_free");
  fn_devices     devs   = (fn_devices)dlsym(h, "ov_core_get_available_devices");
  if (!create || !freec || !devs) { printf("DLSYM FAIL\n"); return 1; }

  ov_core_t* core = NULL;
  if (create(&core) != 0) { printf("ov_core_create FAILED\n"); return 1; }

  ov_available_devices_t d = {0};
  if (devs(core, &d) != 0) { printf("get_available_devices FAILED\n"); return 1; }
  for (size_t i = 0; i < d.size; i++) printf("DEVICE %s\n", d.devices[i]);
  freec(core);
  return 0;
}
```

Create `test/openvino_smoke.sh`:

```bash
#!/usr/bin/env bash
# Runtime acceptance gate for the C10 bundle. Proves the FLAT bundle self-resolves:
# dlopen by absolute path with LD_LIBRARY_PATH explicitly UNSET, then enumerate devices.
# Usage: openvino_smoke.sh <bundle-dir>
# Runs inside manylinux_2_28 (needs a C compiler); self-provisions gcc-toolset like
# test/relocatability.sh does.
set -euo pipefail
BUNDLE="${1:?usage: openvino_smoke.sh <bundle-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f /opt/rh/gcc-toolset-14/enable ] && source /opt/rh/gcc-toolset-14/enable

lib="$BUNDLE/lib/libopenvino_c.so"
[ -e "$lib" ] || { echo "FAIL: $lib missing" >&2; exit 1; }

BIN="$(mktemp -d)/devices_probe"
gcc "$HERE/openvino/devices_probe.c" -o "$BIN" -ldl

echo "== dlopen with LD_LIBRARY_PATH UNSET (proves \$ORIGIN self-resolution) =="
# `env -u` is the point of the test: if the bundle needed LD_LIBRARY_PATH, this fails.
out="$(env -u LD_LIBRARY_PATH "$BIN" "$lib")" || {
  echo "FAIL: probe exited non-zero" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out"

case "$out" in
  *"DEVICE CPU"*) echo "GATE PASS: bundle self-resolves and enumerates CPU" ;;
  *) echo "FAIL: CPU device not enumerated (plugin or TBB missing from the bundle?)" >&2; exit 1 ;;
esac
```

- [ ] **Step 2: Run test to verify it fails**

Build a real bundle and run the smoke test — it must fail before Task 3's script is wired for real wheels, and pass after. From the repo root:

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  bash test/openvino_smoke.sh /work/ovbundle/openvino-runtime-2025.4.1-linux-x86_64'
```

Expected: FAIL — `.../lib/libopenvino_c.so missing` (no bundle has been built yet).

- [ ] **Step 3: Write minimal implementation**

No new source — build the bundle for real, which exercises Task 3's download path end to end:

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  ./scripts/vendor-openvino.sh --out /work/ovbundle'
```

Expected: prints `/work/ovbundle/openvino-runtime-2025.4.1-linux-x86_64`; the wheel sha256 matches the pin.

- [ ] **Step 4: Run test to verify it passes**

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  bash test/openvino_smoke.sh /work/ovbundle/openvino-runtime-2025.4.1-linux-x86_64'
```

Expected: `DEVICE CPU` then `GATE PASS: bundle self-resolves and enumerates CPU`.

Clean up the scratch bundle so it is not committed: `rm -rf ovbundle` (and confirm `git status` is clean apart from the new files).

- [ ] **Step 5: Commit**

```bash
git add test/openvino/devices_probe.c test/openvino_smoke.sh
git commit -m "test: add OpenVINO bundle runtime smoke gate (dlopen + device enumeration)"
```

---

### Task 5: Make the PIC gate cover the delegate

`test/consumer` currently links only `executorch`, so nothing links `openvino_backend` and any regression in it is invisible to the relocatability/PIC gate. Linking the `executorch_backends` aggregate fixes that — upstream already puts `openvino_backend` in it.

**Files:**
- Modify: `test/consumer/CMakeLists.txt`

**Interfaces:**
- Consumes: an ET install prefix built with Task 2's flags.
- Produces: no new API; strengthens the existing `test/relocatability.sh` gate.

- [ ] **Step 1: Write the failing test**

Modify `test/consumer/CMakeLists.txt` — replace the `target_link_libraries` line with:

```cmake
# executorch_backends is the upstream aggregate; on linux-x86_64 it includes openvino_backend,
# whose imported target carries --whole-archive. Linking it here is what makes the relocatability
# /PIC gate actually cover the delegate — with only `executorch`, no backend object is ever
# extracted and an OpenVINO regression would be invisible until model-load time.
target_link_libraries(pic_probe PRIVATE executorch executorch_backends)
```

- [ ] **Step 2: Run test to verify it fails**

Against a prefix built *without* OpenVINO (i.e. the pre-Task-2 install), the aggregate does not exist yet in the way we need. Confirm the gate runs and reports the current state:

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  bash test/relocatability.sh /work/out-logging'
```

Expected: FAIL at the consumer configure/build step if `out-logging` predates Task 2 (`openvino_backend` referenced by the aggregate but absent from the prefix). If your `out-logging` was already rebuilt with OpenVINO, this passes immediately — proceed to Step 3.

- [ ] **Step 3: Write minimal implementation**

Rebuild the prefix with the Task 2 flags so the aggregate resolves. This is incremental against the persisted build tree (minutes, not the full ~15):

```bash
docker run --rm -v "$PWD":/work -v /path/to/executorch:/executorch -w /work \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  ./build-runtime.sh --variant logging --prefix /work/out-logging --et-src /executorch'
```

Expected: build succeeds; `out-logging/lib/libopenvino_backend.a` exists.

- [ ] **Step 4: Run test to verify it passes**

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  bash test/relocatability.sh /work/out-logging'
```

Expected: `GATE PASS: relocatable AND position-independent`.

Confirm the delegate's registrar really survived into the shared library:

```bash
nm -C $(find /tmp -name 'libpic_probe.so' 2>/dev/null | head -1) | grep _GLOBAL__sub_I_OpenvinoBackend
```

Expected: one `t _GLOBAL__sub_I_OpenvinoBackend.cpp` line. (If the build dir was cleaned, re-run the gate and check its temp build output.)

- [ ] **Step 5: Commit**

```bash
git add test/consumer/CMakeLists.txt
git commit -m "test: link executorch_backends so the PIC gate covers the OpenVINO delegate"
```

---

### Task 6: Record `openvino_version` in BUILDINFO (extends C5)

Provenance: a consumer holding a tarball must be able to tell which OpenVINO the delegate was built against without guessing.

**Files:**
- Modify: `scripts/gen-buildinfo.sh`
- Modify: `scripts/package.sh` (source the new lib; pass the new env var)
- Test: `test/buildinfo.test.sh` (modify), `test/package.test.sh` (modify)

**Interfaces:**
- Consumes: `OV_VERSION` from `scripts/lib/openvino.sh` (Task 1).
- Produces: BUILDINFO gains `openvino_version=<ver>` on `linux-x86_64`, and `openvino_version=n/a` elsewhere. `gen-buildinfo.sh` requires a new `OPENVINO_VERSION` env var.

- [ ] **Step 1: Write the failing test**

Append to `test/buildinfo.test.sh` (keep existing assertions; add these before the final `exit`):

```bash
# C5: OpenVINO provenance. linux-x86_64 records the pinned version; every other platform
# records n/a so the key is always present and greppable.
. "$here/../scripts/lib/openvino.sh"
out_ov="$(ET_VERSION=1.3.1 ET_COMMIT=abc TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='--preset linux' TOOLCHAIN=tc PACKAGE_TAG=v1.3.1-1 USDT=on \
  OPENVINO_VERSION="$OV_VERSION" bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out_ov" "openvino_version=$OV_VERSION" "buildinfo records openvino_version"

out_na="$(ET_VERSION=1.3.1 ET_COMMIT=abc TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=windows-x86_64 CMAKE_FLAGS='flags' TOOLCHAIN=tc PACKAGE_TAG=v1.3.1-1 USDT=n/a \
  OPENVINO_VERSION=n/a bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out_na" "openvino_version=n/a" "buildinfo records n/a off linux-x86_64"
```

Append to `test/package.test.sh` (near the existing `cmake_flags=--preset linux` assertion):

```bash
assert_contains "$bil" "openvino_version=" "openvino provenance recorded in BUILDINFO"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/buildinfo.test.sh`
Expected: FAIL — `openvino_version=` missing (and/or an unbound-variable error for `OPENVINO_VERSION`).

- [ ] **Step 3: Write minimal implementation**

In `scripts/gen-buildinfo.sh`, add `OPENVINO_VERSION` to the required-vars line and emit it. Change the guard line to include it:

```bash
: "${USDT:?}"; : "${OPENVINO_VERSION:?}"
```

and add this line to the heredoc, immediately after `usdt=$USDT`:

```
openvino_version=$OPENVINO_VERSION
```

In `scripts/package.sh`, source the new library alongside the others (after the `cmakeflags.sh` line):

```bash
. "$HERE/lib/openvino.sh"
```

and set the variable in the `gen-buildinfo.sh` invocation. Add this line to the env prefix, right after the `USDT="$USDT_STATE" \` line:

```bash
  OPENVINO_VERSION="$([ "$PLATFORM" = linux-x86_64 ] && printf '%s' "$OV_VERSION" || printf 'n/a')" \
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/buildinfo.test.sh && bash test/package.test.sh`
Expected: PASS for both.

Run the full suite: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo the pre-existing `extras_members` prefix dependency).

- [ ] **Step 5: Commit**

```bash
git add scripts/gen-buildinfo.sh scripts/package.sh test/buildinfo.test.sh test/package.test.sh
git commit -m "feat: record openvino_version in BUILDINFO (C5)"
```

---

### Task 7: Pin the OpenVINO asset in `EtRuntimePin.cmake` (C10)

Downstream must be able to `FetchContent` the OpenVINO bundle with a verified hash, exactly as it does the runtime tarballs.

**Files:**
- Modify: `scripts/gen-pin.sh`
- Test: `test/pin.test.sh` (modify)

**Interfaces:**
- Consumes: `ov_tarball_name` and `OV_VERSION` from `scripts/lib/openvino.sh` (Task 1).
- Produces: `gen-pin.sh` gains two optional args, `--openvino-sha <sha>` and `--openvino-platform <platform>` (default `linux-x86_64`). When `--openvino-sha` is given, the generated cmake also defines `ET_RUNTIME_OPENVINO_VERSION`, `ET_RUNTIME_OPENVINO_URL`, and `ET_RUNTIME_OPENVINO_SHA256`. When omitted, output is byte-identical to today's — so a release that skips the OpenVINO job still produces a valid pin.

- [ ] **Step 1: Write the failing test**

Append to `test/pin.test.sh` (before the final `exit`):

```bash
. "$here/../scripts/lib/openvino.sh"
ovsha="$(printf 'b%.0s' $(seq 64))"
pin_ov="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 \
  --base-url https://example.test/dl --row logging linux-x86_64 "$(printf 'a%.0s' $(seq 64))" \
  --openvino-sha "$ovsha")"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_VERSION \"$OV_VERSION\")" "pin records openvino version"
assert_contains "$pin_ov" "https://example.test/dl/$(ov_tarball_name linux-x86_64)" "pin records openvino url"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256 \"$ovsha\")" "pin records openvino sha"

# Omitting the flag must leave the pin exactly as before (no empty/dangling vars).
pin_no="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 \
  --base-url https://example.test/dl --row logging linux-x86_64 "$(printf 'a%.0s' $(seq 64))")"
case "$pin_no" in
  *OPENVINO*) printf 'FAIL: pin must omit OpenVINO vars when no sha is given\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: pin omits OpenVINO vars when not requested\n' ;;
esac
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/pin.test.sh`
Expected: FAIL — `unknown arg: --openvino-sha` (exit 2), so the assertions never match.

- [ ] **Step 3: Write minimal implementation**

In `scripts/gen-pin.sh`, source the OpenVINO lib after `naming.sh`:

```bash
. "$HERE/lib/openvino.sh"
```

Add the two variables and their parsing. Change the declaration line to:

```bash
VERSION=""; ETVER=""; BASEURL=""; ROWS=(); OVSHA=""; OVPLATFORM="linux-x86_64"
```

and add these cases to the `while` loop, before the `*)` catch-all:

```bash
    --openvino-sha)      OVSHA="$2"; shift 2 ;;
    --openvino-platform) OVPLATFORM="$2"; shift 2 ;;
```

Then append this block to the very end of the file, after the existing `for r in "${ROWS[@]}"` loop:

```bash
# C10: the OpenVINO CPU runtime bundle. Emitted only when a sha is supplied, so a release that
# did not run the OpenVINO job still yields a valid (OpenVINO-free) pin rather than dangling vars.
# Versioned by OPENVINO version, not ET version — it tracks an independent upstream and must be
# re-rollable without an ET bump.
if [ -n "$OVSHA" ]; then
  printf 'set(ET_RUNTIME_OPENVINO_VERSION "%s")\n' "$OV_VERSION"
  printf 'set(ET_RUNTIME_OPENVINO_URL\n  "%s/%s")\n' "$BASEURL" "$(ov_tarball_name "$OVPLATFORM")"
  printf 'set(ET_RUNTIME_OPENVINO_SHA256 "%s")\n\n' "$OVSHA"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/pin.test.sh`
Expected: PASS.

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo `extras_members`).

Sanity-check that `discover-pin-rows.sh` ignores the new asset (it only matches `executorch-runtime-<etver>-*`, so `openvino-runtime-*` is skipped — confirm no parse error):

```bash
mkdir -p /tmp/pindisc && touch /tmp/pindisc/openvino-runtime-2025.4.1-linux-x86_64.tar.gz.sha256
printf '%s  x\n' "$(printf 'a%.0s' $(seq 64))" > /tmp/pindisc/executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
./scripts/discover-pin-rows.sh --dir /tmp/pindisc --etver 1.3.1
```

Expected: exactly one row (`logging	linux-x86_64	aaa…`), no parse mismatch error.

- [ ] **Step 5: Commit**

```bash
git add scripts/gen-pin.sh test/pin.test.sh
git commit -m "feat: pin the OpenVINO runtime asset in EtRuntimePin.cmake (C10)"
```

---

### Task 8: Release CI — build, attest, and publish the OpenVINO asset

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/vendor-openvino.sh` (Task 3), `test/openvino_smoke.sh` (Task 4), `scripts/gen-pin.sh --openvino-sha` (Task 7).
- Produces: a job named `openvino` that uploads artifact `dist-openvino` containing the tarball + `.sha256`; `pin` and `release` consume it via the existing `merge-multiple: true` download.

- [ ] **Step 1: Write the failing test**

CI has no unit test; the check is a YAML parse plus a job-graph assertion. Create `test/release_workflow.test.sh`:

```bash
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
assert_contains "$(cat "$wf")" "--openvino-sha" "pin job passes the openvino sha"

# pin must depend on the openvino job, else it may run before the asset exists.
needs_line="$(grep -A1 '^  pin:' "$wf" | grep 'needs:')"
assert_contains "$needs_line" "openvino" "pin depends on the openvino job"

command -v python3 >/dev/null 2>&1 && python3 -c "
import sys,yaml
yaml.safe_load(open('$wf'))
print('ok: release.yml parses as YAML')
" || echo "SKIP: python3/pyyaml unavailable for YAML parse check"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/release_workflow.test.sh`
Expected: FAIL — `openvino job exists` missing.

- [ ] **Step 3: Write minimal implementation**

In `.github/workflows/release.yml`, insert this job after the `build-windows` job and before `pin:`:

```yaml
  # The OpenVINO CPU runtime, vendored from the Apache-2.0 PyPI wheel into a flat, $ORIGIN-resolving
  # bundle (contract C10). Linux x86_64 only and INDEPENDENT of the {variant} x {platform} matrix:
  # the bundle contains no ExecuTorch code, is identical for all three variants, and is versioned by
  # OpenVINO version rather than ET version. Runs in manylinux for the same glibc floor as the
  # runtime tarballs.
  openvino:
    runs-on: ubuntu-latest
    container:
      image: quay.io/pypa/manylinux_2_28_x86_64
    permissions:
      contents: read
      id-token: write
      attestations: write
    steps:
      - uses: actions/checkout@v7
      - name: Vendor the OpenVINO runtime bundle
        run: |
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          ./scripts/vendor-openvino.sh --out "$PWD/ovstage"
      - name: Runtime smoke gate (dlopen + enumerate CPU, LD_LIBRARY_PATH unset)
        # Proves the flat bundle self-resolves before it is attested. A file-listing check cannot
        # catch a missing plugin or a broken $ORIGIN; this can.
        run: |
          . ./scripts/lib/openvino.sh
          bash test/openvino_smoke.sh "$PWD/ovstage/$(ov_asset_stem linux-x86_64)"
      - name: Package
        run: |
          . ./scripts/lib/openvino.sh
          mkdir -p "$PWD/dist"
          stem="$(ov_asset_stem linux-x86_64)"
          tar -C "$PWD/ovstage" -czf "$PWD/dist/$(ov_tarball_name linux-x86_64)" "$stem"
          ( cd "$PWD/dist" && sha256sum "$(ov_tarball_name linux-x86_64)" > "$(ov_sha_name linux-x86_64)" )
      - name: Attest build provenance
        uses: actions/attest@v4
        with:
          subject-path: dist/*.tar.gz
      - uses: actions/upload-artifact@v7
        with:
          name: dist-openvino
          path: dist/*
```

Change the `pin` job's `needs:` line to include it:

```yaml
    needs: [build, build-windows, openvino]
```

In the `pin` job's "Generate EtRuntimePin.cmake" step, pass the sha. Replace the `args=(...)` line and add a lookup immediately after it:

```bash
          args=(--version "$pkgver" --etver "$etver" --base-url "$base")
          # C10: fold in the OpenVINO bundle if its job produced one. Reading the sha from the
          # sibling .sha256 keeps gen-pin.sh's contract (it never hashes files itself).
          . ./scripts/lib/openvino.sh
          ovsha_file="dist/$(ov_sha_name linux-x86_64)"
          if [ -f "$ovsha_file" ]; then
            args+=(--openvino-sha "$(cut -d' ' -f1 "$ovsha_file")")
          fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/release_workflow.test.sh`
Expected: PASS, including the YAML parse.

Run the full suite: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo `extras_members`).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml test/release_workflow.test.sh
git commit -m "ci: build, smoke-test, attest and pin the OpenVINO runtime asset"
```

---

### Task 9: Route OpenVINO changes through the PR gate

A change to the vendoring script or the OpenVINO SSOT must not slip through on a `tier1` kernel-only gate.

**Files:**
- Modify: `scripts/classify-gate.sh`
- Test: `test/classify_gate.test.sh` (modify)

**Interfaces:**
- Consumes: nothing new.
- Produces: `classify-gate.sh` emits `mode=full` when the changed-files list contains `scripts/vendor-openvino.sh` or `scripts/lib/openvino.sh`.

- [ ] **Step 1: Write the failing test**

Append to `test/classify_gate.test.sh` (before the final `exit`):

```bash
# An OpenVINO vendoring/SSOT change alters a published artifact's contents, so it must get the
# full treatment rather than a kernel-only tier1 gate.
for f in scripts/vendor-openvino.sh scripts/lib/openvino.sh; do
  cf="$(mktemp)"; printf '%s\n' "$f" > "$cf"
  out="$(GATE_ET_TAG=v1.3.1 GATE_RELEASE_TAG=v1.3.1-1 bash "$here/../scripts/classify-gate.sh" "$cf")"
  assert_contains "$out" "mode=full" "openvino change ($f) forces a full gate"
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/classify_gate.test.sh`
Expected: FAIL — output is `mode=tier1` for both files.

- [ ] **Step 3: Write minimal implementation**

In `scripts/classify-gate.sh`, add a new rule immediately after the existing rule (1) `build-runtime.sh` block and before rule (2):

```bash
# (1b) an OpenVINO vendoring/SSOT change alters a PUBLISHED artifact's contents (the C10 bundle:
# its members, pinned version, or license set). tier1/tier2 only rebuild extras against a
# downloaded release and would never exercise it, so force a full run.
if grep -qxE 'scripts/(vendor-openvino\.sh|lib/openvino\.sh)' "$CHANGED"; then
  emit full ""; exit 0
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/classify_gate.test.sh`
Expected: PASS, with the pre-existing cases (tier1/tier2/full) still passing.

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo `extras_members`).

- [ ] **Step 5: Commit**

```bash
git add scripts/classify-gate.sh test/classify_gate.test.sh
git commit -m "ci: route OpenVINO vendoring changes to the full gate"
```

---

### Task 10: Python consumer handover doc

Deliverable #1. Written so the slim, torch-free Python package never has to re-derive any of the spike findings.

**Files:**
- Create: `docs/openvino-python-consumer.md`

**Interfaces:**
- Consumes: the C10 asset (Task 8) and the pin variables (Task 7).
- Produces: documentation only.

- [ ] **Step 1: Write the doc**

Create `docs/openvino-python-consumer.md`:

````markdown
# Consuming the OpenVINO delegate from Python

For a slim, torch-free Python package built on this repo's runtime tarballs.

## What you need, and what you don't

The OpenVINO delegate is **already compiled into** every `linux-x86_64` runtime tarball
(`bare`, `logging`, `devtools`) as `lib/libopenvino_backend.a`. You do not enable anything.

What the tarball does **not** contain is the OpenVINO runtime itself. The delegate resolves the
OpenVINO C API with `dlopen` at first use, so OpenVINO is a **runtime** dependency only. Nothing
on this path imports PyTorch.

Exporting a model (the partitioner and quantizer) is a separate concern that lives in the
upstream `executorch` Python package and needs torch. This repo ships runtime artifacts only.

## Getting the OpenVINO runtime

**Option A — our published asset (preferred).** Each release publishes
`openvino-runtime-<ovver>-linux-x86_64.tar.gz` with a SHA-256 and a build attestation, pinned in
`EtRuntimePin.cmake` as `ET_RUNTIME_OPENVINO_URL` / `ET_RUNTIME_OPENVINO_SHA256` /
`ET_RUNTIME_OPENVINO_VERSION`. It is a flat directory that self-resolves, and the hash pin means
you get identical bytes on every build.

**Option B — pip.** `pip install "openvino>=2025.1.0,<2026.0.0"`.

## The one thing that will bite you

**The pip wheel has no unversioned `libopenvino_c.so`.** It ships only the SONAME-versioned file
(e.g. `libopenvino_c.so.2541`), but the delegate's default lookup is the *unversioned* name. So
with a plain `pip install`, the default lookup **fails**:

```
dlopen("libopenvino_c.so") -> cannot open shared object file: No such file or directory
```

You must therefore set `OPENVINO_LIB_PATH`. Three rules:

1. It is the **full path to the `.so` file**, not a directory. (The error message mentions
   `LD_LIBRARY_PATH`, which reads like it wants a directory. It does not.)
2. Set it **before the first inference**. Loading happens once under `std::call_once` with no
   retry — if the first attempt fails, the process stays broken until restart.
3. You do **not** need `LD_LIBRARY_PATH`. Every OpenVINO library carries `RPATH=$ORIGIN`, so
   pointing at one file resolves the rest of the graph from the same directory.

Resolve it like this:

```python
import glob
import os
from importlib.util import find_spec


def openvino_lib_path() -> str:
    """Absolute path to libopenvino_c.so.* inside the installed openvino wheel."""
    spec = find_spec("openvino")
    if spec is None or not spec.submodule_search_locations:
        raise RuntimeError('openvino is not installed; pip install "openvino>=2025.1.0,<2026.0.0"')
    libs = os.path.join(list(spec.submodule_search_locations)[0], "libs")
    matches = sorted(glob.glob(os.path.join(libs, "libopenvino_c.so*")))
    if not matches:
        raise RuntimeError(f"no libopenvino_c.so* under {libs}")
    return matches[0]


# MUST run before the first inference.
os.environ.setdefault("OPENVINO_LIB_PATH", openvino_lib_path())
```

If you use our published asset instead, the path is simply
`<extracted>/openvino-runtime-<ovver>-linux-x86_64/lib/libopenvino_c.so` — we add the unversioned
symlink the wheel omits, so either name works.

## Version compatibility

A `.pte` with an OpenVINO delegate embeds a **precompiled OpenVINO blob** (the AOT side calls
`compiled.export_model()`; the runtime calls `ov_core_import_model`). So the export-time and
runtime OpenVINO versions have to be compatible.

Measured across the 2025.x line, with a corrupted-blob control confirming the check is real:

| blob built with | imported by | result |
|---|---|---|
| corrupted bytes | 2025.4.1 | **fails** (control) |
| 2025.4.1 | 2025.4.0 | ok |
| 2025.4.1 | 2025.1.0 | ok |
| 2025.1.0 | 2025.4.1 | ok |

So `>=2025.1.0,<2026.0.0` is supported. The safe rule is **runtime version ≥ export version** —
the evidence above comes from a trivial graph and does not exercise version-gated operators.

Pin **one exact** OpenVINO version rather than floating within the supported range, and record it
next to your package version. A range lets a rebuild silently resolve a different OpenVINO than
the one your models were exported against, which surfaces as an import failure at model load
rather than at install time.

## Troubleshooting

| symptom | cause |
|---|---|
| `OpenVINO runtime not found (dlopen failed…)` | `OPENVINO_LIB_PATH` unset, or set to a directory instead of a file |
| Works once, then never again in the same process | first load failed; `std::call_once` does not retry — fix the env and restart |
| `IMPORT FAILED` at model load | blob/runtime version mismatch; re-export or upgrade the runtime |
| Delegate silently unused | the `.pte` was not exported with the OpenVINO partitioner |
````

- [ ] **Step 2: Verify the doc's code actually runs**

The snippet is the part most likely to be wrong, so execute it against a real wheel:

```bash
docker run --rm quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  pip install -q "openvino>=2025.1.0,<2026.0.0"
  python -c "
import glob, os
from importlib.util import find_spec
spec = find_spec(\"openvino\")
libs = os.path.join(list(spec.submodule_search_locations)[0], \"libs\")
m = sorted(glob.glob(os.path.join(libs, \"libopenvino_c.so*\")))
print(\"resolved:\", m[0]); assert os.path.exists(m[0])
"'
```

Expected: prints a real path ending in `libopenvino_c.so.<abi>` and exits 0.

- [ ] **Step 3: Commit**

```bash
git add docs/openvino-python-consumer.md
git commit -m "docs: OpenVINO handover guide for the Python consumer"
```

---

### Task 11: JNI consumer handover doc + contract documentation

Deliverable #2, plus the C10 contract entry so the repo's own docs stay the source of truth.

**Files:**
- Create: `docs/openvino-jni-consumer.md`
- Modify: `README.md` (contracts list — add C10)
- Modify: `CLAUDE.md` (architecture — mention the OpenVINO asset)

**Interfaces:**
- Consumes: the C10 asset (Task 8).
- Produces: documentation only.

- [ ] **Step 1: Write the doc**

Create `docs/openvino-jni-consumer.md`:

````markdown
# Consuming the OpenVINO delegate from Java/JNI

For a JVM application shipping qualified jars with platform-specific `.so` files. Linux
`x86_64` only — that is the only platform where this delegate exists.

## What to ship

The OpenVINO delegate is already compiled into every `linux-x86_64` runtime tarball as
`lib/libopenvino_backend.a`. The OpenVINO **runtime** is separate and must be vendored into your
jar. Use our published `openvino-runtime-<ovver>-linux-x86_64.tar.gz` — it is hash-pinned and
attested, so every build vendors identical bytes.

Its `lib/` is a **flat** directory holding exactly six libraries plus one symlink:

| file | why |
|---|---|
| `libopenvino_c.so` → `libopenvino_c.so.<abi>` | the symlink we add; the wheel omits it |
| `libopenvino_c.so.<abi>` | the C API the delegate dlopens |
| `libopenvino.so.<abi>` | core runtime |
| `libopenvino_intel_cpu_plugin.so` | the CPU device (~52 MB, the bulk of the size) |
| `libtbb.so.12` | threading |
| `libtbbbind_2_5.so.3` | NUMA-aware binding; dlopened by `libtbb` |
| `libhwloc.so.15` | topology; needed by `tbbbind` |

About **68 MB on disk, ~21 MB compressed** in a jar. GPU/NPU plugins and every model frontend
(ONNX/TF/PyTorch/…) are deliberately excluded: you consume a precompiled blob and never parse a
model format.

**Extract all of them into one directory and keep them together.** Every library carries
`RPATH=$ORIGIN`, so a flat directory resolves the entire graph with no `LD_LIBRARY_PATH`, no
`ldconfig`, and no system install. Splitting them across directories breaks that.

## The critical part: you cannot use `LD_LIBRARY_PATH` from Java

glibc's dynamic loader reads `LD_LIBRARY_PATH` **once, at process start**. A JVM cannot change
its own — `System.getenv` is read-only, and `ProcessBuilder` only affects child processes. Even
`setenv("LD_LIBRARY_PATH", …)` from JNI is too late to influence later `dlopen` calls.

`OPENVINO_LIB_PATH` does not have this problem: the delegate reads it at `dlopen` time. So from
JNI it is the **only** mechanism that works.

```c
// In your JNI init, AFTER extracting the natives and BEFORE the first inference.
// dir = absolute path to the directory you extracted lib/ into.
static int etnp_init_openvino(const char* dir) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/libopenvino_c.so", dir);
  // overwrite=1: a stale value from a previous init would silently win.
  if (setenv("OPENVINO_LIB_PATH", path, 1) != 0) {
    return -1;
  }
  return 0;
}
```

Three rules, all of which have bitten people:

1. `OPENVINO_LIB_PATH` is the **full path to the `.so` file**, not the directory.
2. Set it **before the first inference**. The delegate loads once under `std::call_once` and
   never retries — a first failure poisons the process until restart.
3. Extract to a **stable, readable** directory. A temp dir cleaned between the `setenv` and the
   first inference fails exactly the same way.

## Platform floor

The bundle is built from the `manylinux2014` wheel; its libraries need at most **glibc 2.17 /
GLIBCXX 3.4.19 / CXXABI 1.3.7**, comfortably below the glibc 2.28 floor of our `linux-x86_64`
runtime tarballs. So if our runtime tarball runs on a host, this bundle does too.

## Why not Intel's toolkit archive?

It is ABI-compatible with `manylinux_2_28` and would work if you installed it yourself. We do not
redistribute it for two reasons: its `runtime/lib/*` is under the Intel OpenVINO Distribution
License (only headers/samples/Python are Apache 2.0) and its `redist.txt` does not list Linux
TBB; and its libraries carry **no `RPATH`**, so making them work from JNI would require
`patchelf` — modifying Intel-provided binaries. The PyPI wheel is Apache 2.0 end to end and
already ships `$ORIGIN`, so we vendor from it and modify nothing.

If you install the Intel archive into your own container instead, note that it *does* ship the
unversioned `libopenvino_c.so` symlink, but you must set `LD_LIBRARY_PATH` to both
`runtime/lib/intel64` **and** `runtime/3rdparty/tbb/lib` at process launch — which, per the
section above, cannot be done from inside the JVM.

## Version compatibility

A `.pte` embeds a precompiled OpenVINO blob, so export-time and runtime versions must be
compatible. Compatibility was measured to hold in both directions across 2025.1 ↔ 2025.4 (with a
corrupted-blob control proving the check is real), so `>=2025.1.0,<2026.0.0` is supported, with
**runtime version ≥ export version** as the safe rule.

Vendor **one exact** OpenVINO version rather than floating within the supported range, and record
it in your jar's manifest. A range lets a rebuild silently vendor a different OpenVINO than the
one your models were exported against, which surfaces as an import failure at model load rather
than at build time.

## Checklist

- [ ] Vendor the six libs + symlink into one flat directory in the Linux-qualified jar
- [ ] Extract them together, preserving the symlink, to a stable directory
- [ ] `setenv("OPENVINO_LIB_PATH", "<dir>/libopenvino_c.so", 1)` in JNI init
- [ ] Do this before the first inference
- [ ] Ship `licenses/` from the bundle — Apache 2.0 plus the hwloc BSD-3-Clause notice
````

- [ ] **Step 2: Document contract C10**

In `README.md`, add this entry to the contracts list immediately after the `C9` entry:

```markdown
- **C10 — OpenVINO runtime asset (`linux-x86_64` only):**
  `openvino-runtime-<ovver>-linux-x86_64.tar.gz` + `.sha256`, versioned by **OpenVINO** version
  (independent of `<etver>`). One top-level dir containing a flat `lib/` (six CPU-only libraries
  plus the unversioned `libopenvino_c.so` symlink we add), `licenses/` (Apache 2.0 + third-party
  notices + hwloc BSD-3-Clause), and `BUILDINFO`. Vendored from the Apache-2.0 PyPI wheel; every
  library carries `RPATH=$ORIGIN` so the directory self-resolves without `LD_LIBRARY_PATH`.
  Pinned as `ET_RUNTIME_OPENVINO_{VERSION,URL,SHA256}`. Consumers set `OPENVINO_LIB_PATH` to the
  absolute path of `lib/libopenvino_c.so`. See `docs/openvino-python-consumer.md` and
  `docs/openvino-jni-consumer.md`.
```

In `CLAUDE.md`, add this paragraph to the "Architecture" section, after the "Single-source-of-truth libraries" list:

```markdown
### OpenVINO (`linux-x86_64` only)

All three Linux x86-64 variants build the ExecuTorch OpenVINO delegate
(`EXECUTORCH_BUILD_OPENVINO=ON`, gated in `common_cmake_flags`). The backend resolves the
OpenVINO C API via `dlopen` at runtime, so the build needs **no** OpenVINO SDK — it only adds a
43 KB static archive. The OpenVINO runtime itself ships as a **separate** hash-pinned asset
(contract C10) assembled by `scripts/vendor-openvino.sh` from the Apache-2.0 PyPI wheel;
`scripts/lib/openvino.sh` is the SSOT for its version, members, and naming. Consumers must set
`OPENVINO_LIB_PATH` to the absolute path of `libopenvino_c.so` — see the two handover docs in
`docs/`.
```

- [ ] **Step 3: Verify the docs are internally consistent**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo `extras_members`).

Check the docs reference only real paths:

```bash
grep -o 'scripts/[a-z-]*\.sh\|scripts/lib/[a-z]*\.sh\|docs/openvino-[a-z-]*\.md' \
  docs/openvino-jni-consumer.md docs/openvino-python-consumer.md CLAUDE.md README.md \
  | cut -d: -f2 | sort -u | while read -r p; do
    [ -e "$p" ] && echo "ok: $p" || echo "MISSING: $p"
  done
```

Expected: every line starts with `ok:`.

- [ ] **Step 4: Commit**

```bash
git add docs/openvino-jni-consumer.md README.md CLAUDE.md
git commit -m "docs: OpenVINO JNI handover guide + document contract C10"
```

---

## Final verification

- [ ] **Full unit suite:** `bash test/run.sh` → `ALL UNIT TESTS PASS`
- [ ] **Flags:** `./build-runtime.sh --print-flags --variant logging` contains `-DEXECUTORCH_BUILD_OPENVINO=ON`; the same with `--platform windows-x86_64-static` does not.
- [ ] **Bundle end to end** (container): `./scripts/vendor-openvino.sh --out "$PWD/ovstage"` then `bash test/openvino_smoke.sh "$PWD/ovstage/openvino-runtime-2025.4.1-linux-x86_64"` → `GATE PASS`.
- [ ] **PIC/relocatability with the delegate linked** (container): `bash test/relocatability.sh "$PWD/out-logging"` → `GATE PASS`.
- [ ] **Scratch dirs removed:** `rm -rf ovstage ovbundle`; `git status` clean.
- [ ] **Open the PR** against `main` from `feature/openvino-linux-x86_64`.
