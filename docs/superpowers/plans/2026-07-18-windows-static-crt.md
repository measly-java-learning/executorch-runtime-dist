# Windows static-CRT (`/MT`) Artifact Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a second Windows artifact, `windows-x86_64-static`, built with the static CRT (`/MT`) alongside the existing dynamic-CRT (`/MD`) `windows-x86_64`, so Python and JNI consumers can each link a compatible runtime.

**Architecture:** The CRT rides the existing `platform` token as a suffix rather than becoming a new tuple dimension. One function (`et_configure_base`) maps platform → cmake configure base, and it already feeds both the build and the recorded `BUILDINFO` provenance — so adding the CRT flag there propagates everywhere for free. Naming, pin discovery, and pin generation need **no** changes.

**Tech Stack:** Bash (`set -euo pipefail`), CMake + Ninja + MSVC, GitHub Actions, `dumpbin` for CRT verification.

**Design spec:** `docs/superpowers/specs/2026-07-18-windows-static-crt-design.md`
**Spike evidence:** `spike/mt-crt/FINDINGS.md` (GO verdict, 18/18 libs clean)

## Global Constraints

- Shell scripts run under `set -euo pipefail`. `grep` exits 1 on no-match and aborts under `set -e` — guard with `|| true`, matching existing code.
- `scripts/lib/*.sh` are the single source of truth, sourced by both the build and packaging/CI. Change them there, never at a call site (contracts C1/C3/C5).
- The recipe is **idempotent**: re-runs must not fail on already-patched sources or existing build trees.
- Windows ships the **`logging` variant only**. Do not add `bare`/`devtools` Windows jobs.
- Do **not** enable `EXECUTORCH_BUILD_KERNELS_OPTIMIZED` or `KERNELS_QUANTIZED` on Windows — they pull torch `c10` headers that MSVC rejects. Existing test guards enforce this; keep them passing for both Windows platforms.
- Do **not** add `CMAKE_POLICY_DEFAULT_CMP0091` — cmake ≥3.15 defaults it `NEW` and cmake 4.3 warns it is unused.
- Exact CRT values: `/MD` → `MultiThreadedDLL`; `/MT` → `MultiThreaded`.
- Exact platform strings: `windows-x86_64` (dynamic), `windows-x86_64-static` (static).
- Unit tests are hermetic (no build, no container): `bash test/run.sh`.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scripts/lib/configure-base.sh` | Platform → cmake configure base. Gains the compiler pin and the per-platform CRT flag. **All product logic lives here.** | 1, 2 |
| `test/lib_configure_base.test.sh` | Unit-tests the above. | 1, 2 |
| `test/discover_pin_rows.test.sh` | Proves the multi-dash platform round-trips through pin discovery. | 2 |
| `scripts/check-windows-crt.sh` | **New.** `dumpbin /directives` scan asserting CRT consistency across an installed prefix. | 3 |
| `test/relocatability-windows.sh` | Existing Windows gate; becomes CRT-aware. | 4 |
| `.github/workflows/release.yml` | `build-windows` gains a platform axis; runs the new CRT scan. | 5 |
| `README.md` | Downstream guidance on which artifact to pick. | 6 |

**Not modified (verified by reading — do not "fix" these):** `scripts/lib/naming.sh`, `scripts/discover-pin-rows.sh`, `scripts/gen-pin.sh`, `scripts/package.sh`.

---

### Task 1: Pin the Windows compiler (issue #10)

Prerequisite bug fix, independent of the CRT work. Without the pin, cmake runs its own MSVC discovery; where `cmake` resolves to the VS-bundled copy (any stock VS workstation with no standalone cmake) it defaults to the `Hostx86\x86` toolchain and silently configures **32-bit**, despite an x64 dev shell, x64 `cl` on `PATH`, and x64 `LIB`. CI is correct only by accident of the runner shipping a standalone cmake that wins `PATH` precedence.

**Files:**
- Modify: `scripts/lib/configure-base.sh`
- Test: `test/lib_configure_base.test.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `et_configure_base <platform>` — unchanged signature, prints a cmake flag string to stdout, returns `2` on unknown platform. The `windows-x86_64` output now additionally contains `-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl`.

- [ ] **Step 1: Write the failing test**

Append to `test/lib_configure_base.test.sh`, immediately before the final `et_configure_base bogus-plat` line:

