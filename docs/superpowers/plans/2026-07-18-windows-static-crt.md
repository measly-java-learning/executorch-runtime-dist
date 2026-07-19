# Windows static-CRT (`/MT`) Artifact Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a second Windows artifact, `windows-x86_64-static`, built with the static CRT (`/MT`) alongside the existing dynamic-CRT (`/MD`) `windows-x86_64`, so Python and JNI consumers can each link a compatible runtime.

**Architecture:** The CRT rides the existing `platform` token as a suffix rather than becoming a new tuple dimension. `scripts/lib/` holds one mapping (`crt_for_platform`) and one flag composer (`effective_cmake_flags`); the build, the dry-run, the provenance record, the relocatability gate, and the CI CRT scan all consume those, so they cannot drift. Naming, pin discovery, and pin generation need **no** changes.

**Tech Stack:** Bash (`set -euo pipefail`), CMake + Ninja + MSVC, GitHub Actions, `dumpbin` for CRT verification.

**Design spec:** `docs/superpowers/specs/2026-07-18-windows-static-crt-design.md`
**Spike evidence:** summarised in the design spec §9 (spike kit removed after the work landed; recoverable from git history, e.g. `git show b4d2d16e0418:spike/mt-crt/FINDINGS.md`)

## Global Constraints

- Shell scripts run under `set -euo pipefail`. `grep` exits 1 on no-match and aborts under `set -e` — guard with `|| true`, matching existing code. **But never `|| true` a command whose failure is the thing you are testing for** (see Task 4).
- `scripts/lib/*.sh` are the single source of truth, sourced by both the build and the packaging/CI. Change them there, never at a call site (contracts C1/C3/C5).
- The recipe is **idempotent**: re-runs must not fail on already-patched sources or existing build trees.
- Windows ships the **`logging` variant only**. Do not add `bare`/`devtools` Windows jobs.
- Do **not** enable `EXECUTORCH_BUILD_KERNELS_OPTIMIZED` or `KERNELS_QUANTIZED` on Windows — they pull torch `c10` headers that MSVC rejects. Existing test guards enforce this; keep them passing for both Windows platforms.
- Do **not** add `CMAKE_POLICY_DEFAULT_CMP0091` — cmake ≥3.15 defaults it `NEW` and cmake 4.3 warns it is unused.
- Exact CRT values: `/MD` → `MultiThreadedDLL`; `/MT` → `MultiThreaded`.
- Exact platform strings: `windows-x86_64` (dynamic), `windows-x86_64-static` (static).
- **MSVC tools must be invoked with `-flag`, never `/flag`, from Git-Bash.** MSYS path conversion rewrites a leading `/` into a Windows path (`/nologo` → `C:\Program Files\Git\nologo`). This silently broke the spike's CRT scan; see Task 4.
- Unit tests are hermetic (no build, no container): `bash test/run.sh`.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scripts/lib/configure-base.sh` | Platform → cmake configure base, **and** `crt_for_platform` (the one platform→CRT mapping). | 1, 2 |
| `scripts/lib/cmakeflags.sh` | Common flags **and** `effective_cmake_flags` (composes + dedupes the full set). | 3 |
| `build-runtime.sh` | Consumes `effective_cmake_flags` for both the cmake invocation and `--print-flags`. | 3 |
| `scripts/package.sh` | Consumes `effective_cmake_flags` for `BUILDINFO` provenance. | 3 |
| `scripts/check-windows-crt.sh` | **New.** `dumpbin` scan asserting CRT consistency, positively. | 4 |
| `test/relocatability-windows.sh` | Existing Windows gate; becomes CRT-aware via `crt_for_platform`. | 5 |
| `test/consumer/probe.cpp` | Consumer probe. Must reference a real ET symbol or every gate using it is vacuous. | 5b |
| `.github/workflows/release.yml` | `build-windows` gains a platform axis; runs the CRT scan. | 6 |
| `README.md`, `docs/handover-to-engine.md`, `CLAUDE.md` | Consumer + contributor docs. | 7 |

**Not modified (verified by reading — do not "fix" these):** `scripts/lib/naming.sh`, `scripts/discover-pin-rows.sh`, `scripts/gen-pin.sh`.

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
Expected: FAIL, two lines reading `FAIL: windows base pins the C compiler` / `...CXX compiler`, non-zero exit.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib/configure-base.sh`, prepend the two flags to the `windows-*` flag string so it begins:

```bash
    windows-*) printf -- '%s' \
'-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON' ;;
```

Append to the file's header comment:

```bash
# The Windows base pins CMAKE_C/CXX_COMPILER=cl because cmake's own MSVC discovery defaults to the
# Hostx86/x86 (32-bit) toolchain when `cmake` is the VS-bundled copy — a silent 32-bit build that no
# existing gate catches (issue #10).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/lib_configure_base.test.sh` → all `ok:`, exit 0.
Run: `bash test/run.sh` → `ALL UNIT TESTS PASS`.

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

### Task 2: `crt_for_platform` + the `windows-x86_64-static` platform

The platform→CRT mapping is defined **once**, in the SSOT. Tasks 5 and 6 consume this function rather than re-implementing the mapping — an earlier draft of this plan duplicated it in a bash `case` *and* a PowerShell ternary, and the two disagreed on unknown platforms (the PowerShell `else` silently defaulted to `/MD`).

**Files:**
- Modify: `scripts/lib/configure-base.sh`
- Test: `test/lib_configure_base.test.sh`, `test/discover_pin_rows.test.sh`

**Interfaces:**
- Consumes: `et_configure_base` from Task 1.
- Produces:
  - `crt_for_platform <platform>` → prints `MultiThreaded` for `windows-x86_64-static`, `MultiThreadedDLL` for `windows-x86_64`; prints an error to stderr and returns `2` otherwise. **Consumed by Tasks 5 and 6.**
  - `et_configure_base windows-x86_64` contains `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`; `windows-x86_64-static` contains `...=MultiThreaded`. Both otherwise flag-identical.

- [ ] **Step 1: Write the failing tests**

Replace the Windows block of `test/lib_configure_base.test.sh` (from `win="$(et_configure_base windows-x86_64)"` down to but **not** including the `et_configure_base bogus-plat` line) with:

```bash
# --- crt_for_platform: the ONE platform -> CRT mapping. Tasks 5/6 consume this; nothing re-derives it.
assert_eq "$(crt_for_platform windows-x86_64)"        "MultiThreadedDLL" "windows-x86_64 -> dynamic CRT"
assert_eq "$(crt_for_platform windows-x86_64-static)" "MultiThreaded"    "windows-x86_64-static -> static CRT"
crt_for_platform linux-x86_64 >/dev/null 2>&1; assert_eq "$?" "2" "non-windows platform has no CRT -> 2"
crt_for_platform windows-arm64 >/dev/null 2>&1; assert_eq "$?" "2" "unknown windows platform -> 2 (never a silent default)"

# --- Both Windows platforms share one flag set and differ ONLY in the CRT.
win="$(et_configure_base windows-x86_64)"
winst="$(et_configure_base windows-x86_64-static)"

for base_desc in "dynamic:$win" "static:$winst"; do
  desc="${base_desc%%:*}"; base="${base_desc#*:}"
  assert_contains "$base" "-DEXECUTORCH_BUILD_XNNPACK=ON"                  "$desc windows base enables xnnpack"
  assert_contains "$base" "-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON"          "$desc windows base enables executor_runner"
  assert_contains "$base" "-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON" "$desc windows base enables named_data_map (EXTENSION_MODULE dep)"
  assert_contains "$base" "-DCMAKE_C_COMPILER=cl"                          "$desc windows base pins the C compiler"
  assert_contains "$base" "-DCMAKE_CXX_COMPILER=cl"                        "$desc windows base pins the CXX compiler"
  case "$base" in *KERNELS_OPTIMIZED*|*KERNELS_QUANTIZED*) printf 'FAIL: %s windows base must not enable optimized/quantized kernels\n' "$desc" >&2; exit 1 ;; esac
  case "$base" in *--preset*) printf 'FAIL: %s windows base must not use a cmake preset\n' "$desc" >&2; exit 1 ;; esac
  case "$base" in *CMP0091*) printf 'FAIL: %s windows base must not set CMP0091\n' "$desc" >&2; exit 1 ;; esac
done

assert_contains "$win"   "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" "windows-x86_64 uses the dynamic CRT (/MD)"
assert_contains "$winst" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"    "windows-x86_64-static uses the static CRT (/MT)"
# assert_contains is a substring test and "MultiThreaded" is a PREFIX of "MultiThreadedDLL", so the
# static assertion above would also pass on a /MD base. This guard is what makes it meaningful.
case "$winst" in *MultiThreadedDLL*) printf 'FAIL: static base must not carry the DLL runtime\n' >&2; exit 1 ;; esac

# Strip each platform's OWN CRT flag, then assert the remainder is byte-identical, so the two bases
# can never drift in any other flag.
# ORDER MATTERS — do NOT factor these into one shared pattern. "MultiThreaded" is a strict prefix of
# "MultiThreadedDLL", so stripping the SHORT pattern from $win would match inside the long flag and
# leave a stray "DLL" behind ("COMMON DLL" vs "COMMON "). Each variable must be stripped with its
# own exact, full flag string.
assert_eq "${win/-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL/}" \
          "${winst/-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded/}" \
          "windows platforms differ ONLY in the CRT flag"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_configure_base.test.sh`
Expected: FAIL — `crt_for_platform: command not found`, plus the CRT assertions failing because `windows-x86_64-static` currently matches the `windows-*` glob and returns the `/MD` string.

- [ ] **Step 3: Write minimal implementation**

Rewrite `scripts/lib/configure-base.sh` in full:

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

# Platform -> MSVC runtime library. THE single mapping: et_configure_base builds its flag from it,
# test/relocatability-windows.sh picks the consumer CRT from it, and release.yml passes it to the CRT
# scan. Never re-derive this mapping at a call site — an unknown platform must FAIL here rather than
# silently default to one CRT and have the gate validate the wrong thing.
crt_for_platform() { # <platform>
  case "$1" in
    windows-x86_64-static) printf 'MultiThreaded' ;;
    windows-x86_64)        printf 'MultiThreadedDLL' ;;
    *) echo "crt_for_platform: no CRT defined for platform '$1'" >&2; return 2 ;;
  esac
}

# Variant-independent Windows flags shared by BOTH windows platforms, so they can only ever differ
# in the CRT appended by et_configure_base.
_ET_WINDOWS_COMMON='-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON'

