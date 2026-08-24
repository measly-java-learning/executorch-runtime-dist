# Devtools Header Install + event_tracer BUILDINFO Key Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `devtools` tarball's `etdump`/`flatccrt` targets actually usable — a
consumer can `#include <executorch/devtools/etdump/etdump_flatcc.h>` and link `etdump` — and
give consumers an authoritative, non-inferred signal (`event_tracer=on|off` in `BUILDINFO`)
for whether a runtime can trace.

**Architecture:** Two independent, additive changes to the existing recipe machinery, each
following a worn path already in this repo:
1. A fourth vendored source patch (`patches/et-devtools-headers.patch`), applied by the
   existing `scripts/patch-et-sources.sh`, adds a header `install()` to ET's
   `devtools/etdump/CMakeLists.txt`, guarded on `EXECUTORCH_BUILD_DEVTOOLS` so it is a no-op
   for `bare`/`logging`. `scripts/package.sh` gets a new guard (parallel to the existing
   OpenVINO-archive guard) that refuses to package a `devtools` tarball missing the header.
2. `scripts/lib/variants.sh` grows one new function, `event_tracer_for_variant`, derived
   directly from the existing `variant_flags` output (no second copy of the variant list).
   `scripts/gen-buildinfo.sh` and `scripts/package.sh` are wired to require/emit
   `event_tracer=on|off`, following the exact pattern already used for `usdt=on|off`.

**Tech Stack:** Bash (`set -euo pipefail`), CMake (ET's install() rules), `git apply` for
patching, the repo's hermetic `test/*.test.sh` + `test/assert.sh` harness (no build, no
container, no ET checkout — runs in ~2s via `bash test/run.sh`).

**Spec:** `docs/devtools-header-install-handover.md`

## Global Constraints

- Every `devtools` tarball must contain `include/executorch/devtools/etdump/etdump_flatcc.h`
  and the `data_sinks/` headers it transitively includes (`buffer_data_sink.h`,
  `data_sink_base.h`). (Spec §7.1, §7.2)
- `bare` and `logging` tarballs must be byte-for-byte unchanged in scope: no devtools headers,
  no `etdump` target, no `libetdump.a`. Windows tarballs untouched. (Spec §7.3)
- `BUILDINFO` must carry `event_tracer=on` for `devtools` and `event_tracer=off` for `bare`
  and `logging`, sourced from the same place as the `-DEXECUTORCH_ENABLE_EVENT_TRACER` cmake
  flag — not a second copy of the variant list. (Spec §7.4, §3)
- Install `flatcc_builder.h` (declares `flatcc_builder_aligned_free`, the portable release for
  MSVC-allocated ETDump buffers). Second priority, not a release blocker. (Spec §7.5)
- The header-install mechanism is a source patch via `patches/` +
  `scripts/patch-et-sources.sh`, idempotent, hard-erroring (never silently skipping) when the
  anchor text has moved. (Spec §4)
- `scripts/package.sh` must refuse to package a `devtools` prefix missing the header — prove
  the change survived the build, not merely that a file was edited. (Spec §5)
- Assert behaviour, not diff shape — no greps for exact current wording where the spec asks
  for behavioural assertions. (Spec §6)