```bash
# Compiler pin (issue #10): without this, cmake's own MSVC discovery can select the Hostx86/x86
# toolchain and silently produce a 32-bit build on a workstation whose `cmake` is the VS-bundled one.
assert_contains "$win" "-DCMAKE_C_COMPILER=cl"   "windows base pins the C compiler"
assert_contains "$win" "-DCMAKE_CXX_COMPILER=cl" "windows base pins the CXX compiler"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_configure_base.test.sh`
Expected: FAIL, two lines reading `FAIL: windows base pins the C compiler` / `...CXX compiler`, and a non-zero exit.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib/configure-base.sh`, add the two flags to the start of the `windows-*` flag string. Replace the `windows-*)` branch body so the string begins:

```bash
    windows-*) printf -- '%s' \
'-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON' ;;
```

Also update the file's header comment. Append this sentence to the existing comment block:

```bash
# The Windows base pins CMAKE_C/CXX_COMPILER=cl because cmake's own MSVC discovery defaults to the
# Hostx86/x86 (32-bit) toolchain when `cmake` is the VS-bundled copy — a silent 32-bit build that no
# existing gate catches (issue #10).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/lib_configure_base.test.sh`
Expected: all `ok:` lines, exit 0.

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/configure-base.sh test/lib_configure_base.test.sh
git commit -m "$(cat <<'EOF'
fix: pin CMAKE_C/CXX_COMPILER=cl on Windows (#10)

Without the pin, cmake runs its own MSVC discovery. Where `cmake` resolves to the VS-bundled copy
(any stock VS workstation with no standalone cmake) that discovery defaults to the Hostx86/x86
toolchain and silently configures 32-bit, despite an x64 dev shell, an x64 cl on PATH, and x64 LIB.
The failure surfaces much later as unresolved __aulldiv/_mainCRTStartup inside flatcc_ep.

CI was correct only by accident: the GitHub runner ships a standalone cmake that wins PATH
precedence. Note the relocatability smoke would not have caught this — a consistently 32-bit build
links and passes find_package fine.

Closes #10

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add the `windows-x86_64-static` platform with its CRT flag

**Files:**
- Modify: `scripts/lib/configure-base.sh`
- Test: `test/lib_configure_base.test.sh`, `test/discover_pin_rows.test.sh`

**Interfaces:**
- Consumes: `et_configure_base <platform>` from Task 1.
- Produces: `et_configure_base windows-x86_64` contains `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`; `et_configure_base windows-x86_64-static` contains `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`. Both are otherwise flag-identical. `package.sh` picks this up automatically for `BUILDINFO` (contract C5) — no change needed there.

- [ ] **Step 1: Write the failing tests**

Replace the Windows block of `test/lib_configure_base.test.sh` (everything from `win="$(et_configure_base windows-x86_64)"` down to but **not** including the `et_configure_base bogus-plat` line) with:

```bash
# Both Windows platforms share one flag set and differ ONLY in the CRT.
win="$(et_configure_base windows-x86_64)"
winst="$(et_configure_base windows-x86_64-static)"

for base_desc in "dynamic:$win" "static:$winst"; do
  desc="${base_desc%%:*}"; base="${base_desc#*:}"
  assert_contains "$base" "-DEXECUTORCH_BUILD_XNNPACK=ON"                  "$desc windows base enables xnnpack"
  assert_contains "$base" "-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON"          "$desc windows base enables executor_runner"
  assert_contains "$base" "-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON" "$desc windows base enables named_data_map (EXTENSION_MODULE dep)"
  assert_contains "$base" "-DCMAKE_C_COMPILER=cl"                          "$desc windows base pins the C compiler"
  assert_contains "$base" "-DCMAKE_CXX_COMPILER=cl"                        "$desc windows base pins the CXX compiler"
  # Must NOT enable the torch-header-pulling kernels, and must NOT use a preset.
  case "$base" in *KERNELS_OPTIMIZED*|*KERNELS_QUANTIZED*) printf 'FAIL: %s windows base must not enable optimized/quantized kernels\n' "$desc" >&2; exit 1 ;; esac
  case "$base" in *--preset*) printf 'FAIL: %s windows base must not use a cmake preset\n' "$desc" >&2; exit 1 ;; esac
  # CMP0091 is NEW by default at our cmake floor; setting it produces an "unused variable" warning.
  case "$base" in *CMP0091*) printf 'FAIL: %s windows base must not set CMP0091\n' "$desc" >&2; exit 1 ;; esac
done

# The CRT is the ONLY difference between the two platforms.
assert_contains "$win"   "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" "windows-x86_64 uses the dynamic CRT (/MD)"
assert_contains "$winst" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"    "windows-x86_64-static uses the static CRT (/MT)"
# Guard against a substring false-positive: MultiThreadedDLL contains "MultiThreaded".
case "$winst" in *MultiThreadedDLL*) printf 'FAIL: static base must not carry the DLL runtime\n' >&2; exit 1 ;; esac
# Strip the differing CRT flag from each and assert the remainder is byte-identical, so the two
# platforms can never drift in any other flag.
assert_eq "${win/-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL/}" \
          "${winst/-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded/}" \
          "windows platforms differ ONLY in the CRT flag"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_configure_base.test.sh`
Expected: FAIL. `et_configure_base windows-x86_64-static` currently matches the `windows-*` glob and returns the same string as `windows-x86_64`, so the CRT assertions fail.

- [ ] **Step 3: Write minimal implementation**

Rewrite `scripts/lib/configure-base.sh` in full. The shared flag list is factored into one variable so the two Windows platforms cannot drift:

```bash
#!/usr/bin/env bash
# Platform -> ExecuTorch cmake CONFIGURE BASE (SSOT). Shared by build-runtime.sh (the build) and
# package.sh (recorded provenance) so the two can never disagree on how the artifact was configured.
# Linux uses the ET `linux` preset. Windows uses a flat flag list because the ET `windows` preset
# pins toolset ClangCL + the VS generator, incompatible with our Ninja/MSVC single-config build
# (spike finding 1). The Windows list is the windows-preset feature set MINUS
# KERNELS_OPTIMIZED/QUANTIZED — those pull torch c10 headers that break MSVC, and Linux ships neither
# (spike finding 3). `common_cmake_flags` + `variant_flags` still layer on top of this base.
#
# The Windows base pins CMAKE_C/CXX_COMPILER=cl because cmake's own MSVC discovery defaults to the
# Hostx86/x86 (32-bit) toolchain when `cmake` is the VS-bundled copy — a silent 32-bit build that no
# existing gate catches (issue #10).
#
# Windows ships TWO platforms differing only in the C runtime, because MSVC bakes the CRT into every
# object and all statically-linked objects in a downstream DLL must agree (mismatch => LNK4098/2005):
#   windows-x86_64         /MD  dynamic CRT — required for CPython extensions (CPython is /MD)
#   windows-x86_64-static  /MT  static CRT  — self-contained JNI DLLs, no VC++ redist needed
# Do NOT set CMAKE_POLICY_DEFAULT_CMP0091: it is NEW by default at our cmake floor and only produces
# an "unused variable" warning.
# Source me.

# Variant-independent Windows flags shared by BOTH windows platforms. Kept in one place so the
# dynamic and static bases can only ever differ in the CRT.
_ET_WINDOWS_COMMON='-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON'

et_configure_base() { # <platform>
  case "$1" in
    linux-*)               printf -- '--preset linux' ;;
    windows-x86_64-static) printf -- '%s -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'    "$_ET_WINDOWS_COMMON" ;;
    windows-x86_64)        printf -- '%s -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL' "$_ET_WINDOWS_COMMON" ;;
    *) echo "et_configure_base: unknown platform '$1'" >&2; return 2 ;;
  esac
}
```

**Ordering matters:** `windows-x86_64-static` must be matched *before* `windows-x86_64`. The previous `windows-*` glob is deliberately gone so an unrecognized Windows platform returns `2` instead of silently building with the wrong CRT.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/lib_configure_base.test.sh`
Expected: all `ok:` lines including `windows platforms differ ONLY in the CRT flag`, exit 0.

- [ ] **Step 5: Add the pin-discovery round-trip test**

In `test/discover_pin_rows.test.sh`, add a fixture after the existing `windows-x86_64` line (the `mk ...12345678` line):

```bash
mk 1111111111111111111111111111111111111111111111111111111122223333 executorch-runtime-1.3.1-logging-windows-x86_64-static.tar.gz.sha256
```

Then update the `expected` string to include the new row. Discovery sorts by platform then variant, and `windows-x86_64` sorts before `windows-x86_64-static`, so append it last:

```bash
expected="$(printf 'bare\tlinux-x86_64\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaacafef00d\ndevtools\tlinux-x86_64\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbdeadbeef\nlogging\tlinux-x86_64\tccccccccccccccccccccccccccccccccccccccccccccccccccccccccfeedface\nlogging\twindows-x86_64\tdddddddddddddddddddddddddddddddddddddddddddddddddddddddd12345678\nlogging\twindows-x86_64-static\t1111111111111111111111111111111111111111111111111111111122223333')"
```

Update the row-count assertion from `4` to `5`:

```bash
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "5" "foreign-etver file excluded from row count"
```

And add an explicit multi-dash assertion after the existing dash-split one:

```bash
# A platform with TWO dashes must still split correctly (variant is everything before the FIRST dash).
assert_contains "$out" "$(printf 'logging\twindows-x86_64-static\t1111111111111111111111111111111111111111111111111111111122223333')" "two-dash platform split correctly"
```

- [ ] **Step 6: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

This proves `discover-pin-rows.sh` and `gen-pin.sh` need no changes: discovery splits variant on the *first* dash, so the two-dash platform round-trips through `tarball_name` reconstruction unmodified.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/configure-base.sh test/lib_configure_base.test.sh test/discover_pin_rows.test.sh
git commit -m "$(cat <<'EOF'
feat: add windows-x86_64-static platform (static CRT /MT)

MSVC bakes the CRT into every object and all statically-linked objects in a downstream DLL must
agree, so one artifact cannot serve both consumers: CPython extensions must match CPython's /MD,
while a JNI DLL wants /MT to be self-contained (no VC++ redist on locked-down workstations).

Encodes the CRT as a platform suffix so it rides the existing platform token: naming (C1),
discover-pin-rows, gen-pin, and package.sh are all unchanged. Because package.sh derives
BUILDINFO's cmake_flags from et_configure_base, provenance records the CRT automatically (C5).

The shared Windows flag list is factored into one variable so the two platforms can only differ in
the CRT, and a test asserts exactly that.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: CRT-consistency scan script

The only check that catches a *future* ET or third-party dependency starting to hardcode `/MD`. The consumer link alone would not reveal a leak in a lib the probe does not pull in.

**Files:**
- Create: `scripts/check-windows-crt.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>` — exits 0 if every installed `.lib` requests the expected CRT, exits 1 naming each offender, exits 2 on bad usage. Consumed by Task 5.

- [ ] **Step 1: Write the script**

Create `scripts/check-windows-crt.sh`. This is promoted from the validated spike harness (`spike/mt-crt/check-crt.sh`):

```bash
#!/usr/bin/env bash
# Assert CRT consistency across an installed Windows prefix (release gate).
#
# MSVC records the CRT choice per-object as /DEFAULTLIB directives:
#   /MT  (static)  -> LIBCMT  / LIBCPMT
#   /MD  (dynamic) -> MSVCRT  / MSVCPRT
# Every statically-linked object in a downstream DLL must agree, so a single lib requesting the
# wrong CRT makes the artifact unlinkable for its intended consumer (LNK4098/LNK2005).
#
# This catches a dependency that hardcodes its own CRT — which the consumer-link gate would miss if
# the offending lib is not on the probe's link line.
#
# Run inside Git-Bash from an activated VS dev shell (needs dumpbin).
# Usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>
set -euo pipefail
PREFIX="${1:?usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>}"
CRT="${2:?usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>}"
command -v dumpbin >/dev/null 2>&1 || { echo "FAIL: dumpbin not on PATH — run inside an activated VS dev shell" >&2; exit 1; }
[ -d "$PREFIX/lib" ] || { echo "FAIL: no lib/ under $PREFIX" >&2; exit 1; }

case "$CRT" in
  MultiThreaded)    want="static (LIBCMT/LIBCPMT)";  bad_re='MSVCRT|MSVCPRT' ;;
  MultiThreadedDLL) want="dynamic (MSVCRT/MSVCPRT)"; bad_re='LIBCMT|LIBCPMT' ;;
  *) echo "FAIL: CRT must be MultiThreaded or MultiThreadedDLL (got '$CRT')" >&2; exit 2 ;;