et_configure_base() { # <platform>
  case "$1" in
    linux-*) printf -- '--preset linux' ;;
    windows-*)
      # crt_for_platform is the gatekeeper: an unrecognized windows-* platform returns 2 here rather
      # than building with an arbitrary CRT.
      _crt="$(crt_for_platform "$1")" || return 2
      printf -- '%s -DCMAKE_MSVC_RUNTIME_LIBRARY=%s' "$_ET_WINDOWS_COMMON" "$_crt" ;;
    *) echo "et_configure_base: unknown platform '$1'" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/lib_configure_base.test.sh`
Expected: all `ok:` including `windows platforms differ ONLY in the CRT flag` and `unknown windows platform -> 2`, exit 0.

- [ ] **Step 5: Add the pin-discovery round-trip test**

In `test/discover_pin_rows.test.sh`, add a fixture after the existing `windows-x86_64` line:

```bash
mk 1111111111111111111111111111111111111111111111111111111122223333 executorch-runtime-1.3.1-logging-windows-x86_64-static.tar.gz.sha256
```

Update `expected` (discovery sorts platform then variant; `windows-x86_64` sorts before `windows-x86_64-static`):

```bash
expected="$(printf 'bare\tlinux-x86_64\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaacafef00d\ndevtools\tlinux-x86_64\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbdeadbeef\nlogging\tlinux-x86_64\tccccccccccccccccccccccccccccccccccccccccccccccccccccccccfeedface\nlogging\twindows-x86_64\tdddddddddddddddddddddddddddddddddddddddddddddddddddddddd12345678\nlogging\twindows-x86_64-static\t1111111111111111111111111111111111111111111111111111111122223333')"
```

Update the row count from `4` to `5`:

```bash
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "5" "foreign-etver file excluded from row count"
```

Add after the existing dash-split assertion:

```bash
# A platform with TWO dashes must still split correctly (variant is everything before the FIRST dash).
assert_contains "$out" "$(printf 'logging\twindows-x86_64-static\t1111111111111111111111111111111111111111111111111111111122223333')" "two-dash platform split correctly"
```

- [ ] **Step 6: Run the full suite**

Run: `bash test/run.sh` → `ALL UNIT TESTS PASS`.

This proves `discover-pin-rows.sh` and `gen-pin.sh` need no changes.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/configure-base.sh test/lib_configure_base.test.sh test/discover_pin_rows.test.sh
git commit -m "$(cat <<'EOF'
feat: add windows-x86_64-static platform (static CRT /MT)

MSVC bakes the CRT into every object and all statically-linked objects in a downstream DLL must
agree, so one artifact cannot serve both consumers: CPython extensions must match CPython's /MD,
while a JNI DLL wants /MT to be self-contained (no VC++ redist on locked-down workstations).

Encodes the CRT as a platform suffix so it rides the existing platform token: naming (C1),
discover-pin-rows, gen-pin, and package.sh are all unchanged.

Adds crt_for_platform as the ONE platform->CRT mapping, consumed by the configure base, the
relocatability gate, and the CI CRT scan. An unknown platform returns 2 rather than defaulting, so
a gate can never validate against the wrong CRT.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `effective_cmake_flags` — make `--print-flags` actually print the effective flags

`--print-flags` is documented as "print effective cmake flags for a variant without building" but prints **only** `$VARIANT_FLAGS` — one flag out of ~18. It ignores `--platform` entirely, so it would show **nothing** about `/MD` vs `/MT`, leaving no way to inspect this feature's headline deliverable short of a 15-minute build.

Fixing it by composing the same string in a third place would invite drift, so this task extracts one composer used by the build, the dry-run, and the provenance record. It also **dedupes**: the Windows base overlaps `common_cmake_flags` in 6 flags, which is harmless to cmake (identical values) but noisy in `--print-flags` output and `BUILDINFO`.

**Files:**
- Modify: `scripts/lib/cmakeflags.sh`, `build-runtime.sh`, `scripts/package.sh`
- Test: `test/build_cli.test.sh`, `test/buildinfo.test.sh` (verify only)

**Interfaces:**
- Consumes: `et_configure_base` (Tasks 1–2), `variant_flags`, `common_cmake_flags`.
- Produces: `effective_cmake_flags <platform> <variant>` → prints the full deduped flag string (configure base + variant flags + common flags, first occurrence wins, order preserved). Returns `2` if either lookup fails.

- [ ] **Step 1: Write the failing test**

Replace the two `--print-flags` assertions at the top of `test/build_cli.test.sh`:

```bash
assert_eq "$(bash "$BR" --print-flags --variant logging)" "-DEXECUTORCH_ENABLE_LOGGING=ON" "print-flags logging"
assert_eq "$(bash "$BR" --print-flags --variant bare)"    "-DEXECUTORCH_ENABLE_LOGGING=OFF" "print-flags bare"
```

with:

```bash
# --print-flags must print the EFFECTIVE set (configure base + variant + common), not just the
# variant flag, and must honor --platform — otherwise there is no way to inspect the CRT without a
# full build.
lin="$(bash "$BR" --print-flags --variant logging)"
assert_contains "$lin" "--preset linux"                  "print-flags: linux default includes the configure base"
assert_contains "$lin" "-DEXECUTORCH_ENABLE_LOGGING=ON"  "print-flags: includes the variant flag"
assert_contains "$lin" "-DEXECUTORCH_BUILD_XNNPACK=ON"   "print-flags: includes common flags"

bar="$(bash "$BR" --print-flags --variant bare)"
assert_contains "$bar" "-DEXECUTORCH_ENABLE_LOGGING=OFF" "print-flags bare: variant flag"

wmd="$(bash "$BR" --print-flags --variant logging --platform windows-x86_64)"
wmt="$(bash "$BR" --print-flags --variant logging --platform windows-x86_64-static)"
assert_contains "$wmd" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" "print-flags: /MD platform shows the dynamic CRT"
assert_contains "$wmt" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"    "print-flags: /MT platform shows the static CRT"
case "$wmt" in *MultiThreadedDLL*) printf 'FAIL: static print-flags must not carry the DLL runtime\n' >&2; exit 1 ;; esac

# Deduped: the windows base overlaps common_cmake_flags, and a repeated flag must appear ONCE.
assert_eq "$(printf '%s\n' $wmd | grep -c -- '-DCMAKE_BUILD_TYPE=Release')" "1" "print-flags: duplicate flags collapsed"
assert_eq "$(printf '%s\n' $wmd | grep -c -- '-DEXECUTORCH_BUILD_XNNPACK=ON')" "1" "print-flags: duplicate xnnpack collapsed"

# An unknown platform must fail, not print a default set.
bash "$BR" --print-flags --variant logging --platform windows-arm64 >/dev/null 2>&1; assert_eq "$?" "2" "print-flags: unknown platform exits 2"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/build_cli.test.sh`
Expected: FAIL on `print-flags: linux default includes the configure base` (output is only the variant flag) and on the CRT assertions.

- [ ] **Step 3: Add `effective_cmake_flags` to the SSOT**

Rewrite `scripts/lib/cmakeflags.sh`:

```bash
#!/usr/bin/env bash
# Common (variant-independent) cmake flags — SINGLE SOURCE OF TRUTH shared by the build
# (build-runtime.sh) and the recorded provenance (package.sh -> BUILDINFO cmake_flags, C5), so the
# two can never drift. Excludes only genuinely machine-specific flags (-DCMAKE_INSTALL_PREFIX), which
# the build sets separately and which are deliberately not recorded. Source me.
common_cmake_flags() {
  printf -- '-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON'
}

# Collapse repeated whitespace-separated tokens, keeping the FIRST occurrence and preserving order.
# Safe here because every flag is a self-contained `-DKEY=VALUE` token and the overlapping flags
# carry identical values. Two flags sharing a KEY but differing in VALUE are distinct tokens and are
# both retained (cmake's last-wins behaviour is unchanged).
_dedupe_flags() { # <flag string>
  local out="" f
  for f in $1; do
    case " $out " in *" $f "*) ;; *) out="${out:+$out }$f" ;; esac
  done
  printf '%s' "$out"
}