- Do **not** touch `build-runtime.sh`, `bare`/`logging` scope, Windows tarballs, or upstream
  ExecuTorch. Do **not** implement §8 (optional Windows `devtools` rows) — separate workstream,
  explicitly out of scope. Do **not** cut the `v1.4.1-3` release tag — that is a follow-up
  action outside this plan (tag pushes are the sole release trigger and are not something to
  do without the user's explicit go-ahead).

---

## File Structure

- `patches/et-devtools-headers.patch` — **new.** The vendored source patch adding the header
  `install()` rule to ET's `devtools/etdump/CMakeLists.txt`.
- `test/fixtures/etpatch/etdump-CMakeLists.txt` — **new.** Pristine fixture the hermetic patch
  test patches against (mirrors the `openvino-CMakeLists.txt` fixture pattern already there).
- `scripts/patch-et-sources.sh` — **modify.** One new `apply_patch` call.
- `test/patch_et_sources.test.sh` — **modify.** `mk_tree` grows the devtools/etdump fixture;
  new assertions for the header-install patch (applies, idempotent, drift fails loud).
- `scripts/lib/variants.sh` — **modify.** New `event_tracer_for_variant` function.
- `test/lib_variants.test.sh` — **modify.** Coverage for the new function.
- `scripts/gen-buildinfo.sh` — **modify.** Require `EVENT_TRACER`, emit `event_tracer=...`.
- `test/buildinfo.test.sh` — **modify.** Existing invocations gain `EVENT_TRACER=...`; new
  assertions for the key and its hard-error-when-missing behaviour.
- `scripts/package.sh` — **modify.** Compute `EVENT_TRACER` via `event_tracer_for_variant`,
  pass it through to `gen-buildinfo.sh`; add the devtools-header packaging guard.
- `test/package.test.sh` — **modify.** New fixtures: a `devtools` prefix with the header
  (packages, `BUILDINFO` records `event_tracer=on`), a `devtools` prefix without it (hard
  error), and a `logging` prefix (`event_tracer=off`, unaffected).
- `README.md` — **modify.** One-line addition documenting `event_tracer` in the BUILDINFO
  section, mirroring the existing `usdt=on|off` sentence.
- `docs/devtools-header-install-handover.md` — **modify.** Flip `Status:` from "not started"
  to reflect the header/BUILDINFO work being done, noting §8 remains a separate workstream.

---

### Task 1: `event_tracer_for_variant` in `scripts/lib/variants.sh`

**Files:**
- Modify: `scripts/lib/variants.sh`
- Test: `test/lib_variants.test.sh`

**Interfaces:**
- Produces: `event_tracer_for_variant <bare|logging|devtools>` — prints `on` or `off` to
  stdout, derived from `variant_flags`'s own output (never a second variant list). Returns 2
  and prints `unknown variant: $1` to stderr for an unrecognized variant, matching
  `variant_flags`'s existing contract. Consumed by Task 3 (`scripts/package.sh`).

- [ ] **Step 1: Write the failing test**

Append to `test/lib_variants.test.sh`, just before the final `variant_flags bogus` check:

```bash
assert_eq "$(event_tracer_for_variant bare)"     "off" "bare event_tracer off"
assert_eq "$(event_tracer_for_variant logging)"  "off" "logging event_tracer off"
assert_eq "$(event_tracer_for_variant devtools)" "on"  "devtools event_tracer on"
event_tracer_for_variant bogus >/dev/null 2>&1
assert_eq "$?" "2" "event_tracer_for_variant: unknown variant returns 2"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_variants.test.sh`
Expected: FAIL — `event_tracer_for_variant: command not found`.

- [ ] **Step 3: Implement `event_tracer_for_variant`**

In `scripts/lib/variants.sh`, append after the closing `}` of `variant_flags`:

```bash

# Capability signal for BUILDINFO's event_tracer key. Derived from variant_flags's own output
# — never a second copy of the variant list — so this cannot drift from the cmake flag that
# actually controls EXECUTORCH_ENABLE_EVENT_TRACER.
event_tracer_for_variant() { # <bare|logging|devtools>
  case "$(variant_flags "$1")" in
    *-DEXECUTORCH_ENABLE_EVENT_TRACER=ON*) printf 'on' ;;
    *) printf 'off' ;;
  esac
}
```

Note: `variant_flags bogus` already exits 2 with a stderr message before returning any output,
so `event_tracer_for_variant bogus` naturally propagates the same exit code — no separate
validation needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_variants.test.sh`
Expected: PASS, all `ok:` lines, `ASSERT_FAILS=0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/variants.sh test/lib_variants.test.sh
git commit -m "feat: add event_tracer_for_variant, derived from variant_flags"
```

---

### Task 2: `event_tracer` key in `scripts/gen-buildinfo.sh`

**Files:**
- Modify: `scripts/gen-buildinfo.sh`
- Test: `test/buildinfo.test.sh`

**Interfaces:**
- Consumes: none new (plain env var `EVENT_TRACER`, set by the caller — Task 3 wires
  `scripts/package.sh` to set it via `event_tracer_for_variant` from Task 1).
- Produces: a required `event_tracer=on|off` line in `BUILDINFO`, consumed by downstream
  consumers (the engine) and asserted on by Task 3's packaging tests.

- [ ] **Step 1: Write the failing test**

`test/buildinfo.test.sh` currently builds its `$out` via one big env-var invocation. Update it
so **all** existing invocations in the file gain `EVENT_TRACER=off` (or `on` where the variant
is devtools-flavored — all existing cases in this file use `VARIANT=logging`, so `off` for all
of them), then add new assertions. Replace the whole file with:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"
out="$(ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.13.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 USDT=on \
  OPENVINO_VERSION="$OV_VERSION" EVENT_TRACER=off \
  bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out" "et_version=1.3.1"        "et_version"
assert_contains "$out" "et_commit=abc123"        "et_commit"
assert_contains "$out" "torch_version=2.13.0+cpu" "torch_version"
assert_contains "$out" "variant=logging"         "variant"
assert_contains "$out" "platform=linux-x86_64"   "platform"
assert_contains "$out" "package_tag=v1.3.1-1"    "package_tag"
assert_contains "$out" "build_utc="              "build_utc present"
assert_contains "$out" "toolchain=manylinux_2_28 gcc-toolset-14" "toolchain"
assert_contains "$out" "usdt=on" "usdt field"
assert_contains "$out" "event_tracer=off" "event_tracer field"

# USDT is required: omitting it is a hard error (never silently drop provenance).
ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.13.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 \
  OPENVINO_VERSION=n/a EVENT_TRACER=off \
  bash "$here/../scripts/gen-buildinfo.sh" >/dev/null 2>&1
assert_eq "$?" "1" "missing USDT is a hard error"

# event_tracer is required too: omitting it must be just as hard an error as omitting USDT —
# a silently-dropped capability signal is the exact failure mode this key exists to prevent.
ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.13.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 \
  OPENVINO_VERSION=n/a USDT=on \
  bash "$here/../scripts/gen-buildinfo.sh" >/dev/null 2>&1
assert_eq "$?" "1" "missing EVENT_TRACER is a hard error"

# devtools value: event_tracer=on flows through when the caller says so.
out_dt="$(ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.13.0+cpu VARIANT=devtools \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_BUILD_DEVTOOLS=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 USDT=on \
  OPENVINO_VERSION="$OV_VERSION" EVENT_TRACER=on \
  bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out_dt" "event_tracer=on" "event_tracer=on for devtools"

# C5: OpenVINO provenance. linux-x86_64 records the pinned version; every other platform
# records n/a so the key is always present and greppable.
out_ov="$(ET_VERSION=1.3.1 ET_COMMIT=abc TORCH_VERSION=2.13.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='--preset linux' TOOLCHAIN=tc PACKAGE_TAG=v1.3.1-1 USDT=on \
  OPENVINO_VERSION="$OV_VERSION" EVENT_TRACER=off bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out_ov" "openvino_version=$OV_VERSION" "buildinfo records openvino_version"

out_na="$(ET_VERSION=1.3.1 ET_COMMIT=abc TORCH_VERSION=2.13.0+cpu VARIANT=logging \
  PLATFORM=windows-x86_64 CMAKE_FLAGS='flags' TOOLCHAIN=tc PACKAGE_TAG=v1.3.1-1 USDT=n/a \
  OPENVINO_VERSION=n/a EVENT_TRACER=off bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out_na" "openvino_version=n/a" "buildinfo records n/a off linux-x86_64"

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/buildinfo.test.sh`
Expected: FAIL on `event_tracer field` (key absent) and on `missing EVENT_TRACER is a hard
error` (currently succeeds because nothing requires the var — expected exit is `1` but actual
will be `0`).

- [ ] **Step 3: Implement the `event_tracer` key**

In `scripts/gen-buildinfo.sh`, change:

```bash
: "${ET_VERSION:?}"; : "${ET_COMMIT:?}"; : "${TORCH_VERSION:?}"; : "${VARIANT:?}"
: "${PLATFORM:?}"; : "${CMAKE_FLAGS:?}"; : "${TOOLCHAIN:?}"; : "${PACKAGE_TAG:?}"
: "${USDT:?}"; : "${OPENVINO_VERSION:?}"
cat <<EOF
et_version=$ET_VERSION
et_commit=$ET_COMMIT
torch_version=$TORCH_VERSION
variant=$VARIANT
platform=$PLATFORM
usdt=$USDT
openvino_version=$OPENVINO_VERSION
cmake_flags=$CMAKE_FLAGS
toolchain=$TOOLCHAIN
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
package_tag=$PACKAGE_TAG
EOF
```

to:

```bash
: "${ET_VERSION:?}"; : "${ET_COMMIT:?}"; : "${TORCH_VERSION:?}"; : "${VARIANT:?}"
: "${PLATFORM:?}"; : "${CMAKE_FLAGS:?}"; : "${TOOLCHAIN:?}"; : "${PACKAGE_TAG:?}"
: "${USDT:?}"; : "${OPENVINO_VERSION:?}"; : "${EVENT_TRACER:?}"
cat <<EOF
et_version=$ET_VERSION
et_commit=$ET_COMMIT
torch_version=$TORCH_VERSION
variant=$VARIANT
platform=$PLATFORM
usdt=$USDT
event_tracer=$EVENT_TRACER
openvino_version=$OPENVINO_VERSION
cmake_flags=$CMAKE_FLAGS
toolchain=$TOOLCHAIN
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
package_tag=$PACKAGE_TAG
EOF
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/buildinfo.test.sh`
Expected: PASS, all `ok:` lines, `ASSERT_FAILS=0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/gen-buildinfo.sh test/buildinfo.test.sh
git commit -m "feat: require and emit event_tracer=on|off in BUILDINFO"
```

---

### Task 3: Wire `EVENT_TRACER` through `scripts/package.sh` + devtools-header packaging guard

**Files:**
- Modify: `scripts/package.sh`
- Test: `test/package.test.sh`

**Interfaces:**
- Consumes: `event_tracer_for_variant` (Task 1, already sourced — `package.sh` already does
  `. "$HERE/lib/variants.sh"`); the required `EVENT_TRACER` env var on `gen-buildinfo.sh`
  (Task 2).
- Produces: `package.sh` now refuses (exit 1) to package a `devtools` prefix whose
  `include/executorch/devtools/etdump/etdump_flatcc.h` is missing. Every packaged tarball's
  `BUILDINFO` carries the correct `event_tracer` value.

- [ ] **Step 1: Write the failing test**

Append to `test/package.test.sh` (after the existing "linux-x86_64 prefix without
libopenvino_backend.a is refused" block at the end of the file):

```bash

# --- event_tracer provenance + devtools header guard ---

# logging (existing fixture $p) must record event_tracer=off.
outlog2="$(mktemp -d)"
tblog2="$(bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$outlog2")"
bilog2="$(tar -xzOf "$tblog2" executorch-runtime-1.3.1-logging-linux-x86_64/BUILDINFO)"
assert_contains "$bilog2" "event_tracer=off" "logging BUILDINFO records event_tracer=off"

# A devtools prefix WITH the installed header packages cleanly and records event_tracer=on.
pdt="$(mktemp -d)/pfxdt"
mkdir -p "$pdt/lib/cmake/ExecuTorch" \
         "$pdt/include/executorch/devtools/etdump/data_sinks" \
         "$pdt/THIRD-PARTY-NOTICES"
: > "$pdt/lib/cmake/ExecuTorch/executorch-config.cmake"
: > "$pdt/lib/libopenvino_backend.a"
: > "$pdt/lib/libetdump.a"
: > "$pdt/include/et.h"
: > "$pdt/include/executorch/devtools/etdump/etdump_flatcc.h"
: > "$pdt/include/executorch/devtools/etdump/data_sinks/buffer_data_sink.h"
: > "$pdt/THIRD-PARTY-NOTICES/xnnpack_LICENSE"
: > "$pdt/LICENSE"
echo "deadbeef" > "$pdt/.et_commit"
echo "on" > "$pdt/.etnp_usdt"
outdt="$(mktemp -d)"
tbdt="$(bash "$here/../scripts/package.sh" --prefix "$pdt" --etver 1.3.1 --variant devtools \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$outdt")"
bidt="$(tar -xzOf "$tbdt" executorch-runtime-1.3.1-devtools-linux-x86_64/BUILDINFO)"
assert_contains "$bidt" "event_tracer=on" "devtools BUILDINFO records event_tracer=on"
membersdt="$(tar -tzf "$tbdt")"
assert_contains "$membersdt" "etdump_flatcc.h" "devtools tarball ships the etdump header"

# A devtools prefix WITHOUT the header must be refused outright — proves the change survived
# the build rather than merely that a file was edited somewhere (spec §5).
pdtmiss="$(mktemp -d)/pfxdtmiss"
mkdir -p "$pdtmiss/lib/cmake/ExecuTorch" "$pdtmiss/include" "$pdtmiss/THIRD-PARTY-NOTICES"
: > "$pdtmiss/lib/cmake/ExecuTorch/executorch-config.cmake"
: > "$pdtmiss/lib/libopenvino_backend.a"
: > "$pdtmiss/lib/libetdump.a"
: > "$pdtmiss/include/et.h"
: > "$pdtmiss/THIRD-PARTY-NOTICES/xnnpack_LICENSE"
: > "$pdtmiss/LICENSE"
echo "deadbeef" > "$pdtmiss/.et_commit"
echo "on" > "$pdtmiss/.etnp_usdt"
bash "$here/../scripts/package.sh" --prefix "$pdtmiss" --etver 1.3.1 --variant devtools \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$(mktemp -d)" >/dev/null 2>&1
assert_eq "$?" "1" "devtools prefix without etdump_flatcc.h is refused"

# The guard must be devtools-specific: a logging prefix missing the header packages fine
# (bare/logging never had it and never will).
outlogok="$(mktemp -d)"
bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$outlogok" >/dev/null
assert_eq "$?" "0" "logging prefix without devtools header still packages"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/package.test.sh`
Expected: FAIL — the two new `event_tracer=` assertions fail because `package.sh` does not yet
set `EVENT_TRACER` (so `gen-buildinfo.sh` will hard-error with exit 1, `tbdt`/`tblog2` will be
empty, and `tar -xzOf ""` will itself error). The "refused" assertion will fail too since
nothing yet checks for the header.

- [ ] **Step 3: Implement in `scripts/package.sh`**

Add the `EVENT_TRACER` computation next to the existing `CMAKE_FLAGS` line. Change:

```bash
CMAKE_FLAGS="$(effective_cmake_flags "$PLATFORM" "$VARIANT")"
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.13.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="$TOOLCHAIN" PACKAGE_TAG="$PACKAGE_TAG" \
  USDT="$USDT_STATE" \
  OPENVINO_VERSION="$OPENVINO_VERSION" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"
```

to:

```bash
CMAKE_FLAGS="$(effective_cmake_flags "$PLATFORM" "$VARIANT")"
EVENT_TRACER="$(event_tracer_for_variant "$VARIANT")"
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.13.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="$TOOLCHAIN" PACKAGE_TAG="$PACKAGE_TAG" \
  USDT="$USDT_STATE" \
  EVENT_TRACER="$EVENT_TRACER" \
  OPENVINO_VERSION="$OPENVINO_VERSION" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"
```

Then add the devtools-header packaging guard. Place it right after the existing OpenVINO
provenance block (after the `fi` that closes the `if ov_enabled_for_platform "$PLATFORM";
then ... fi`), before `CMAKE_FLAGS="$(effective_cmake_flags ...)"`:

```bash
# devtools header guard: a devtools tarball that links etdump but ships no header to include
# it is a broken consumer contract (spec §5/§7.1-2). Check the built PREFIX directly — proving
# the header install survived the build, not merely that the patch file exists.
if [ "$VARIANT" = "devtools" ]; then
  [ -f "$PREFIX/include/executorch/devtools/etdump/etdump_flatcc.h" ] || {
    echo "package.sh: variant 'devtools' requires" >&2
    echo "  include/executorch/devtools/etdump/etdump_flatcc.h in $PREFIX but it is missing." >&2
    echo "  The devtools header-install patch (patches/et-devtools-headers.patch) did not" >&2
    echo "  apply, or the prefix was not built with EXECUTORCH_BUILD_DEVTOOLS=ON. Refusing to" >&2
    echo "  ship a devtools tarball whose #include ETDumpGen contract is broken." >&2
    exit 1; }
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/package.test.sh`
Expected: PASS, all `ok:` lines, `ASSERT_FAILS=0`.

- [ ] **Step 5: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (confirms no other test file's `package.sh`/`gen-buildinfo.sh`
invocations broke from the new required `EVENT_TRACER` var — grep first if anything else calls
either script directly).

```bash
grep -rl 'gen-buildinfo.sh\|package.sh --prefix' test/*.test.sh scripts/*.sh
```

If any other caller turns up beyond `test/package.test.sh`, `test/buildinfo.test.sh`, and
`scripts/package.sh` itself, add `EVENT_TRACER=...`/rely on the now-sourced
`event_tracer_for_variant` there too before moving on.

- [ ] **Step 6: Commit**

```bash
git add scripts/package.sh test/package.test.sh
git commit -m "feat: wire event_tracer through package.sh, guard devtools header at package time"
```

---

### Task 4: `patches/et-devtools-headers.patch` + `scripts/patch-et-sources.sh` wiring

**Files:**
- Create: `patches/et-devtools-headers.patch`
- Create: `test/fixtures/etpatch/etdump-CMakeLists.txt`
- Modify: `scripts/patch-et-sources.sh`
- Test: `test/patch_et_sources.test.sh`

**Interfaces:**
- Produces: after `patch-et-sources.sh` runs against a `EXECUTORCH_BUILD_DEVTOOLS`-configured
  ET tree, `cmake --install` places `etdump_flatcc.h`, `data_sinks/buffer_data_sink.h`,
  `data_sinks/data_sink_base.h` under `<prefix>/include/executorch/devtools/etdump[/data_sinks]`
  and `flatcc_builder.h` under `<prefix>/include/flatcc`. This is what Task 3's packaging
  guard checks for at `$PREFIX/include/executorch/devtools/etdump/etdump_flatcc.h`.

- [ ] **Step 1: Create the fixture (pristine, pre-patch content)**

Create `test/fixtures/etpatch/etdump-CMakeLists.txt` with exactly this content (the pristine
ET v1.4.1 `devtools/etdump/CMakeLists.txt` — verified against a local ET checkout pinned at
this repo's `DEFAULT_ET_TAG="v1.4.1"`, commit `e4d02f41f7909e8ed5bf4a14ffc520d733453d9f`):

```cmake
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

set(_schema_files etdump_schema_flatcc.fbs scalar_type.fbs)

set(_schema_outputs)
foreach(schema_file ${_schema_files})
  list(APPEND _etdump_schema__srcs "${CMAKE_CURRENT_SOURCE_DIR}/${schema_file}")

  string(REGEX REPLACE "[.]fbs$" "_reader.h" generated_reader "${schema_file}")
  list(APPEND _schema_outputs
       "${DEVTOOLS_INCLUDE_DIR}/executorch/devtools/etdump/${generated_reader}"
  )

  string(REGEX REPLACE "[.]fbs$" "_builder.h" generated_builder
                       "${schema_file}"
  )
  list(APPEND _schema_outputs
       "${DEVTOOLS_INCLUDE_DIR}/executorch/devtools/etdump/${generated_builder}"
  )
endforeach()

file(MAKE_DIRECTORY
     ${DEVTOOLS_INCLUDE_DIR_NO_BUILD_INTERFACE}/executorch/devtools/etdump
)
add_custom_command(
  OUTPUT ${_schema_outputs}
  COMMAND
    # Note that the flatcc project actually writes its outputs into the source
    # tree instead of under the binary directory, and there's no way to change
    # that behavior.
    flatcc_cli -cwr -o
    ${DEVTOOLS_INCLUDE_DIR_NO_BUILD_INTERFACE}/executorch/devtools/etdump
    ${_etdump_schema__srcs}
  DEPENDS flatcc_cli ${_etdump_schema__srcs}
  COMMENT "Generating etdump headers"
)

add_library(
  etdump
  ${_schema_outputs}
  ${CMAKE_CURRENT_SOURCE_DIR}/etdump_flatcc.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/emitter.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/data_sinks/buffer_data_sink.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/data_sinks/buffer_data_sink.h
  ${CMAKE_CURRENT_SOURCE_DIR}/data_sinks/file_data_sink.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/data_sinks/file_data_sink.h
)
target_link_libraries(
  etdump
  PUBLIC flatccrt
  PRIVATE executorch
)
target_include_directories(
  etdump
  PUBLIC ${DEVTOOLS_INCLUDE_DIR}
         $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/third-party/flatcc/include>
)

install(
  TARGETS etdump flatccrt
  EXPORT ExecuTorchTargets
  DESTINATION ${CMAKE_INSTALL_LIBDIR}
  INCLUDES
  DESTINATION ${_common_include_directories}
)
```

Set permissions to match the sibling fixtures: `chmod 664
test/fixtures/etpatch/etdump-CMakeLists.txt`.

- [ ] **Step 2: Create the patch**
> **Deviation note (controller ruling B, commit f7f6ae2):** the patch text below is superseded — the shipped patch installs the whole vendored flatcc include tree (`install(DIRECTORY ${PROJECT_SOURCE_DIR}/third-party/flatcc/include/ ...)`) because `flatcc_builder.h` alone cannot be #included, and two of the Step-3 test needles were replaced with non-vacuous ones. See docs/devtools-header-install-handover.md.

Create `patches/et-devtools-headers.patch` with exactly this content (already verified: applies
clean via `git apply --check` against the pristine file above, and `git apply --reverse
--check` confirms idempotency detection works):

```diff
diff --git a/devtools/etdump/CMakeLists.txt b/devtools/etdump/CMakeLists.txt
index 9ef3c8cd6..ba34851e5 100644
--- a/devtools/etdump/CMakeLists.txt
+++ b/devtools/etdump/CMakeLists.txt
@@ -67,3 +67,28 @@ install(
   INCLUDES
   DESTINATION ${_common_include_directories}
 )
+
+# Install the public devtools headers so a downstream consumer can #include
+# ETDumpGen, not merely link against it. devtools/CMakeLists.txt adds this
+# subdirectory from two call sites (see CMakeLists.txt around
+# EXECUTORCH_BUILD_DEVTOOLS and EXECUTORCH_BUILD_PYBIND); guard explicitly
+# here rather than relying on which branch reached us, since both do.
+if(EXECUTORCH_BUILD_DEVTOOLS)
+  install(
+    FILES ${CMAKE_CURRENT_SOURCE_DIR}/etdump_flatcc.h
+    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/executorch/devtools/etdump
+  )
+  install(
+    FILES ${CMAKE_CURRENT_SOURCE_DIR}/data_sinks/buffer_data_sink.h
+          ${CMAKE_CURRENT_SOURCE_DIR}/data_sinks/data_sink_base.h
+    DESTINATION
+      ${CMAKE_INSTALL_INCLUDEDIR}/executorch/devtools/etdump/data_sinks
+  )
+  # flatcc_builder.h: declares flatcc_builder_aligned_free, the portable
+  # release for buffers ETDumpGen::get_etdump_data() hands back (flatcc
+  # allocates with _aligned_malloc under MSVC; plain free() is UB there).
+  install(
+    FILES ${PROJECT_SOURCE_DIR}/third-party/flatcc/include/flatcc/flatcc_builder.h
+    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/flatcc
+  )
+endif()
```

- [ ] **Step 3: Write the failing test — extend `mk_tree` and add assertions**

In `test/patch_et_sources.test.sh`, add the devtools fixture copy to `mk_tree()`. Insert right
after the existing `mkdir -p "$r/backends/openvino/runtime"` / OpenVINO `cp` block (before the
`git -C "$r" init -q` line):

```bash
  mkdir -p "$r/devtools/etdump/data_sinks"
  cp "$here/fixtures/etpatch/etdump-CMakeLists.txt" "$r/devtools/etdump/CMakeLists.txt"
```

Then, near the top of the script, add the new patch to the `apply_patch` invocation list. This
is a script edit inside the *test* file that exercises the patch application logic the same way
`scripts/patch-et-sources.sh` will (Step 4 wires the real script) — but the test invokes the
real `patch-et-sources.sh` script directly (`script="$here/../scripts/patch-et-sources.sh"`),
so no separate call list exists in the test itself; only `mk_tree` needs the new fixture.

Add these assertions right after the existing OpenVINO assertions (after the `"MSVC compile
options patched in"` assertion, before the "Linux path must be untouched" comment block):

```bash

# The devtools header-install patch. Assert on the install() rule content, not the surrounding
# comment prose — a reworded comment must not fail this test.
assert_contains "$(cat "$tmp/et/devtools/etdump/CMakeLists.txt")" \
  "if(EXECUTORCH_BUILD_DEVTOOLS)" "devtools header install is guarded on EXECUTORCH_BUILD_DEVTOOLS"
assert_contains "$(cat "$tmp/et/devtools/etdump/CMakeLists.txt")" \
  'DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/executorch/devtools/etdump' \
  "etdump_flatcc.h install destination patched in"
assert_contains "$(cat "$tmp/et/devtools/etdump/CMakeLists.txt")" \
  "data_sinks/buffer_data_sink.h" "buffer_data_sink.h install patched in"
assert_contains "$(cat "$tmp/et/devtools/etdump/CMakeLists.txt")" \
  "data_sinks/data_sink_base.h" "data_sink_base.h install patched in"
assert_contains "$(cat "$tmp/et/devtools/etdump/CMakeLists.txt")" \
  "flatcc_builder.h" "flatcc_builder.h install patched in"
```

Then extend the existing idempotency check (the `bash "$script" "$tmp/et"` second run further
down already re-runs against the same tree) with a "not applied twice" guard, right after the
existing `"accessor declared exactly once (not applied twice)"` assertion:

```bash
assert_eq "$(grep -c 'if(EXECUTORCH_BUILD_DEVTOOLS)' "$tmp/et/devtools/etdump/CMakeLists.txt")" \
  "1" "devtools header install guard present exactly once (not applied twice)"
```

Finally, add a drift case alongside the existing `drift3` (OpenVINO) block, right before the
`bash "$script" >/dev/null 2>&1` missing-argument check at the end of the file:

```bash

mk_tree "$tmp/drift4"
: > "$tmp/drift4/devtools/etdump/CMakeLists.txt"
git -C "$tmp/drift4" -c user.email=t@t -c user.name=t commit -qam drift
out="$(bash "$script" "$tmp/drift4" 2>&1)"
assert_eq "$?" "1" "drifted devtools/etdump anchor fails"
assert_contains "$out" "does not apply" "devtools/etdump drift failure explains itself"
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bash test/patch_et_sources.test.sh`
Expected: FAIL — the new `devtools header install` assertions fail (patch not yet wired into
`scripts/patch-et-sources.sh`, so the fixture content is unchanged after `mk_tree` +
`apply_patch`... actually since the patch call isn't wired yet, the script won't even attempt
to touch `devtools/etdump/CMakeLists.txt`, so every new `assert_contains` against patched
content fails; the `drift4` case will unexpectedly succeed (exit 0, since nothing touches that
file), failing `"drifted devtools/etdump anchor fails"` too).

- [ ] **Step 5: Wire the patch into `scripts/patch-et-sources.sh`**

Change the final three lines of `scripts/patch-et-sources.sh`:

```bash
echo ">> patching ET sources (workspace-size accounting, OpenVINO/Windows)"
apply_patch "$XNN_DIR" "$ROOT/patches/xnnpack-workspace-size-accessor.patch"
apply_patch "$ET_SRC"  "$ROOT/patches/et-xnnpack-workspace-size.patch"
apply_patch "$ET_SRC"  "$ROOT/patches/et-openvino-windows.patch"
```

to:

```bash
echo ">> patching ET sources (workspace-size accounting, OpenVINO/Windows, devtools headers)"
apply_patch "$XNN_DIR" "$ROOT/patches/xnnpack-workspace-size-accessor.patch"
apply_patch "$ET_SRC"  "$ROOT/patches/et-xnnpack-workspace-size.patch"
apply_patch "$ET_SRC"  "$ROOT/patches/et-openvino-windows.patch"
apply_patch "$ET_SRC"  "$ROOT/patches/et-devtools-headers.patch"
```

Also update the file's header comment to mention the third concern (optional but keeps the
"Two concerns" preamble accurate — change `Two concerns:` to `Three concerns:` and add a `3.`
bullet mirroring the style of `1.`/`2.`):

```bash
#   3. DEVTOOLS HEADERS — ET installs the etdump/flatccrt link targets but not their headers, so
#      a consumer can link ETDumpGen but not #include it. The patch adds a header install() to
#      devtools/etdump/CMakeLists.txt, guarded on EXECUTORCH_BUILD_DEVTOOLS so bare/logging stay
#      unaffected. See docs/devtools-header-install-handover.md.
```

Insert this new `3.` bullet directly above the file's existing `# Idempotent by contract:`
comment line (i.e. right after concern `2.`'s closing sentence about `-frtti -fexceptions`).

- [ ] **Step 6: Run test to verify it passes**

Run: `bash test/patch_et_sources.test.sh`
Expected: PASS, all `ok:` lines, `ASSERT_FAILS=0`.

- [ ] **Step 7: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 8: Commit**

```bash
git add patches/et-devtools-headers.patch test/fixtures/etpatch/etdump-CMakeLists.txt \
  scripts/patch-et-sources.sh test/patch_et_sources.test.sh
git commit -m "feat: patch ET to install devtools/etdump headers + flatcc_builder.h"
```

---

### Task 5: Docs — README BUILDINFO note + handover status

**Files:**
- Modify: `README.md`
- Modify: `docs/devtools-header-install-handover.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Update `README.md`**

In the "Bundled first-party op & dependencies" section, change:

```markdown
On Linux, every variant also emits **USDT tracepoints** for the op's XNNPACK FC cache
(`etnp:lstm_xnn_cache__hit`/`__miss`/`__evict`) — a zero-dependency way to see cache
hit/miss/eviction behavior at runtime. See `docs/lstm-xnn-cache-usdt.md`. `BUILDINFO`
records whether a build carries them (`usdt=on|off`).
```

to:

```markdown
On Linux, every variant also emits **USDT tracepoints** for the op's XNNPACK FC cache
(`etnp:lstm_xnn_cache__hit`/`__miss`/`__evict`) — a zero-dependency way to see cache
hit/miss/eviction behavior at runtime. See `docs/lstm-xnn-cache-usdt.md`. `BUILDINFO`
records whether a build carries them (`usdt=on|off`).

The `devtools` variant additionally installs the ExecuTorch devtools headers
(`include/executorch/devtools/etdump/etdump_flatcc.h` and its `data_sinks/` dependents, plus
`include/flatcc/flatcc_builder.h`), so a consumer can `#include` `ETDumpGen` and construct an
event tracer, not merely link it. `BUILDINFO` records the capability as
`event_tracer=on|off`, sourced from the same variant definition as the
`-DEXECUTORCH_ENABLE_EVENT_TRACER` cmake flag — `on` for `devtools`, `off` for `bare` and
`logging`.
```

- [ ] **Step 2: Update the handover doc's status**

In `docs/devtools-header-install-handover.md`, change the header block:

```markdown
**Date:** 2026-08-24
**Target repo:** `executorch-runtime-dist`
**Requested by:** `djl-executorch-engine`, for
`docs/superpowers/specs/2026-08-24-executorch-devtools-profiling-design.md` §2 (Phase 0)
**Status:** not started — this is the gate on all engine-side work
```

to:

```markdown
**Date:** 2026-08-24
**Target repo:** `executorch-runtime-dist`
**Requested by:** `djl-executorch-engine`, for
`docs/superpowers/specs/2026-08-24-executorch-devtools-profiling-design.md` §2 (Phase 0)
**Status:** items 1-3 implemented — see
`docs/superpowers/plans/2026-08-24-devtools-header-install.md`. Not yet released (no
`v1.4.1-3` tag pushed). §8 (Windows devtools rows) remains a separate, unstarted workstream.
```

- [ ] **Step 3: Run the full suite (docs-only sanity check)**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (docs changes touch nothing tests read).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/devtools-header-install-handover.md
git commit -m "docs: note devtools header install + event_tracer BUILDINFO key"
```

---

## Post-plan follow-up (not part of this plan's tasks)

- Cutting the `v1.4.1-3` release (pushing the tag) is the explicit release trigger
  (`.github/workflows/release.yml`) and is a user-authorized action, not something to do as
  part of implementing this plan. Once Tasks 1-5 are merged to `main`, ask the user whether to
  cut the release.
- §8 (publishing Windows `devtools` rows) is an explicitly separate, optional workstream — not
  covered here. If pursued later, it needs its own plan: it touches the `build-windows` matrix
  in `.github/workflows/release.yml` and both Windows CRT rows per spec §8.