esac

echo "== CRT directive scan: expecting $want across $PREFIX/lib =="
leaks=0; scanned=0
while IFS= read -r lib; do
  scanned=$((scanned+1))
  # `|| true`: dumpbin failing on one lib must not abort the scan under set -e.
  dir="$(dumpbin /nologo /directives "$lib" 2>/dev/null || true)"
  # `|| true`: grep exits 1 when the lib is clean, which is the expected case.
  hit="$(printf '%s' "$dir" | grep -Eio "$bad_re" | sort -u | paste -sd, - || true)"
  if [ -n "$hit" ]; then
    echo "  LEAK  $(basename "$lib")  -> requests $hit"
    leaks=$((leaks+1))
  fi
done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.lib')

[ "$scanned" -gt 0 ] || { echo "FAIL: no .lib files found under $PREFIX/lib — wrong prefix?" >&2; exit 1; }
echo "-- scanned $scanned static libs, $leaks with a wrong-CRT directive --"
if [ "$leaks" -ne 0 ]; then
  echo "CRT CHECK: FAIL — $leaks lib(s) did not honor CRT=$CRT. See names above." >&2
  exit 1
fi
echo "CRT CHECK: PASS — all $scanned libs request $want."
```

- [ ] **Step 2: Verify it is syntactically valid and rejects bad input**

Run: `bash -n scripts/check-windows-crt.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