# The full, deduped flag set actually handed to cmake — and recorded as provenance, and printed by
# --print-flags. One composer, three consumers, so the build, the dry run, and BUILDINFO can never
# disagree (extends contract C5). Requires configure-base.sh + variants.sh to be sourced.
effective_cmake_flags() { # <platform> <variant>
  local base variant
  base="$(et_configure_base "$1")" || return 2
  variant="$(variant_flags "$2")" || return 2
  _dedupe_flags "$base $variant $(common_cmake_flags)"
}
```

- [ ] **Step 4: Consume it in `build-runtime.sh`**

`build-runtime.sh` sources `cmakeflags.sh` after `configure-base.sh` and `variants.sh` already; confirm that ordering, since `effective_cmake_flags` calls both.

Replace the `--print-flags` block (currently `printf '%s\n' "$VARIANT_FLAGS"`):

```bash
if [ "$PRINT_FLAGS" -eq 1 ]; then
  # The EFFECTIVE set, platform-aware — this is the only way to inspect the CRT without a build.
  effective_cmake_flags "$PLATFORM" "$VARIANT" || exit 2
  printf '\n'
  exit 0
fi
```

Replace the cmake configure invocation so the build uses the same composed string:

```bash
echo ">> configuring ($VARIANT, platform=$PLATFORM)"
# shellcheck disable=SC2086  # deliberate word-splitting of the flag strings
cmake -B "$ET_BUILD" -S "$ET_SRC" -G Ninja \
  $(effective_cmake_flags "$PLATFORM" "$VARIANT") \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  $PYTHON_PIN
```

The now-unused `CONFIGURE_BASE` and `VARIANT_FLAGS` assignments near line 69-70 must stay — `variant_flags` still validates the variant early (returning 2 on unknown, which `set -e` turns into an abort), and `et_configure_base` still validates the platform.

- [ ] **Step 5: Consume it in `scripts/package.sh`**

Replace the `CMAKE_FLAGS=` line (currently composing the three calls inline):

```bash
CMAKE_FLAGS="$(effective_cmake_flags "$PLATFORM" "$VARIANT")"
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash test/build_cli.test.sh` → all `ok:`, exit 0.
Run: `bash test/buildinfo.test.sh` → still passes (it passes `CMAKE_FLAGS` in directly, so it is unaffected).
Run: `bash test/run.sh` → `ALL UNIT TESTS PASS`.

Sanity-check the deduping by eye:

Run: `./build-runtime.sh --print-flags --variant logging --platform windows-x86_64-static | tr ' ' '\n' | sort | uniq -d`
Expected: **no output** (no duplicated flags).

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/cmakeflags.sh build-runtime.sh scripts/package.sh test/build_cli.test.sh
git commit -m "$(cat <<'EOF'
fix: --print-flags prints the effective, deduped, platform-aware flag set

--print-flags claimed to print "effective cmake flags" but printed only the variant flag and
ignored --platform, so it could not show the CRT at all — the one thing you would want to inspect
without paying for a full build.

Adds effective_cmake_flags(platform, variant) to the SSOT and routes the build, the dry run, and
BUILDINFO provenance through it, so all three agree by construction (extends C5). Also dedupes: the
windows base overlaps common_cmake_flags in six flags, harmless to cmake but noise in provenance.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: CRT-consistency scan (positive assertion)

> **Why this task is written the way it is.** The spike's version of this scan reported
> `PASS — all 18 libs request static (LIBCMT/LIBCPMT)` while `dumpbin` was in fact **failing on every
> single lib** (`rc=157`). Two compounding defects produced a green light from zero evidence:
>
> 1. **MSYS path conversion.** In Git-Bash, an argument starting with `/` is rewritten to a Windows
>    path: `/nologo` became `C:\Program Files\Git\nologo`, so dumpbin got a garbage filename instead
>    of its flags. **Use `-nologo -directives`** — MSVC accepts `-` for options.
> 2. **A negative-only check.** It asserted the *absence* of the wrong marker. Absence is satisfied
>    by silence, and a broken tool produces silence. `|| true` and `2>/dev/null` hid the failure.
>
> The scan below asserts the **presence** of the expected marker and treats a dumpbin failure as a
> hard error. Verified against the real `/MT` prefix: 18/18 libs carry `LIBCMT`/`libcpmt`, 0 wrong,
> 0 without a marker, 0 dumpbin failures — so a blanket positive assertion is safe.

**Files:**
- Create: `scripts/check-windows-crt.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>` — exits 0 only if every installed `.lib` positively carries the expected CRT marker; exits 1 naming offenders; exits 2 on bad usage. Consumed by Task 6.

- [ ] **Step 1: Write the script**

Create `scripts/check-windows-crt.sh`:

```bash
#!/usr/bin/env bash
# Assert CRT consistency across an installed Windows prefix (release gate).
#
# MSVC records the CRT choice per-object as /DEFAULTLIB directives:
#   /MT  (static)  -> LIBCMT  / LIBCPMT
#   /MD  (dynamic) -> MSVCRT  / MSVCPRT
# Every statically-linked object in a downstream DLL must agree, so one lib requesting the wrong CRT
# makes the artifact unlinkable for its intended consumer (LNK4098/LNK2005).
#
# This check is deliberately POSITIVE: each lib must CARRY the expected marker. An earlier
# negative-only version ("no wrong marker found") reported PASS on 18 libs while dumpbin was failing
# on every one of them — absence of evidence read as evidence of absence.
#
# NOTE: flags are passed as -nologo -directives, NOT /nologo /directives. Under Git-Bash, MSYS path
# conversion rewrites a leading '/' into a Windows path (/nologo -> C:\Program Files\Git\nologo), so
# the slash form silently feeds dumpbin a garbage filename. MSVC accepts '-' for all options.
#
# Run inside Git-Bash from an activated VS dev shell (needs dumpbin).
# Usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>
set -euo pipefail
PREFIX="${1:?usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>}"
CRT="${2:?usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>}"
command -v dumpbin >/dev/null 2>&1 || { echo "FAIL: dumpbin not on PATH — run inside an activated VS dev shell" >&2; exit 1; }
[ -d "$PREFIX/lib" ] || { echo "FAIL: no lib/ under $PREFIX" >&2; exit 1; }

