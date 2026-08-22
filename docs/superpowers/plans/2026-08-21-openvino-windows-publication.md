# OpenVINO Windows Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the `win_amd64` OpenVINO bundle as a release asset and pin it, so a Windows consumer gets a working delegate + runtime pairing from `EtRuntimePin.cmake` — closing the standing risk that Windows tarballs advertise `openvino_version` with no bundle to pair them with.

**Architecture:** Six moves. Two isolated cleanups first, then the design decision the rest depends on (one shared Windows bundle serving both CRT platforms), then the pin schema change that decision forces, then release wiring, then the runtime gate for the static platform, then docs. The pin change is consumer-visible and is the reason this is a plan rather than a patch.

**Tech Stack:** Bash (`set -euo pipefail`), CMake, GitHub Actions, OpenVINO 2025.4.1.

**Spec:** https://github.com/measly-java-learning/executorch-runtime-dist/issues/37, step 6 of its suggested order, plus the five review findings recorded against PR #44 and reproduced under "Prerequisite findings" below.

**Predecessors:**
- `docs/superpowers/plans/2026-08-21-openvino-windows-compile-coverage.md` (PR #43) — vendored the backend patch, enabled the delegate on both Windows platforms.
- `docs/superpowers/plans/2026-08-21-openvino-windows-bundle-and-gate.md` (PR #44) — produced the `win_amd64` bundle and proved the delegate runs against it on Windows.

## Global Constraints

- `OV_VERSION` is **2025.4.1** for both platforms; same `OV_WHEEL_PYTAG` (`cp312`), so no version skew.
- **`EtRuntimePin.cmake` is a published downstream contract** (contract C6/C10). It is consumed by `djl-executorch-engine`; the current variable names are documented in `README.md:68`, `docs/handover-to-engine.md:91`, `docs/openvino-python-consumer.md:21-22` and `docs/openvino-jni-consumer.md:45-54`. Any change here must keep existing consumers building until they migrate.
- Shell runs under `set -euo pipefail`; `grep` exits 1 on no-match, so guard with `|| true`.
- `bash test/run.sh` must be green from a clean checkout at the end of every task.
- Work lands on a branch (`feature/*`) through a PR. The PR touches `scripts/lib/openvino.sh` and `test/openvino/**`, so `classify-gate.sh` routes it to `full`.

## Prerequisite findings

These came out of the pre-merge review of PR #44 and are folded in as tasks rather than filed separately, because four of the five directly shape the publication work.

| # | Finding | Task |
|---|---|---|
| 1 | `gen-pin.sh` emits **singular** `ET_RUNTIME_OPENVINO_{PLATFORM,URL,SHA256}` — one bundle only, and the names are a published contract | Task 3 |
| 2 | `windows-x86_64` and `windows-x86_64-static` yield two differently-named bundles with **identical member and licence lists** (differing only in BUILDINFO's `platform=`) | Task 2 |
| 3 | `windows-x86_64-static` ships a delegate **no runtime gate has executed** | Task 5 |
| 4 | The bundle stem `openvino-runtime-2025.4.1-windows-x86_64` is **hardcoded twice** in `extras-gate.yml` (631, 637), duplicating `ov_asset_stem` + `OV_VERSION`, while the Linux steps in the same file use the SSOT | Task 1 |
| 5 | `test/openvino/CMakeLists.txt`'s kernel-library fallback is **silent** — a Linux build that stopped producing `optimized_native_cpu_ops_lib` would downgrade to `portable_ops_lib` and still pass | Task 1 |

## Decision Record

**One Windows bundle, shared by both CRT platforms.** The bundle is the OpenVINO runtime, not our artifact: the wheel's DLLs are `/MD` regardless of how a consumer links, and no CRT object crosses the boundary (verified — a `/MT` consumer against these `/MD` DLLs links and runs). Publishing two ~56 MB assets that differ only in a BUILDINFO line is waste with a maintenance cost. A new `ov_bundle_platform` maps a *target* platform to the platform whose bundle serves it.

**Per-platform pin variables plus a selector, mirroring the tarball rows.** `gen-pin.sh` already solves exactly this shape for tarballs: flat `ET_RUNTIME_URL_<variant>_<platform>` vars plus a fixed `et_runtime_dist_url()` the consumer calls instead of string-building a variable name. The OpenVINO rows get the same treatment. **One deliberate difference:** `et_runtime_dist_url` FATAL_ERRORs on a missing combination, because every variant/platform pair must exist. A missing OpenVINO bundle is *legitimate* (`linux-aarch64` has none), so `et_runtime_openvino_url()` must return empty rather than abort, and consumers test the result.

**Legacy singular variables stay for one release cycle.** `docs/openvino-jni-consumer.md` currently instructs consumers to write `if(DEFINED ET_RUNTIME_OPENVINO_URL AND ET_RUNTIME_ROW STREQUAL ET_RUNTIME_OPENVINO_PLATFORM)`. Emitting only the new names would break that silently at the next release. The legacy trio continues to be emitted, pointing at `linux-x86_64`, marked deprecated in the generated file's header comment. **File an issue to remove them once `djl-executorch-engine` has migrated** — do not leave the removal untracked.

**Out of scope:** the upstream ExecuTorch PR (deferred by decision in the predecessor plan — the working implementation is the argument for it), and any new platform beyond the three now enabled.

---

## File Structure

**Created:**
- `test/fixtures/pin/openvino_selector_probe.cmake` — drives `et_runtime_openvino_url()` through real cmake, as `selector_probe.cmake` already does for the tarball selector.

**Modified:**
- `scripts/lib/openvino.sh` — `ov_bundle_platform`; `ov_bundle_platforms` (the distinct set to build).
- `scripts/gen-pin.sh` — repeatable `--openvino-row`, per-platform vars, the new selector, legacy aliases.
- `scripts/vendor-openvino.sh` — nothing, if Task 2 is done in `openvino.sh`. Verify.
- `.github/workflows/release.yml` — the `openvino` job builds every bundle platform; the `pin` job passes a row per bundle.
- `.github/workflows/extras-gate.yml` — remove the hardcoded stems; matrix the Windows runtime gate over both tarballs.
- `test/openvino/CMakeLists.txt` — make the kernel fallback visible.
- `test/pin.test.sh`, `test/lib_openvino.test.sh`, `test/lib/extras_gate_ov_windows.py` — cover the above.
- `README.md`, `docs/handover-to-engine.md`, `docs/openvino-jni-consumer.md`, `docs/openvino-python-consumer.md` — the new consumer pattern.

---

## Task 1: Prerequisite cleanups (findings 4 and 5)

Isolated from everything else; done first so later diffs are not mixed with them.

**Files:**
- Modify: `.github/workflows/extras-gate.yml` (the two hardcoded stems), `test/openvino/CMakeLists.txt`
- Modify: `test/lib/extras_gate_ov_windows.py`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other code calls.

- [ ] **Step 1: Create the branch**

```bash
git fetch origin && git checkout -b feature/openvino-windows-publish origin/main
```

- [ ] **Step 2: Write the failing guard for the hardcoded stem**

Add to `test/lib/extras_gate_ov_windows.py`, inside `main()` before the `for f in fails:` loop:

```python
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
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bash test/extras_gate_ov_windows.test.sh
```

Expected: `FAIL: extras-gate.yml spells an OpenVINO asset stem literally...`, exit 1.

- [ ] **Step 4: Derive the stem instead of spelling it**

In `.github/workflows/extras-gate.yml`, add a step to `full-gates-windows` immediately after the vendoring step:

```yaml
      - name: Resolve the bundle stem from the SSOT
        # ov_asset_stem is the naming SSOT; spelling the result into the pwsh steps below would be
        # a second copy that goes stale the day OV_VERSION moves. Bash step, exported once.
        shell: bash
        run: |
          set -euo pipefail
          . ./scripts/lib/openvino.sh
          echo "OV_BUNDLE_STEM=$(ov_asset_stem windows-x86_64)" >> "$GITHUB_ENV"
```

Then replace both `$stem = "openvino-runtime-2025.4.1-windows-x86_64"` lines with:

```powershell
          $stem = $env:OV_BUNDLE_STEM
          if (-not $stem) { throw "OV_BUNDLE_STEM not set -- the resolve step must run first" }
```

- [ ] **Step 5: Make the kernel fallback visible**

In `test/openvino/CMakeLists.txt`, replace the `if(TARGET ...)` block with:

```cmake
# Windows builds do not produce optimized_native_cpu_ops_lib, so fall back to the portable kernels
# there. STATUS, not silence: the fallback also fires if a LINUX build ever stops producing the
# optimized lib, and this gate would then quietly exercise a different kernel set and still pass.
if(TARGET optimized_native_cpu_ops_lib)
  set(OV_RUNNER_KERNELS optimized_native_cpu_ops_lib)
else()
  set(OV_RUNNER_KERNELS portable_ops_lib)
endif()
message(STATUS "ov_runner kernels: ${OV_RUNNER_KERNELS}")
```

- [ ] **Step 6: Run the tests and commit**

```bash
bash test/extras_gate_ov_windows.test.sh && bash test/run.sh
git add .github/workflows/extras-gate.yml test/openvino/CMakeLists.txt \
  test/lib/extras_gate_ov_windows.py
git commit -m "fix(gate): derive the bundle stem, surface the kernel fallback

The Windows gate steps spelled openvino-runtime-<ver>-windows-x86_64 literally,
duplicating ov_asset_stem and OV_VERSION while the Linux steps in the same file
call the SSOT. Guarded by the structural test now.

ov_runner's kernel-library fallback was silent; it also fires if a Linux build
stops producing optimized_native_cpu_ops_lib, which would downgrade the gate to
portable kernels and still pass."
```

---

## Task 2: One Windows bundle for both CRT platforms (finding 2)

**Files:**
- Modify: `scripts/lib/openvino.sh`, `test/lib_openvino.test.sh`

**Interfaces:**
- Produces:
  - `ov_bundle_platform <platform>` → the platform whose bundle serves `<platform>`. Identity for `linux-x86_64` and `windows-x86_64`; `windows-x86_64-static` → `windows-x86_64`. Exit 2 for a platform with no bundle.
  - `ov_bundle_platforms` → the distinct set of platforms a release must actually build bundles for, one per line.
  - `ov_alias_platforms` → the platforms served by *another* platform's bundle, one per line. Task 3 emits an alias pin row for each.
- Tasks 3, 4 and 5 consume these.

- [ ] **Step 1: Write the failing tests**

Append to `test/lib_openvino.test.sh`:

```bash
# --- which bundle serves which platform ---------------------------------------------------
# Both Windows CRT platforms are served by ONE bundle: the wheel's DLLs are /MD regardless of how
# a consumer links, and no CRT object crosses the boundary (every OpenVINO allocation is released
# through an OpenVINO-side free function). Publishing two assets that differ only in a BUILDINFO
# line would be pure duplication.
assert_eq "$(ov_bundle_platform linux-x86_64)"          "linux-x86_64"   "linux serves itself"
assert_eq "$(ov_bundle_platform windows-x86_64)"        "windows-x86_64" "windows /MD serves itself"
assert_eq "$(ov_bundle_platform windows-x86_64-static)" "windows-x86_64" "windows /MT reuses the /MD bundle"

# A platform with no bundle must FAIL rather than silently resolve to some other platform's --
# that would publish a pin row claiming a bundle exists for linux-aarch64.
ov_bundle_platform linux-aarch64 >/dev/null 2>&1; assert_eq "$?" "2" "aarch64 has no bundle"
ov_bundle_platform ""            >/dev/null 2>&1; assert_eq "$?" "2" "empty platform rejected"

# The set a release actually builds. Distinct, so the release matrix cannot be handed the same
# bundle twice.
assert_eq "$(ov_bundle_platforms | sort | tr '\n' ' ')" "linux-x86_64 windows-x86_64 " \
  "exactly two bundles are built per release"
assert_eq "$(ov_bundle_platforms | sort -u | wc -l)" "$(ov_bundle_platforms | wc -l)" \
  "ov_bundle_platforms has no duplicates"

# The aliases are the platforms that do NOT get their own asset. Bundles + aliases must together
# cover every OpenVINO-enabled platform, or a release enables a delegate for a platform whose
# runtime is neither published nor aliased -- exactly the gap this plan closes.
assert_eq "$(ov_alias_platforms)" "windows-x86_64-static" "the static CRT platform is an alias"
for _p in linux-x86_64 windows-x86_64 windows-x86_64-static; do
  case "$(ov_bundle_platforms; ov_alias_platforms)" in
    *"$_p"*) printf 'ok: %s is published or aliased\n' "$_p" ;;
    *) printf 'FAIL: %s is enabled but neither built nor aliased\n' "$_p" >&2
       ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  esac
done
# An alias must never also be built, or the release would publish the duplicate this avoids.
while read -r _a; do
  case "$(ov_bundle_platforms)" in
    *"$_a"*) printf 'FAIL: %s is both aliased and built\n' "$_a" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
    *) printf 'ok: %s is aliased, not built\n' "$_a" ;;
  esac
done <<EOF
$(ov_alias_platforms)
EOF

# Every OpenVINO-enabled platform must map to a buildable bundle, or a release would enable the
# delegate for a platform whose runtime is never published -- the exact gap this plan closes.
for _p in linux-x86_64 windows-x86_64 windows-x86_64-static; do
  _b="$(ov_bundle_platform "$_p")" || { printf 'FAIL: no bundle for %s\n' "$_p" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); continue; }
  case "$(ov_bundle_platforms)" in
    *"$_b"*) printf 'ok: %s -> %s is built\n' "$_p" "$_b" ;;
    *) printf 'FAIL: %s maps to %s, which ov_bundle_platforms does not build\n' "$_p" "$_b" >&2
       ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  esac
done
```

- [ ] **Step 2: Run to verify they fail**

```bash
bash test/lib_openvino.test.sh
```

Expected: `ov_bundle_platform: command not found`.

- [ ] **Step 3: Implement**

Add to `scripts/lib/openvino.sh`, immediately after `ov_enabled_for_platform`:

```bash
# Platform -> the platform whose BUNDLE serves it. Usually identity, but both Windows CRT
# platforms share one bundle: the wheel's DLLs are /MD regardless of how a consumer links, and no
# CRT object crosses the boundary, so a second asset differing only in BUILDINFO would be waste.
# Exit 2 rather than defaulting: an OpenVINO-enabled platform with no bundle must fail here, not
# publish a pin row pointing at another platform's runtime.
ov_bundle_platform() { # <platform>
  case "${1:-}" in
    linux-x86_64)                          printf 'linux-x86_64' ;;
    windows-x86_64|windows-x86_64-static)  printf 'windows-x86_64' ;;
    *) echo "ov_bundle_platform: no OpenVINO bundle serves platform '${1:-}'" >&2; return 2 ;;
  esac
}

# The distinct bundles a release builds. Derived from nothing -- it is the authoritative list, and
# ov_bundle_platform's targets must all appear here (asserted in test/lib_openvino.test.sh).
ov_bundle_platforms() {
  cat <<'EOF'
linux-x86_64
windows-x86_64
EOF
}

# Platforms served by ANOTHER platform's bundle. gen-pin.sh emits an alias row for each so a
# consumer building that row resolves a runtime without knowing about the sharing. Kept distinct
# from ov_bundle_platforms: their union must cover every OpenVINO-enabled platform, and the two
# lists must not overlap (both asserted in test/lib_openvino.test.sh).
ov_alias_platforms() {
  cat <<'EOF'
windows-x86_64-static
EOF
}
```

- [ ] **Step 4: Verify and commit**

```bash
bash test/lib_openvino.test.sh && bash test/run.sh
git add scripts/lib/openvino.sh test/lib_openvino.test.sh
git commit -m "feat(openvino): map both windows CRT platforms to one bundle

ov_bundle_platform answers 'which bundle serves this platform', and
ov_bundle_platforms is the distinct set a release builds. windows-x86_64-static
reuses the windows-x86_64 bundle: the wheel's DLLs are /MD regardless of how a
consumer links, so a second ~56MB asset differing only in a BUILDINFO line
would be duplication."
```

---

## Task 3: Per-platform pin rows and a selector (finding 1)

**Files:**
- Modify: `scripts/gen-pin.sh`, `test/pin.test.sh`
- Create: `test/fixtures/pin/openvino_selector_probe.cmake`

**Interfaces:**
- Consumes: Task 2's `ov_bundle_platform`.
- Produces:
  - `gen-pin.sh --openvino-row <platform> <sha>` — repeatable; replaces `--openvino-sha`/`--openvino-platform`.
  - In the generated pin: `ET_RUNTIME_OPENVINO_URL_<platform>`, `ET_RUNTIME_OPENVINO_SHA256_<platform>`, and `et_runtime_openvino_url(platform out_url out_sha)` which sets both outputs to `""` when no bundle serves that platform.
  - Legacy `ET_RUNTIME_OPENVINO_{PLATFORM,URL,SHA256}` still emitted for `linux-x86_64`.
- Task 4 calls the new flag.

- [ ] **Step 1: Write the failing tests**

In `test/pin.test.sh`, replace the OpenVINO assertions (currently around lines 44-61) with:

```bash
# Per-platform rows, mirroring the tarball rows' shape.
pin_ov="$("$here/../scripts/gen-pin.sh" --version 1.2.3-1 --etver 1.2.3 --base-url "$base" \
  --row logging linux-x86_64 "$sha1" \
  --openvino-row linux-x86_64 "$ovsha" --openvino-row windows-x86_64 "$ovsha2")"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_VERSION \"$OV_VERSION\")" "pin records openvino version"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256_linux-x86_64 \"$ovsha\")"   "linux row"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256_windows-x86_64 \"$ovsha2\")" "windows row"
assert_contains "$pin_ov" 'function(et_runtime_openvino_url platform out_url out_sha)' "selector defined"

# The legacy trio must survive: docs/openvino-jni-consumer.md instructs consumers to test
# `ET_RUNTIME_ROW STREQUAL ET_RUNTIME_OPENVINO_PLATFORM`, and dropping it would break every
# existing consumer at the next release with no CI signal anywhere.
assert_contains "$pin_ov" 'set(ET_RUNTIME_OPENVINO_PLATFORM "linux-x86_64")' "legacy platform var kept"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256 \"$ovsha\")" "legacy sha var kept"
assert_contains "$pin_ov" "DEPRECATED" "legacy vars are marked deprecated"

# A release with no bundle at all still yields a valid pin.
pin_no="$("$here/../scripts/gen-pin.sh" --version 1.2.3-1 --etver 1.2.3 --base-url "$base" \
  --row logging linux-x86_64 "$sha1")"
if printf '%s\n' "$pin_no" | grep -q '^set(ET_RUNTIME_OPENVINO_'; then
  printf 'FAIL: pin without an openvino row must emit no ET_RUNTIME_OPENVINO_* vars\n' >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: openvino-free pin is clean\n'
fi

# Run the selector through real cmake, the way selector_probe.cmake proves the tarball selector.
# A generated function that merely LOOKS right is not the property we need.
printf '%s\n' "$pin_ov" > "$tmp/pin_ov.cmake"
for p in linux-x86_64 windows-x86_64; do
  out="$(cmake -DPIN="$tmp/pin_ov.cmake" -DP="$p" -P "$here/fixtures/pin/openvino_selector_probe.cmake" 2>&1)" \
    || { printf 'FAIL: openvino selector aborted for %s\n%s\n' "$p" "$out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); continue; }
  assert_contains "$out" "$(ov_tarball_name "$p")" "selector resolves the $p bundle"
done
# Absence must be reported as empty, NOT as a fatal error: linux-aarch64 legitimately has no
# bundle, and a consumer building that row must be able to ask and get "no".
out="$(cmake -DPIN="$tmp/pin_ov.cmake" -DP=linux-aarch64 -P "$here/fixtures/pin/openvino_selector_probe.cmake" 2>&1)" \
  || { printf 'FAIL: selector must not abort for a platform with no bundle\n%s\n' "$out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$out" "URL=" "selector returns an empty url for aarch64"
```

Declare `ovsha2` near the existing `ovsha` (any distinct 64-hex value, e.g. `$(printf 'b%.0s' $(seq 64))`).

- [ ] **Step 2: Write the selector probe**

Create `test/fixtures/pin/openvino_selector_probe.cmake`:

```cmake
# Drives a generated EtRuntimePin.cmake's OpenVINO selector through real cmake, so the function is
# proven to RUN. Sibling of selector_probe.cmake; the difference is that absence is legal here --
# a platform with no bundle must yield empty strings rather than a fatal error.
#   cmake -DPIN=<pin> -DP=<platform> -P openvino_selector_probe.cmake
cmake_minimum_required(VERSION 3.19)

include("${PIN}")
et_runtime_openvino_url("${P}" url sha)

# When a row exists the selector must agree with the flat vars it reads from; a divergence would
# hand consumers a URL and a hash describing different tarballs, which FetchContent reports as a
# hash mismatch far from the cause.
if(DEFINED ET_RUNTIME_OPENVINO_URL_${P})
  if(NOT url STREQUAL "${ET_RUNTIME_OPENVINO_URL_${P}}")
    message(FATAL_ERROR "openvino selector url disagrees with flat var for ${P}")
  endif()
  if(NOT sha STREQUAL "${ET_RUNTIME_OPENVINO_SHA256_${P}}")
    message(FATAL_ERROR "openvino selector sha disagrees with flat var for ${P}")
  endif()
elseif(NOT url STREQUAL "")
  message(FATAL_ERROR "openvino selector invented a url for ${P}, which has no row")
endif()

message("URL=${url}")
message("SHA=${sha}")
```

- [ ] **Step 3: Run to verify they fail**

```bash
bash test/pin.test.sh
```

Expected: failures on `--openvino-row` being an unknown arg.

- [ ] **Step 4: Implement the new pin schema**

In `scripts/gen-pin.sh`, replace the `OVSHA`/`OVPLATFORM` handling with a repeatable row list:

```bash
VERSION=""; ETVER=""; BASEURL=""; ROWS=(); OVROWS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --etver) ETVER="$2"; shift 2 ;;
    --base-url) BASEURL="$2"; shift 2 ;;
    --row) ROWS+=("$2 $3 $4"); shift 4 ;;
    --openvino-row) OVROWS+=("$2 $3"); shift 3 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
```

and replace the emission block with:

```bash
# C10: the OpenVINO CPU runtime bundles. Emitted only for the platforms a row was supplied for, so
# a release that did not run the OpenVINO job still yields a valid (OpenVINO-free) pin.
# Versioned by OPENVINO version, not ET version -- it tracks an independent upstream.
if [ "${#OVROWS[@]}" -gt 0 ]; then
  printf 'set(ET_RUNTIME_OPENVINO_VERSION "%s")\n' "$OV_VERSION"
  _ov_legacy_sha=""
  for r in "${OVROWS[@]}"; do
    # shellcheck disable=SC2086  # split the "platform sha" pair
    set -- $r
    ovplatform="$1"; ovsha="$2"
    case "$ovsha" in
      ""|*[!0-9a-f]*) echo "gen-pin.sh: --openvino-row sha is not lowercase hex ('$ovsha')" >&2; exit 1 ;;
    esac
    [ "${#ovsha}" -eq 64 ] \
      || { echo "gen-pin.sh: --openvino-row sha must be 64 hex chars (got ${#ovsha})" >&2; exit 1; }
    printf 'set(ET_RUNTIME_OPENVINO_URL_%s\n  "%s/%s")\n' \
      "$ovplatform" "$BASEURL" "$(ov_tarball_name "$ovplatform")"
    printf 'set(ET_RUNTIME_OPENVINO_SHA256_%s "%s")\n\n' "$ovplatform" "$ovsha"
    [ "$ovplatform" = "linux-x86_64" ] && _ov_legacy_sha="$ovsha"
  done

  # A platform that SHARES another's bundle still needs its own row, or a consumer building that
  # row cannot find a runtime. Emitted as aliases rather than duplicate assets.
  while read -r p; do
    [ -n "$p" ] || continue
    b="$(ov_bundle_platform "$p")" || continue
    [ "$b" = "$p" ] && continue
    printf 'set(ET_RUNTIME_OPENVINO_URL_%s "${ET_RUNTIME_OPENVINO_URL_%s}")\n' "$p" "$b"
    printf 'set(ET_RUNTIME_OPENVINO_SHA256_%s "${ET_RUNTIME_OPENVINO_SHA256_%s}")\n\n' "$p" "$b"
  done <<EOF
$(ov_alias_platforms)
EOF

  cat <<'EOF'
# Ask for a platform's bundle. Unlike et_runtime_dist_url this does NOT abort when there is no
# row: a platform with no OpenVINO bundle is legitimate (linux-aarch64 has none), so the caller
# gets empty strings and decides. Test the url, do not test DEFINED on a built-up name.
function(et_runtime_openvino_url platform out_url out_sha)
  if(DEFINED ET_RUNTIME_OPENVINO_URL_${platform})
    set(${out_url} "${ET_RUNTIME_OPENVINO_URL_${platform}}" PARENT_SCOPE)
    set(${out_sha} "${ET_RUNTIME_OPENVINO_SHA256_${platform}}" PARENT_SCOPE)
  else()
    set(${out_url} "" PARENT_SCOPE)
    set(${out_sha} "" PARENT_SCOPE)
  endif()
endfunction()

EOF

  # DEPRECATED legacy trio. docs/openvino-jni-consumer.md still instructs consumers to compare
  # ET_RUNTIME_ROW against ET_RUNTIME_OPENVINO_PLATFORM; dropping these would break them at the
  # next release with no signal. Remove once djl-executorch-engine has migrated to the selector.
  if [ -n "$_ov_legacy_sha" ]; then
    cat <<'EOF'
# DEPRECATED: single-bundle variables, kept for consumers written before multi-platform bundles.
# Use et_runtime_openvino_url(<platform> url sha) instead; these describe linux-x86_64 only.
EOF
    printf 'set(ET_RUNTIME_OPENVINO_PLATFORM "linux-x86_64")\n'
    printf 'set(ET_RUNTIME_OPENVINO_URL\n  "%s/%s")\n' "$BASEURL" "$(ov_tarball_name linux-x86_64)"
    printf 'set(ET_RUNTIME_OPENVINO_SHA256 "%s")\n\n' "$_ov_legacy_sha"
  fi
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash test/pin.test.sh && bash test/run.sh
```

Expected: `ALL UNIT TESTS PASS`, including the three cmake-executed selector cases.

- [ ] **Step 6: Commit**

```bash
git add scripts/gen-pin.sh scripts/lib/openvino.sh test/pin.test.sh \
  test/fixtures/pin/openvino_selector_probe.cmake test/lib_openvino.test.sh
git commit -m "feat(pin): per-platform OpenVINO rows and a selector

gen-pin.sh emitted a singular ET_RUNTIME_OPENVINO_{PLATFORM,URL,SHA256}: one
bundle, one platform. Three platforms now have one, so the rows take the shape
the tarball rows already use -- flat per-platform vars plus a fixed selector.

et_runtime_openvino_url deliberately does NOT abort on a missing row, unlike
et_runtime_dist_url: a platform without a bundle is legitimate, so the caller
gets empty strings and decides.

windows-x86_64-static gets an alias row pointing at the windows-x86_64 bundle.
The legacy trio is still emitted for linux-x86_64, marked DEPRECATED -- the JNI
consumer doc still instructs its use and dropping it would break consumers at
the next release with no signal."
```

- [ ] **Step 7: File the removal issue**

```bash
gh issue create --title "Remove the deprecated single-bundle ET_RUNTIME_OPENVINO_* pin variables" \
  --body "gen-pin.sh still emits ET_RUNTIME_OPENVINO_{PLATFORM,URL,SHA256} for linux-x86_64
alongside the per-platform rows and et_runtime_openvino_url(), because
docs/openvino-jni-consumer.md instructed the old pattern and consumers were written against it.

Remove them once djl-executorch-engine reads the selector. Leaving this untracked is how a
deprecation becomes permanent."
```

Record the issue number in a comment above the legacy block in `gen-pin.sh`, by full URL — a bare `#NN` does not resolve for a reader of the script.

---

## Task 4: Build and publish every bundle

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: one `openvino-runtime-<ovver>-<platform>.tar.gz` + `.sha256` per entry in `ov_bundle_platforms`, and a pin with a row for each.

- [ ] **Step 1: Matrix the `openvino` job over the bundle platforms**

The job currently hardcodes `linux-x86_64` in four places. Give it a matrix whose values come from the SSOT rather than a second literal list. Add to the `setup` job's outputs:

```yaml
      ovbundles: ${{ steps.ovb.outputs.ovbundles }}
```

and a step in `setup`:

```yaml
      - name: Bundle platforms
        id: ovb
        run: |
          set -euo pipefail
          . ./scripts/lib/openvino.sh
          # JSON array from the SSOT, so the release matrix cannot drift from ov_bundle_platforms.
          # sed+paste, not jq: no workflow in this repo uses jq today and the bundle list is a
          # handful of bare platform strings -- not worth a new tool on the release path.
          printf 'ovbundles=[%s]\n' \
            "$(ov_bundle_platforms | sed 's/.*/"&"/' | paste -sd, -)" >> "$GITHUB_OUTPUT"
```

Then in the `openvino` job:

```yaml
    strategy:
      fail-fast: false
      matrix:
        platform: ${{ fromJSON(needs.setup.outputs.ovbundles) }}
```

and replace the four hardcoded `linux-x86_64` uses with `${{ matrix.platform }}`, including the `--platform` flag on `vendor-openvino.sh`. **The smoke gate must follow the platform too**: `test/openvino_smoke.sh` is the POSIX one and cannot gate a `win_amd64` bundle. Guard it:

```bash
          if [ "${{ matrix.platform }}" = "linux-x86_64" ]; then
            bash test/openvino_smoke.sh "$PWD/ovstage/$(ov_asset_stem "${{ matrix.platform }}")"
          else
            echo ">> ${{ matrix.platform }} bundle is gated on the Windows runner by extras-gate;"
            echo "   the POSIX smoke gate cannot dlopen a DLL. Contents are asserted by"
            echo "   vendor-openvino.sh's member and licence gates, which ran above."
          fi
```

Give the upload artifact a per-platform name (`dist-openvino-${{ matrix.platform }}`) so the two do not collide.

- [ ] **Step 2: Pass a row per bundle in the `pin` job**

Replace the single `--openvino-sha` block with a loop over the SSOT:

```bash
          . ./scripts/lib/openvino.sh
          while read -r ovp; do
            [ -n "$ovp" ] || continue
            ovsha_file="dist/$(ov_sha_name "$ovp")"
            # REQUIRED, not best-effort: this job hard-`needs: openvino`, so a missing sidecar
            # means artifact drift or a partial download, not "no OpenVINO this release".
            [ -f "$ovsha_file" ] || {
              echo "::error::expected $ovsha_file from the openvino job; refusing to publish a release whose pin omits OpenVINO for $ovp"
              exit 1; }
            args+=(--openvino-row "$ovp" "$(cut -d' ' -f1 "$ovsha_file")")
          done <<EOF
$(ov_bundle_platforms)
EOF
```

- [ ] **Step 3: Verify the release job publishes both**

`release` globs `dist/*`, so both bundles and both `.sha256` sidecars are picked up with no change. Confirm by reading the step rather than assuming — if it enumerates names, add the new ones.

- [ ] **Step 4: Check attestation covers the new asset**

The `openvino` job's `actions/attest` step uses `subject-path: dist/*.tar.gz`, so a second bundle in the same job is attested with no change. Confirm the matrix did not move the attest step out of the job.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): build and pin an OpenVINO bundle per platform

The openvino job hardcoded linux-x86_64 in four places. It now matrices over
ov_bundle_platforms, and the pin job emits a row per bundle. The POSIX smoke
gate is skipped for the Windows bundle -- it cannot dlopen a DLL; that bundle is
gated on the Windows runner in extras-gate."
```

---

## Task 5: Gate the static platform at runtime (finding 3)

**Files:**
- Modify: `.github/workflows/extras-gate.yml`, `test/lib/extras_gate_ov_windows.py`

**Interfaces:**
- Consumes: Task 2 (both platforms share one bundle, so no second vendoring).

- [ ] **Step 1: Extend the structural assertion**

In `test/lib/extras_gate_ov_windows.py`, replace the single-platform expectations with:

```python
    # Both CRT platforms must be gated at RUNTIME, not just compiled and packaged. They share one
    # bundle, so the second leg costs a runner and no new assets -- and windows-x86_64-static
    # shipped a delegate nothing had ever executed until this matrix existed.
    gate_platforms = set(job["strategy"]["matrix"]["platform"])
    rel_platforms = set(release["jobs"]["build-windows"]["strategy"]["matrix"]["platform"])
    if gate_platforms != rel_platforms:
        fails.append(f"runtime gate platforms {sorted(gate_platforms)} != shipped {sorted(rel_platforms)}")
```

(The file already imports `release`; if it does not, load it the same way `extras_gate_windows.py` does.)

- [ ] **Step 2: Run to verify it fails**

```bash
bash test/extras_gate_ov_windows.test.sh
```

Expected: a failure naming the platform mismatch.

- [ ] **Step 3: Matrix the gate job**

Give `full-gates-windows` a matrix over both platforms, download `win-tarball-${{ matrix.platform }}`, and keep vendoring the single shared bundle:

```yaml
    strategy:
      fail-fast: false
      matrix:
        platform: [windows-x86_64, windows-x86_64-static]
```

The fixture gate already reads the platform from the unpacked prefix's `BUILDINFO` and derives the CRT from `crt_for_platform`, so it needs no new argument — that is the payoff of doing it that way rather than passing a flag.

- [ ] **Step 4: Verify and commit**

```bash
bash test/extras_gate_ov_windows.test.sh && bash test/run.sh
git add .github/workflows/extras-gate.yml test/lib/extras_gate_ov_windows.py
git commit -m "ci(gate): run the Windows OpenVINO gates on both CRT platforms

windows-x86_64-static shipped a delegate no runtime gate had ever executed. The
two platforms share one bundle, so the second leg costs a runner and no assets.
The fixture gate reads the CRT from the prefix's BUILDINFO, so it needed no new
argument."
```

---

## Task 6: Update the consumer documentation

**Files:**
- Modify: `README.md:68`, `docs/handover-to-engine.md:91`, `docs/openvino-jni-consumer.md:45-54`, `docs/openvino-python-consumer.md:21-22`

**Interfaces:**
- Consumes: Task 3's selector.

- [ ] **Step 1: Replace the single-bundle pattern in the JNI doc**

`docs/openvino-jni-consumer.md` currently shows:

```cmake
if(DEFINED ET_RUNTIME_OPENVINO_URL AND ET_RUNTIME_ROW STREQUAL ET_RUNTIME_OPENVINO_PLATFORM)
```

Replace with the selector, and say why it is better — the old form silently declined to fetch a bundle whenever the row did not happen to be the one platform a bundle existed for:

```cmake
# Ask the pin whether a bundle exists for the row you are building. Returns empty when there is
# none (linux-aarch64), so this is a test on the value rather than on a built-up variable name.
et_runtime_openvino_url("${ET_RUNTIME_ROW}" ov_url ov_sha)
if(ov_url)
  FetchContent_Declare(openvino_runtime
    URL       "${ov_url}"
    URL_HASH  "SHA256=${ov_sha}")
  FetchContent_MakeAvailable(openvino_runtime)
endif()
```

- [ ] **Step 2: Update the Windows section of the python consumer doc**

`docs/openvino-python-consumer.md` currently tells Windows users to supply their own `openvino_c.dll` because no bundle is published. That is no longer true. Replace that paragraph with the pinned bundle, and **keep** the two facts that remain true regardless of where the DLL comes from: `OPENVINO_LIB_PATH` must be **absolute** on Windows, and the MSVC redistributable must be installed.

- [ ] **Step 3: Update README and the handover doc**

Both describe `ET_RUNTIME_OPENVINO_{VERSION,URL,SHA256}` as the pinned form. Update to the per-platform vars plus the selector, and note the legacy trio is deprecated with a pointer to the removal issue from Task 3 Step 7.

- [ ] **Step 4: Commit, push, open the PR**

```bash
git add README.md docs/handover-to-engine.md docs/openvino-jni-consumer.md \
  docs/openvino-python-consumer.md
git commit -m "docs: the OpenVINO pin is per-platform now

Consumers select with et_runtime_openvino_url(row url sha) instead of comparing
against a single ET_RUNTIME_OPENVINO_PLATFORM. The Windows guidance no longer
tells users to supply their own openvino_c.dll -- there is a published bundle."
git push -u origin feature/openvino-windows-publish
gh pr create --fill
```

- [ ] **Step 5: Verify the gate proved what it claims**

In `full-gates-windows`, for **both** matrix legs, confirm the four lines the predecessor plan established: `ok: plain load fails`, `DEVICE CPU` + `IMPORT OK` with no `[OUTSIDE]`, `ok: load fails without OPENVINO_LIB_PATH`, and `compare.py: 8 values match`.

The new signal in this PR is the `windows-x86_64-static` leg reaching that last line. If only the `/MD` leg does, the matrix did not take effect.

- [ ] **Step 6: Verify the pin by eye before tagging**

The pin is generated at release time, not on a PR, so the gate cannot check it. Before tagging, run it locally with representative values and read the output:

```bash
./scripts/gen-pin.sh --version 9.9.9-1 --etver 1.4.1 --base-url https://example/dl \
  --row logging linux-x86_64 "$(printf 'a%.0s' $(seq 64))" \
  --openvino-row linux-x86_64 "$(printf 'b%.0s' $(seq 64))" \
  --openvino-row windows-x86_64 "$(printf 'c%.0s' $(seq 64))"
```

Confirm: a row for each bundle, an alias row for `windows-x86_64-static` pointing at the `windows-x86_64` values, the selector present, and the DEPRECATED legacy trio describing `linux-x86_64`.

---

## What this does NOT deliver

- **No upstream ExecuTorch PR.** Still deferred; the argument for it is now a published, gated implementation.
- **No new platforms.** `linux-aarch64` still has no bundle and the selector correctly returns empty for it.
- **The legacy pin variables are not removed**, only deprecated — tracked by the issue from Task 3 Step 7. That issue is the only thing keeping this from becoming permanent.