Run: `bash scripts/check-windows-crt.sh /nonexistent BogusCRT; echo "exit=$?"`
Expected: `FAIL: no lib/ under /nonexistent` and `exit=1`.

> The scan itself cannot run on Linux (needs `dumpbin`); it is exercised for real by the Windows CI job in Task 5. This was validated on winbox during the spike: 18/18 libs clean.

- [ ] **Step 3: Make it executable and commit**

```bash
chmod +x scripts/check-windows-crt.sh
git add scripts/check-windows-crt.sh
git commit -m "$(cat <<'EOF'
feat: add Windows CRT-consistency scan

dumpbin /directives scan asserting every installed static lib requests the expected CRT. Promoted
from the validated spike harness (spike/mt-crt/check-crt.sh).

This is the only gate that catches a future ET or third-party dependency hardcoding its own CRT: a
leak in a lib the consumer probe does not link would otherwise ship silently.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Make the relocatability smoke CRT-aware

The gate currently builds `test/consumer` with cmake defaults (`/MD`). Run against a `/MT` artifact it fails with `LNK4098`, and worse, against a `/MD` artifact it would silently prove nothing about `/MT`. Since this gate is what certifies an artifact as consumable, it must test the *matching* CRT.

**Files:**
- Modify: `test/relocatability-windows.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `test/relocatability-windows.sh <extracted-prefix-dir | *.tar.gz> [platform]` — `platform` defaults to `windows-x86_64`; passing `windows-x86_64-static` builds the consumer probe with `/MT`. Consumed by Task 5.