# Markers are mixed-case in real dumpbin output (LIBCMT but libcpmt), so all matching is -i.
# A C-only lib (cpuinfo, pthreadpool, xnnpack-microkernels-prod) carries LIBCMT with no LIBCPMT,
# so the expected pattern is an OR, never a requirement for both.
case "$CRT" in
  MultiThreaded)    want_re='LIBCMT|LIBCPMT';  bad_re='MSVCRT|MSVCPRT'; want="static (LIBCMT/LIBCPMT)" ;;
  MultiThreadedDLL) want_re='MSVCRT|MSVCPRT';  bad_re='LIBCMT|LIBCPMT'; want="dynamic (MSVCRT/MSVCPRT)" ;;
  *) echo "FAIL: CRT must be MultiThreaded or MultiThreadedDLL (got '$CRT')" >&2; exit 2 ;;
esac

echo "== CRT directive scan: every lib must carry $want =="
ok=0; leaks=0; indeterminate=0; failed=0; total=0
while IFS= read -r lib; do
  total=$((total+1))
  name="$(basename "$lib")"
  # Capture stdout+stderr AND the exit status. Do NOT `|| true` here: a dumpbin failure is exactly
  # the condition this gate exists to notice, and swallowing it is what made the old scan useless.
  set +e
  out="$(dumpbin -nologo -directives "$lib" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  ERROR $name -> dumpbin exited $rc:"
    printf '%s\n' "$out" | sed 's/^/          /' | head -5
    failed=$((failed+1)); continue
  fi
  if printf '%s' "$out" | grep -Eqi "$bad_re"; then
    echo "  LEAK  $name -> requests $(printf '%s' "$out" | grep -Eoi "$bad_re" | sort -u | paste -sd, -)"
    leaks=$((leaks+1))
  elif printf '%s' "$out" | grep -Eqi "$want_re"; then
    ok=$((ok+1))
  else
    echo "  INDET $name -> no CRT directive at all (expected $want)"
    indeterminate=$((indeterminate+1))
  fi
done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.lib')

echo "-- scanned $total: ok=$ok leaks=$leaks indeterminate=$indeterminate dumpbin_failures=$failed --"
[ "$total" -gt 0 ]        || { echo "FAIL: no .lib files under $PREFIX/lib — wrong prefix?" >&2; exit 1; }
[ "$failed" -eq 0 ]       || { echo "FAIL: dumpbin failed on $failed lib(s); the scan proved nothing." >&2; exit 1; }
[ "$leaks" -eq 0 ]        || { echo "FAIL: $leaks lib(s) request the wrong CRT for $CRT." >&2; exit 1; }
[ "$indeterminate" -eq 0 ] || { echo "FAIL: $indeterminate lib(s) carry no CRT directive; cannot certify." >&2; exit 1; }
[ "$ok" -eq "$total" ]    || { echo "FAIL: only $ok/$total libs positively confirmed." >&2; exit 1; }
echo "CRT CHECK: PASS — all $total libs positively carry $want."
```

- [ ] **Step 2: Verify syntax and the usage guards**

Run: `bash -n scripts/check-windows-crt.sh && echo SYNTAX_OK` → `SYNTAX_OK`

Run: `bash scripts/check-windows-crt.sh /nonexistent MultiThreaded; echo "exit=$?"`
Expected: `FAIL: no lib/ under /nonexistent`, `exit=1`.

> The scan itself needs `dumpbin` and runs for real in CI (Task 6). Its behaviour was verified
> against the winbox `/MT` prefix: `TOTAL=18 HAS_STATIC=18 WRONG_CRT=0 NO_MARKER=0 DUMPBIN_FAIL=0`.

- [ ] **Step 3: Make it executable and commit**

```bash
chmod +x scripts/check-windows-crt.sh
git add scripts/check-windows-crt.sh
git commit -m "$(cat <<'EOF'
feat: add Windows CRT-consistency scan (positive assertion)

Asserts every installed static lib CARRIES the expected CRT marker, rather than merely lacking the
wrong one, and treats a dumpbin failure as a hard error.

Both properties are load-bearing. The spike's negative-only version reported "PASS - all 18 libs
request static" while dumpbin was failing on every lib (rc=157): MSYS path conversion had rewritten
/nologo into C:\Program Files\Git\nologo, and `|| true` plus 2>/dev/null hid it. Absence of the bad
marker was satisfied by silence. Flags are therefore passed in -dash form.

Verified against the real /MT prefix: 18/18 libs carry LIBCMT/libcpmt, 0 wrong, 0 indeterminate.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Make the relocatability smoke CRT-aware

The gate builds `test/consumer` with cmake defaults (`/MD`). Against a `/MT` artifact that fails `LNK4098`; worse, a probe that silently used the wrong CRT would certify an artifact it never tested.

**Files:**
- Modify: `test/relocatability-windows.sh`

**Interfaces:**
- Consumes: `crt_for_platform` (Task 2).
- Produces: `test/relocatability-windows.sh <extracted-prefix-dir | *.tar.gz> [platform]` — `platform` defaults to `windows-x86_64`. Consumed by Task 6.

- [ ] **Step 1: Add the platform argument, sourcing the CRT from the SSOT**

Replace:

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
# The mapping lives in scripts/lib/configure-base.sh; do NOT re-derive it here.
# shellcheck source=../scripts/lib/configure-base.sh
. "$HERE/../scripts/lib/configure-base.sh"
CRT="$(crt_for_platform "$PLATFORM")" || {
  echo "FAIL: no CRT for platform '$PLATFORM'" >&2; exit 2; }
echo ">> platform under test: $PLATFORM (CRT=$CRT)"
```

- [ ] **Step 2: Pass the CRT to the consumer configure**

Replace the consumer `cmake -S ... -B ...` invocation with:

```bash
cmake -S "$(winpath "$HERE/consumer")" -B "$(winpath "$BUILD")" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MSVC_RUNTIME_LIBRARY="$CRT" \
  -DCMAKE_PREFIX_PATH="$(winpath "$RELO")"