- [ ] **Step 1: Add the platform argument and CRT derivation**

In `test/relocatability-windows.sh`, replace the `IN=` line:

```bash
IN="${1:?usage: relocatability-windows.sh <extracted-prefix-dir | *.tar.gz>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
```

with:

```bash
IN="${1:?usage: relocatability-windows.sh <extracted-prefix-dir | *.tar.gz> [platform]}"
PLATFORM="${2:-windows-x86_64}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# The consumer probe MUST be built with the same CRT as the artifact. MSVC bakes the CRT into every
# object and refuses to mix them (LNK4098/LNK2005), so a /MD probe against a /MT artifact fails —
# and a probe that silently used the wrong CRT would certify an artifact it never actually tested.
case "$PLATFORM" in
  windows-x86_64-static) CRT="MultiThreaded" ;;
  windows-x86_64)        CRT="MultiThreadedDLL" ;;
  *) echo "FAIL: unknown platform '$PLATFORM' (expected windows-x86_64 or windows-x86_64-static)" >&2; exit 2 ;;
esac
echo ">> platform under test: $PLATFORM (CRT=$CRT)"
```

- [ ] **Step 2: Pass the CRT to the consumer configure**

In the same file, in "Step 2: consume from a DIFFERENT directory", replace the `cmake -S ... -B ...` invocation with:

```bash
cmake -S "$(winpath "$HERE/consumer")" -B "$(winpath "$BUILD")" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MSVC_RUNTIME_LIBRARY="$CRT" \
  -DCMAKE_PREFIX_PATH="$(winpath "$RELO")"
```

- [ ] **Step 3: Update the closing success message**

Replace:

```bash
echo "GATE PASS: windows-x86_64 artifact is relocatable AND links under MSVC"
```

with:

```bash
echo "GATE PASS: $PLATFORM artifact is relocatable AND links under MSVC with CRT=$CRT"
```

- [ ] **Step 4: Verify syntax and argument validation**

Run: `bash -n test/relocatability-windows.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

Run: `bash test/relocatability-windows.sh /nonexistent-prefix bogus-platform; echo "exit=$?"`
Expected: `FAIL: unknown platform 'bogus-platform' ...` and `exit=2`.

> The full gate needs MSVC and runs in CI (Task 5).

- [ ] **Step 5: Commit**

```bash
git add test/relocatability-windows.sh
git commit -m "$(cat <<'EOF'
test: make Windows relocatability smoke CRT-aware

Takes an optional platform argument and builds the consumer probe with the matching
CMAKE_MSVC_RUNTIME_LIBRARY. A /MD probe cannot link a /MT artifact (LNK4098/LNK2005), and a probe
that silently used the wrong CRT would certify an artifact it never tested.

Unknown platforms are rejected rather than defaulted, so a typo in the CI matrix fails loudly.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire both Windows platforms into the release workflow

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `et_configure_base` (Tasks 1–2), `scripts/check-windows-crt.sh` (Task 3), `test/relocatability-windows.sh <tarball> <platform>` (Task 4).
- Produces: two uploaded artifacts, `dist-logging-windows-x86_64` and `dist-logging-windows-x86_64-static`. The existing `pin` job consumes them via filesystem discovery with no change.

- [ ] **Step 1: Add the platform axis to the matrix**

In `.github/workflows/release.yml`, in the `build-windows` job, replace:

```yaml
    strategy:
      fail-fast: false
      matrix:
        variant: [logging]
```

with:

```yaml
    strategy:
      fail-fast: false
      matrix:
        variant: [logging]
        # Two CRT flavors. MSVC bakes the CRT into every object, so a consumer must link the one
        # matching its own: /MD for CPython extensions, /MT for self-contained JNI DLLs.
        platform: [windows-x86_64, windows-x86_64-static]
```

- [ ] **Step 2: Parameterize every hardcoded `windows-x86_64`**

Four call sites in the `build-windows` job must become `${{ matrix.platform }}`.

In "Build runtime (MSVC)", replace `--platform windows-x86_64` so the final line reads:

```yaml
            --et-tag ${{ steps.ver.outputs.ettag }} --platform ${{ matrix.platform }}
```

In "Package", replace the `--platform` argument:

```yaml
          ./scripts/package.sh --prefix "$PWD/out" --etver "${{ steps.ver.outputs.etver }}" \
            --variant "${{ matrix.variant }}" --platform ${{ matrix.platform }} \
            --package-tag "${GITHUB_REF_NAME}" --outdir "$PWD/dist" \
            --toolchain "msvc-2022"
```

In the relocatability smoke step, pass the platform through to the gate and glob the right tarball:

```yaml
          & $bash -c 'set -euo pipefail; t="$(ls dist/*-${{ matrix.platform }}.tar.gz | head -n1)"; ./test/relocatability-windows.sh "$t" ${{ matrix.platform }}'
```

In the upload step, parameterize the artifact name. **This is load-bearing** — with the name left as `windows-x86_64` the two CRT builds would collide on upload and one would overwrite the other:

```yaml
      - uses: actions/upload-artifact@v7
        with:
          name: dist-${{ matrix.variant }}-${{ matrix.platform }}
          path: dist/*
```

> Note the glob `dist/*-${{ matrix.platform }}.tar.gz`: for `windows-x86_64` this could also match the `-static` tarball if both were present, but each matrix job builds into its own fresh `dist/`, so only one tarball exists per job.

- [ ] **Step 3: Add the CRT-consistency gate**

Insert a new step **after** the relocatability smoke and **before** "Attest build provenance", so a CRT-inconsistent artifact is never attested:

```yaml
      - name: CRT consistency scan
        # Proves every installed static lib requests the CRT this platform promises. Catches a
        # dependency that hardcodes its own CRT, which the consumer-link gate above would miss if the
        # offending lib is not on the probe's link line. Same VS-activation -> Git-Bash handoff as
        # the build step.
        shell: pwsh
        run: |
          $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
          $vsPath = & $vswhere -latest -products * -property installationPath
          if (-not $vsPath) { throw "vswhere found no Visual Studio installation" }
          & "$vsPath\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation
          $crt = if ("${{ matrix.platform }}" -eq "windows-x86_64-static") { "MultiThreaded" } else { "MultiThreadedDLL" }
          $bash = "${env:ProgramFiles}\Git\bin\bash.exe"
          & $bash -c "set -euo pipefail; ./scripts/check-windows-crt.sh `"$PWD/out`" $crt"
          if ($LASTEXITCODE -ne 0) { throw "CRT consistency scan failed (exit $LASTEXITCODE)" }