```

- [ ] **Step 3: Update the closing success message**

Replace `echo "GATE PASS: windows-x86_64 artifact is relocatable AND links under MSVC"` with:

```bash
echo "GATE PASS: $PLATFORM artifact is relocatable AND links under MSVC with CRT=$CRT"
```

- [ ] **Step 4: Verify syntax and argument validation**

Run: `bash -n test/relocatability-windows.sh && echo SYNTAX_OK` → `SYNTAX_OK`

Run: `bash test/relocatability-windows.sh /nonexistent-prefix bogus-platform; echo "exit=$?"`
Expected: `crt_for_platform: no CRT defined for platform 'bogus-platform'`, `FAIL: no CRT for platform 'bogus-platform'`, `exit=2`.

- [ ] **Step 5: Commit**

```bash
git add test/relocatability-windows.sh
git commit -m "$(cat <<'EOF'
test: make Windows relocatability smoke CRT-aware

Takes an optional platform argument and builds the consumer probe with the matching
CMAKE_MSVC_RUNTIME_LIBRARY. A /MD probe cannot link a /MT artifact (LNK4098/LNK2005), and a probe
that silently used the wrong CRT would certify an artifact it never tested.

The platform->CRT mapping is sourced from scripts/lib/configure-base.sh rather than re-derived, so
this gate and the build can never disagree. Unknown platforms are rejected, not defaulted.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5b: Make the consumer probe actually link ExecuTorch code

> **Why this task exists.** `test/consumer/probe.cpp` is `extern "C" int et_pic_probe() { return 0; }`
> — it references **no** ExecuTorch symbol. Static-archive linking is lazy: objects are pulled only
> to resolve undefined symbols, so **no ET object ever enters the link**. Both gates that depend on
> this probe are therefore vacuous, measured not inferred:
>
> - **Windows CRT gate (Task 5) is unfalsifiable.** The same `/MT` prefix PASSED as
>   `windows-x86_64-static` (probe `/MT`, 177,664 B, no CRT DLL imports) *and* as `windows-x86_64`
>   (probe `/MD`, 47,104 B, importing `VCRUNTIME140.dll`). It passes whichever CRT it selects.
> - **Linux PIC gate has the same hole**, and that gate is the reason this repo exists. Proven
>   locally: a shared library linking a deliberately `-fno-PIC` archive links `rc=0` when the probe
>   references nothing; add one symbol reference and `ld` correctly fails with
>   `relocation R_X86_64_PC32 ... recompile with -fPIC`.
>
> Both are **pre-existing** defects, not introduced by this plan. One probe change fixes both gates.

**Files:**
- Modify: `test/consumer/probe.cpp`

**Interfaces:**
- Consumes: the installed prefix's `executorch` imported target and public headers.
- Produces: no code interface. Both `test/relocatability.sh` (Linux) and
  `test/relocatability-windows.sh` (Windows) gain real linking power; neither script changes.

- [ ] **Step 1: Verify the symbol is present in a built prefix**

The probe must call something torch-free, public, and defined in the **core** archive so the
reference forces object extraction. `executorch::runtime::runtime_init()` qualifies: declared in
`include/executorch/runtime/platform/runtime.h`, defined in `libexecutorch_core.a(runtime.cpp.o)`.

Run against any built prefix (e.g. `out-bare`):

```bash
nm -C --defined-only -A <prefix>/lib/libexecutorch_core.a | grep runtime_init
```
Expected: a line naming `runtime.cpp.o` and `T executorch::runtime::runtime_init()`.

- [ ] **Step 2: Change the probe**

Replace the entire contents of `test/consumer/probe.cpp` with:

```cpp
// Consumer probe for the relocatability / PIC / CRT gates.
//
// This TU MUST reference a real ExecuTorch symbol. Static-archive linking is lazy — the linker
// extracts an archive member only to resolve an undefined symbol — so a self-contained probe
// (`return 0;`) pulls in NO ET object and makes every gate built on it vacuous:
//   * the Linux PIC gate links a non-PIC archive without complaint, and
//   * the Windows CRT gate passes a /MT artifact against a /MD consumer.
// Both were verified to pass on artifacts they should have rejected before this reference existed.
//
// runtime_init() is chosen because it is public, torch-free, and defined in the core archive
// (libexecutorch_core.a / executorch_core.lib), so referencing it forces object extraction. It is
// never called at runtime — the LINK is the test.
#include <executorch/runtime/platform/runtime.h>

extern "C" int et_pic_probe() {
  ::executorch::runtime::runtime_init();
  return 0;
}
```

- [ ] **Step 3: Verify the object is now pulled in (Linux)**

Against a built Linux prefix:

```bash
g++ -fPIC -shared test/consumer/probe.cpp -o /tmp/p.so \
  -I<prefix>/include <prefix>/lib/libexecutorch_core.a
nm -C --defined-only /tmp/p.so | grep runtime_init
```
Expected: the link succeeds AND `executorch::runtime::runtime_init()` appears in the output — proof
an archive member was extracted. Before this change the same grep returned nothing.

- [ ] **Step 4: Verify the gates still pass on a real artifact**

The probe now compiles ET headers, so the gate needs the prefix's include dir to resolve —
`find_package(executorch)` supplies it via the imported target's usage requirements. Confirm the
consumer still configures and links:

```bash
bash test/relocatability.sh <built-linux-prefix>
```
Expected: `GATE PASS`. If it fails on a missing header, the imported target is not propagating its
include directories and `test/consumer/CMakeLists.txt` needs
`target_include_directories`/`target_link_libraries` review — report that rather than working around
it by hardcoding a path.

- [ ] **Step 5: Commit**

```bash
git add test/consumer/probe.cpp
git commit -m "$(cat <<'EOF'
fix: make the consumer probe actually link ExecuTorch code

The probe was `extern "C" int et_pic_probe() { return 0; }` and referenced no ET symbol. Static
archive linking is lazy, so no ET object was ever pulled into the link and every gate built on this
probe was vacuous.

Measured, not inferred: the same /MT Windows prefix passed as windows-x86_64-static (probe /MT, no
CRT DLL imports) AND as windows-x86_64 (probe /MD, importing VCRUNTIME140), so the CRT gate would
pass whichever CRT it chose. On Linux, a shared library linking a deliberately -fno-PIC archive
links cleanly when the probe references nothing; adding one symbol reference makes ld correctly
refuse with "recompile with -fPIC". That PIC gate is the reason this repo exists.

Referencing runtime_init() forces extraction of runtime.cpp.o from the core archive, so both the
PIC gate and the CRT gate now exercise real ET objects.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Wire both Windows platforms into the release workflow

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `crt_for_platform` (Task 2), `scripts/check-windows-crt.sh` (Task 4), `test/relocatability-windows.sh <tarball> <platform>` (Task 5).
- Produces: two uploaded artifacts, `dist-logging-windows-x86_64` and `dist-logging-windows-x86_64-static`. The existing `pin` job consumes them via filesystem discovery with no change.

- [ ] **Step 1: Add the platform axis**

Replace:

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

In "Build runtime (MSVC)":

```yaml
            --et-tag ${{ steps.ver.outputs.ettag }} --platform ${{ matrix.platform }}