```

- [ ] **Step 4: Update the job's explanatory comment**

Replace the comment block above `build-windows:`:

```yaml
  #
  # Windows amd64 support is implemented via `build-windows` below (MSVC, logging variant
  # only, GitHub-hosted windows-2022 runner, no container). It builds TWO platforms that differ
  # only in the C runtime — windows-x86_64 (/MD, for CPython extensions) and
  # windows-x86_64-static (/MT, for self-contained JNI DLLs) — because MSVC bakes the CRT into
  # every object and a consumer must link the flavor matching its own. macOS remains future work
  # and would follow the same pattern: a new `build-macos` job, uploading via the same
  # `dist-variant-platform` naming, added to `pin`'s `needs`.
```

- [ ] **Step 5: Validate the workflow YAML**

Run: `python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/release.yml')); m=d['jobs']['build-windows']['strategy']['matrix']; print('variants:',m['variant']); print('platforms:',m['platform'])"`

Expected:
```
variants: ['logging']
platforms: ['windows-x86_64', 'windows-x86_64-static']
```

Run: `grep -c 'windows-x86_64' .github/workflows/release.yml`
Then confirm no *hardcoded* uses remain outside the matrix list and comments:

Run: `grep -n 'windows-x86_64' .github/workflows/release.yml`
Expected: occurrences only in the `platform:` matrix list and in comments — **no** `--platform windows-x86_64`, and **no** `name: dist-...-windows-x86_64`.

- [ ] **Step 6: Run the full unit suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
ci: build both Windows CRT flavors and gate on CRT consistency

Adds a platform axis to build-windows (windows-x86_64 /MD, windows-x86_64-static /MT), threading
the platform through build, package, and the now-CRT-aware relocatability smoke. The
upload-artifact name is parameterized — left hardcoded, the two CRT builds would collide and one
would silently overwrite the other.

Adds the CRT-consistency scan between the smoke and attestation, so an artifact whose libs disagree
about the CRT is never attested. The pin job needs no change: it discovers rows from the filesystem
and the two-dash platform already round-trips.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Document which artifact to consume

**Files:**
- Modify: `README.md`
- Modify: `docs/handover-to-engine.md`

**Interfaces:**
- Consumes: the platform names established in Task 2.
- Produces: no code interface.

> `docs/handover-to-engine.md` is the **engine/JNI** team's contract reference — precisely the
> audience for the `/MT` artifact — and its C4 platform enumeration is already stale (says
> `linux-x86_64` only, though `windows-x86_64` ships today). This is an enumeration update, **not** a
> Contract Delta: C4 already states "the `<platform>` token scales to future targets", so the
> contract shape is unchanged and C1/C6 keep working as written.

- [ ] **Step 1: Add a CRT selection section**

In `README.md`, immediately after the closing paragraph of "Consuming downstream" (the paragraph ending "the same guarantee `sha256sum -c` gives you locally."), add:

```markdown
### Choosing a Windows artifact: `/MD` vs `/MT`

Windows ships two artifacts that differ **only** in the C runtime they were compiled against. MSVC
bakes that choice into every object file, and every statically-linked object in your final DLL must
agree — so pick the one matching how *you* compile:

| Consumer | Platform | CRT | Why |
|---|---|---|---|
| CPython extension | `windows-x86_64` | `/MD` (dynamic) | **Required.** CPython is itself `/MD`. A `/MT` extension puts two CRTs and two heaps in one process, corrupting anything allocated on one side and freed on the other. Ship the VC++ runtime DLLs with your wheel (e.g. `delvewheel`) or depend on the redistributable. |
| Java / JNI | `windows-x86_64-static` | `/MT` (static) | Self-contained: the CRT is folded into your JNI DLL, so end users need no VC++ redistributable. Compile your JNI DLL `/MT` to match. |

Both are correct for JNI — `/MT` is preferred only because it removes the redistributable
dependency, which matters on locked-down workstations. JNI is safe with either because its ABI is
pure C and never passes CRT-owned resources across the boundary.

Mixing them is a **link-time** failure (`LNK4098`, `LNK2005`), not a silent runtime bug — you will
know immediately.

```cmake
# JNI consumer: select the static-CRT artifact
FetchContent_Declare(et_runtime
  URL       "${ET_RUNTIME_URL_logging_windows-x86_64-static}"
  URL_HASH  "SHA256=${ET_RUNTIME_SHA256_logging_windows-x86_64-static}"
)
# ...and compile your own JNI target to match:
set_property(TARGET my_jni_lib PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
```
```

- [ ] **Step 2: Verify the pin variable names match what gen-pin.sh emits**

`gen-pin.sh` emits `ET_RUNTIME_URL_<variant>_<platform>`. Confirm the README's names are exactly what a release would produce:

Run:
```bash
bash scripts/gen-pin.sh --version 1.3.1-1 --etver 1.3.1 --base-url https://example.invalid \
  --row logging windows-x86_64-static 1111111111111111111111111111111111111111111111111111111122223333 \
  | grep -E 'ET_RUNTIME_(URL|SHA256)_logging_windows-x86_64-static'
```

Expected:
```
set(ET_RUNTIME_URL_logging_windows-x86_64-static
set(ET_RUNTIME_SHA256_logging_windows-x86_64-static "1111111111111111111111111111111111111111111111111111111122223333")
```

- [ ] **Step 3: Update the engine handover contract reference**

In `docs/handover-to-engine.md`, replace the C4 line:

```markdown
- **C4 — Platform:** `linux-x86_64` (glibc ≥ 2.28 floor). The `<platform>` token scales to future targets.
```

with:

```markdown
- **C4 — Platform:** `linux-x86_64` (glibc ≥ 2.28 floor), `linux-aarch64`, `windows-x86_64` (MSVC,
  `/MD` dynamic CRT), `windows-x86_64-static` (MSVC, `/MT` static CRT). The `<platform>` token scales
  to future targets — this is an enumeration change, **not** a Contract Delta.
  **Engine note:** on Windows prefer **`windows-x86_64-static`**. Its `/MT` CRT is folded into your
  JNI DLL, so end users need no VC++ redistributable — compile the JNI target `/MT` to match
  (`set_property(TARGET <t> PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")`). The `/MD`
  `windows-x86_64` build exists for CPython extensions, which must match CPython's own CRT. Mixing
  the two is a link-time failure (`LNK4098`/`LNK2005`), never silent corruption.
```

Then, in the "Your punch-list" table, replace the C4 row:

```markdown
| C4 | `EtRuntimePin.cmake` platform key; engine platform detection (`linux-x86_64` only for now) | ok |
```

with:

```markdown
| C4 | `EtRuntimePin.cmake` platform key; engine platform detection. **Windows: select `windows-x86_64-static` and build the JNI target `/MT`** | **⚠ new Windows platforms available; engine detection must map Windows → the `-static` row** |
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/handover-to-engine.md
git commit -m "$(cat <<'EOF'
docs: explain the Windows /MD vs /MT artifact choice

Documents which Windows artifact each consumer needs and why: CPython extensions must match
CPython's /MD, while JNI consumers should prefer the static-CRT build to avoid requiring the VC++
redistributable. Notes that mixing is a loud link-time failure, not silent corruption.

Also refreshes C4 in the engine handover doc, whose platform enumeration still listed linux-x86_64
only, and flags in the punch-list that engine platform detection should map Windows to the -static
row. Enumeration change only — C4 already stated the platform token scales, so no Contract Delta.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Verification

After all tasks, before opening a PR:

- [ ] `bash test/run.sh` → `ALL UNIT TESTS PASS`
- [ ] `./build-runtime.sh --print-flags --variant logging` still works (Linux path untouched)
- [ ] `grep -n 'windows-x86_64' .github/workflows/release.yml` → matrix list and comments only
- [ ] The real gate is a tagged release: both Windows tarballs build, pass the relocatability smoke **and** the CRT scan, and appear as separate rows in `EtRuntimePin.cmake`.

## Out of scope

Do not implement these here — they are separate work:

- `bare`/`devtools` Windows variants.
- `extras/` on Windows.
- Optimized/quantized kernels and the clang-cl question (orthogonal to the CRT; see spec §10).
- An architecture assertion on the packaged artifact. Recommended follow-up (spec §4): no current gate catches a *consistently* 32-bit build, since such a build links and passes `find_package` fine. Task 1 prevents it at the source, but nothing detects it after the fact.