```

In "Package":

```yaml
          ./scripts/package.sh --prefix "$PWD/out" --etver "${{ steps.ver.outputs.etver }}" \
            --variant "${{ matrix.variant }}" --platform ${{ matrix.platform }} \
            --package-tag "${GITHUB_REF_NAME}" --outdir "$PWD/dist" \
            --toolchain "msvc-2022"
```

In the relocatability smoke step:

```yaml
          & $bash -c 'set -euo pipefail; t="$(ls dist/*-${{ matrix.platform }}.tar.gz | head -n1)"; ./test/relocatability-windows.sh "$t" ${{ matrix.platform }}'
```

In the upload step — **load-bearing**: left hardcoded, the two CRT builds collide on upload and one silently overwrites the other:

```yaml
      - uses: actions/upload-artifact@v7
        with:
          name: dist-${{ matrix.variant }}-${{ matrix.platform }}
          path: dist/*
```

> On the glob `dist/*-${{ matrix.platform }}.tar.gz`: for `windows-x86_64` this pattern would also
> match a `-static` tarball, since `windows-x86_64` is a prefix of `windows-x86_64-static`. It is
> safe only because each matrix job builds into its own fresh `dist/` containing exactly one
> tarball. Do not reuse this glob anywhere a job could see both.

- [ ] **Step 3: Add the CRT-consistency gate**

Insert **after** the relocatability smoke and **before** "Attest build provenance", so a
CRT-inconsistent artifact is never attested. The CRT comes from `crt_for_platform`, not a
PowerShell ternary — an earlier draft used `if (...-eq "windows-x86_64-static") {...} else {...}`,
whose `else` would silently map an unknown platform to `/MD` and scan against the wrong CRT:

```yaml
      - name: CRT consistency scan
        # Proves every installed static lib positively carries the CRT this platform promises.
        # Catches a dependency that hardcodes its own CRT, which the consumer-link gate above would
        # miss if the offending lib is not on the probe's link line. Same VS-activation -> Git-Bash
        # handoff as the build step.
        shell: pwsh
        run: |
          $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
          $vsPath = & $vswhere -latest -products * -property installationPath
          if (-not $vsPath) { throw "vswhere found no Visual Studio installation" }
          & "$vsPath\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation
          $bash = "${env:ProgramFiles}\Git\bin\bash.exe"
          & $bash -c 'set -euo pipefail; . scripts/lib/configure-base.sh; crt="$(crt_for_platform ${{ matrix.platform }})"; ./scripts/check-windows-crt.sh "$PWD/out" "$crt"'
          if ($LASTEXITCODE -ne 0) { throw "CRT consistency scan failed (exit $LASTEXITCODE)" }
```

- [ ] **Step 4: Update the job comment**

```yaml
  #
  # Windows amd64 support is implemented via `build-windows` below (MSVC, logging variant
  # only, GitHub-hosted windows-2022 runner, no container). It builds TWO platforms that differ
  # only in the C runtime — windows-x86_64 (/MD, for CPython extensions) and
  # windows-x86_64-static (/MT, for self-contained JNI DLLs) — because MSVC bakes the CRT into
  # every object and a consumer must link the flavor matching its own. NOTE: these platforms are
  # NOT in env.PLATFORMS; that list drives the linux container matrix only. macOS remains future
  # work and would follow this job's pattern, uploading via the same `dist-variant-platform`
  # naming and added to `pin`'s `needs`.
```

- [ ] **Step 5: Validate the workflow mechanically**

The matrix parses:

Run: `python3 -c "import yaml; m=yaml.safe_load(open('.github/workflows/release.yml'))['jobs']['build-windows']['strategy']['matrix']; print('variants:',m['variant']); print('platforms:',m['platform'])"`

Expected:
```
variants: ['logging']
platforms: ['windows-x86_64', 'windows-x86_64-static']
```

**Negative check — no literal platform in any executable position.** A bare `grep windows-x86_64` is useless here because `windows-x86_64-static` contains it as a substring, so it always matches the matrix line and comments. Grep for the specific bad forms instead:

Run: `grep -nE -- '--platform +windows-x86_64|dist/\*-windows-x86_64\.tar\.gz|name: dist-.*-windows-x86_64' .github/workflows/release.yml`
Expected: **no output** (exit 1). Any match is a call site that was not parameterized.

**Positive check — the parameterized forms are present.** A negative check alone passes trivially if a step is deleted:

Run:
```bash
for pat in -- '--platform ${{ matrix.platform }}' \
              'dist/\*-\${\{ matrix.platform \}\}\.tar\.gz' \
              'name: dist-\${\{ matrix.variant \}\}-\${\{ matrix.platform \}\}'; do
  grep -qF -- "$(printf '%s' "$pat" | sed 's/\\//g')" .github/workflows/release.yml \
    && echo "ok: $pat" || echo "MISSING: $pat"
done
```
Expected: three `ok:` lines, no `MISSING:`.

- [ ] **Step 6: Run the full unit suite**

Run: `bash test/run.sh` → `ALL UNIT TESTS PASS`.

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
about the CRT is never attested. The scan's CRT comes from crt_for_platform rather than an inline
PowerShell ternary, whose else-branch would have mapped an unknown platform to /MD and validated
against the wrong runtime.

The pin job needs no change: it discovers rows from the filesystem and the two-dash platform
already round-trips.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`, `docs/handover-to-engine.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: platform names from Task 2, `--print-flags` behaviour from Task 3.
- Produces: no code interface.

- [ ] **Step 1: README — add a CRT selection section**

In `README.md`, after the closing paragraph of "Consuming downstream" (ending "the same guarantee `sha256sum -c` gives you locally."), add:

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

Mixing them is **not reliably caught at link time.** Measured: a `/MD` consumer linked against a
`/MT` artifact with no `LNK2005` and not even an `LNK4098` warning. `LNK4098` is only a warning even
when it fires. The failure that matters is at **runtime** — two CRTs mean two heaps, and memory
allocated on one side and freed on the other corrupts. Match the artifact to your build deliberately;
do not rely on the linker to tell you.

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

- [ ] **Step 2: Verify the pin variable names are real**

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

- [ ] **Step 3: Engine handover contract reference**

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
  `windows-x86_64` build exists for CPython extensions, which must match CPython's own CRT. Do NOT
  rely on the linker to catch a mismatch — measured, a `/MD` consumer linked a `/MT` artifact with no
  error and no LNK4098 warning. The failure is at runtime: two CRTs, two heaps, corruption when an
  allocation crosses the boundary.
```

And in the punch-list table, replace the C4 row:

```markdown
| C4 | `EtRuntimePin.cmake` platform key; engine platform detection (`linux-x86_64` only for now) | ok |
```

with:

```markdown
| C4 | `EtRuntimePin.cmake` platform key; engine platform detection. **Windows: select `windows-x86_64-static` and build the JNI target `/MT`** | **⚠ new Windows platforms available; engine detection must map Windows → the `-static` row** |
```

- [ ] **Step 4: CLAUDE.md — five corrections**

(a) Test count. Replace `# Run the full shell unit-test suite (12 *.test.sh files: naming, variants, packaging,` with:

```
# Run the full shell unit-test suite (16 *.test.sh files: naming, variants, packaging,
```

(b) `--print-flags` example. Replace:

```
# Print effective cmake flags for a variant without building (dry run)
./build-runtime.sh --print-flags --variant devtools
```

with:

```
# Print the full effective cmake flags (configure base + variant + common, deduped) without
# building. Platform-aware: this is how you inspect the Windows CRT without a 15-minute build.
./build-runtime.sh --print-flags --variant devtools
./build-runtime.sh --print-flags --variant logging --platform windows-x86_64-static
```

(c) SSOT list — `configure-base.sh` is missing entirely, and it now holds this feature's product
logic. Replace the three-bullet list with:

```
- `configure-base.sh` — platform → cmake configure base (`--preset linux` vs the flat Windows flag
  list), **and** `crt_for_platform`, the one platform→CRT mapping consumed by the build, the
  relocatability gate, and the CI CRT scan.
- `variants.sh` — variant → cmake flag string (contract C3).
- `cmakeflags.sh` — common variant-independent cmake flags, **and** `effective_cmake_flags`, which
  composes + dedupes the full set. The build, `--print-flags`, and `BUILDINFO` provenance (C5) all
  go through it, so they cannot diverge.
- `naming.sh` — asset/tarball/sha/fixtures naming (contract C1).
```

(d) Variant/platform framing. Replace `Every release builds three variants for each platform:` with:

```
Every release builds three variants **on Linux**; Windows ships `logging` only:
```

(e) CI matrix description. Replace:

```
  Matrix of {variant} × {platform}; platforms are a single JSON source-of-truth in the
  workflow `env.PLATFORMS`. Jobs: `setup` → `build` (per variant/platform, attests each
  tarball) → `pin` (generates `EtRuntimePin.cmake`) → `release`.
```

with:

```
  Matrix of {variant} × {platform}; the **Linux** platforms are a single JSON source-of-truth in the
  workflow `env.PLATFORMS`. Windows is a **separate `build-windows` job, not in `env.PLATFORMS`**
  (it needs MSVC on a non-container runner); it has its own {variant} × {platform} matrix over
  `windows-x86_64` (/MD) and `windows-x86_64-static` (/MT). Jobs: `setup` → `build` +
  `build-windows` (attest each tarball) → `pin` (generates `EtRuntimePin.cmake`) → `release`.
```

- [ ] **Step 5: Verify the doc claims are true**

Run: `ls test/*.test.sh | wc -l` → `16` (matches the CLAUDE.md figure).
Run: `./build-runtime.sh --print-flags --variant logging --platform windows-x86_64-static | grep -o 'MultiThreaded[A-Za-z]*'` → `MultiThreaded`.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/handover-to-engine.md CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: Windows /MD vs /MT selection, engine handover, and CLAUDE.md refresh

Documents which Windows artifact each consumer needs and why: CPython extensions must match
CPython's /MD, while JNI consumers should prefer the static-CRT build to avoid requiring the VC++
redistributable. Mixing is a loud link-time failure, not silent corruption.

Refreshes C4 in the engine handover doc (platform enumeration still listed linux-x86_64 only) and
flags that engine platform detection should map Windows to the -static row. Enumeration change
only, so no Contract Delta.

Corrects five stale CLAUDE.md claims, four pre-existing: the test-file count (12 -> 16), the
--print-flags description and example, the missing configure-base.sh/effective_cmake_flags entries
in the SSOT list, "three variants for each platform" (Windows is logging-only), and the CI matrix
description (build-windows is a separate job outside env.PLATFORMS).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Verification

After all tasks, before opening a PR:

- [ ] `bash test/run.sh` → `ALL UNIT TESTS PASS`
- [ ] `./build-runtime.sh --print-flags --variant logging` → includes `--preset linux`, the variant flag, and common flags
- [ ] `./build-runtime.sh --print-flags --variant logging --platform windows-x86_64-static | tr ' ' '\n' | sort | uniq -d` → **no output** (deduped)
- [ ] `grep -nE -- '--platform +windows-x86_64|dist/\*-windows-x86_64\.tar\.gz|name: dist-.*-windows-x86_64' .github/workflows/release.yml` → **no output**
- [ ] The real gate is a tagged release: both Windows tarballs build, pass the relocatability smoke **and** the CRT scan, and appear as separate rows in `EtRuntimePin.cmake`.

## Out of scope

- `bare`/`devtools` Windows variants.
- `extras/` on Windows.
- Optimized/quantized kernels and the clang-cl question (orthogonal to the CRT; see spec §10).
- An architecture assertion on the packaged artifact. Recommended follow-up (spec §4): no current gate catches a *consistently* 32-bit build, since such a build links and passes `find_package` fine. Task 1 prevents it at the source, but nothing detects it after the fact.
