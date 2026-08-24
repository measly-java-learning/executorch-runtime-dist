# Windows `devtools` Variant — Design

**Date:** 2026-08-24
**Status:** approved, ready for implementation planning
**Depends on:** `docs/devtools-header-install-handover.md` §8 (requirement); `#57` (Linux devtools
headers + `event_tracer` BUILDINFO key, merged as `91fca18`); the feasibility spike at
`spike/2026-08-24-windows-devtools-variant-spike.md` (green, with two required upstream-file
fixes identified and verified live on `winbox`).

## 1. Problem

`docs/devtools-header-install-handover.md` §8 asks for `devtools` tarballs on both Windows CRT
platforms (`windows-x86_64` /MD, `windows-x86_64-static` /MT), gating the engine's Windows
profiling arm. Today Windows only ships `logging`. This was left as a separate, optional
workstream from the Linux devtools-header work because the ET `devtools` subtree
(`-DEXECUTORCH_BUILD_DEVTOOLS=ON -DEXECUTORCH_ENABLE_EVENT_TRACER=ON`) had never been built under
MSVC in this repo, and this repo has one prior precedent (the
`spike/2026-08-22-windows-optimized-ops-spike.md` optimized-kernels finding) of an ET flag that
compiles on Linux but not MSVC.

The spike closed that unknown: `devtools` **does** compile under MSVC, gated on two small,
well-understood fixes to ET's own `third-party/CMakeLists.txt` (upstream file, not this repo's
code) — both are Windows-only defects in the `flatcc_ep` `ExternalProject_Add`, invisible until
now because nothing exercised that external project on Windows before `devtools` existed as a
Windows build target. No devtools-specific MSVC/C++20 incompatibility exists; `etdump` and
`bundled_program` do not depend on torch's `c10`, unlike the optimized-kernels defect.

This design covers publishing `devtools` for both Windows platforms, following the two fixes the
spike verified and this repo's existing patterns for everything else.

## 2. Goals / Non-goals

**Goals:**
- Add `devtools` to the Windows variant matrix in both `release.yml` (`build-windows`) and
  `extras-gate.yml` (`full-build-windows`), for both `windows-x86_64` and
  `windows-x86_64-static`.
- Apply the two `flatcc_ep` fixes the spike verified, as a proper, tested part of the recipe —
  not a copy of the live winbox edits (which were throwaway and are not committed anywhere).
- Close a latent gap found along the way: the existing Windows byproduct fix for the sibling
  `flatbuffers_ep` (already in `build-runtime.sh` as an inline `sed ... || true`) has zero test
  coverage and swallows failure silently. The new fixes should not repeat that; the existing one
  is brought up to the same standard while it's being extended for the same class of bug.

**Non-goals:**
- Publishing `bare` for Windows. Not requested by the handover spec; out of scope.
- Any change to Windows extras (`build-runtime.sh` skips phase 2 on Windows unconditionally,
  `devtools` included — this design does not touch that).
- Re-litigating whether Windows devtools should be published at all — that's the handover spec's
  call, already made.
- Measuring the C4530 exception-boundary warning count or running the `/MT` flavor a second time
  beyond what CI itself will do — the spike explicitly deferred both as non-blocking for
  feasibility (see spike *Findings*, "Not measured this run").

## 3. The `flatcc_ep` fix

### 3.1 What's broken (from the spike)

Two independent defects in ET's `third-party/CMakeLists.txt`, both inside the `flatcc_ep`
`ExternalProject_Add` block (around line 107-130 at the `v1.4.1` pin):

1. **Missing `.exe` on `BUILD_BYPRODUCTS`.** Line 128 declares
   `BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc` (no suffix). This repo's `build-runtime.sh`
   already fixes the *sibling* `flatbuffers_ep`'s identical bug
   (`BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc` → `.exe`) via an anchored `sed`, but that anchor
   (`bin/flatc$`) does not match `bin/flatcc` — the `$` requires end-of-line immediately after
   `flatc`, and `flatcc` has one more character first. Symptom: `ninja: error:
   'third-party/flatcc_ep/bin/flatcc.exe', needed by
   '...etdump_schema_flatcc_builder.h', missing and no known rule to make it`.

2. **`flatcc_ep` never passes `-DCMAKE_BUILD_TYPE=Release`.** Even after fix 1 makes the
   byproduct *declaration* say `.exe`, the actual file built is `flatcc_d.exe` (debug postfix) —
   `flatcc_ep`'s CMake build defaults to a debug config in the absence of an explicit build type,
   unlike the neighboring `flatbuffers_ep`, whose own comment notes "the build forces Release
   config" internally regardless of `CMAKE_BUILD_TYPE`. `flatcc` has no such internal forcing.
   Symptom (only visible after fix 1): `'...\third-party\flatcc_ep\bin\flatcc.exe' is not
   recognized as an internal or external command`.

Both fixes were verified live on `winbox` (see spike *Findings*) to produce a working
`flatcc.exe`, after which the full `devtools`/`windows-x86_64` build completed, installed the
expected `etdump.lib`/`flatccrt.lib`/headers, and packaged cleanly with `event_tracer=on` in
`BUILDINFO`.

### 3.2 Mechanism: extract to a testable script

`build-runtime.sh` currently has this shape (inside `if [ "$IS_WINDOWS" -eq 1 ]`, before
configure):

```bash
echo ">> patching flatc_ep BUILD_BYPRODUCTS for WIN32 (.exe) — upstream flatc byproduct bug"
sed -i 's#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)$#\1.exe#' \
  "$ET_SRC/third-party/CMakeLists.txt" || true
```

This has no test coverage (unlike `patches/*.patch`, which get hermetic fixture tests via
`test/patch_et_sources.test.sh`), and the `|| true` swallows any failure silently — there is no
signal today if the anchor ever stops matching. Extending this in place would keep both problems
and add a third un-tested sed alongside it.

Instead, pull the byproduct-fix logic (the existing `flatc` sed plus the two new `flatcc` fixes)
out into its own script, `scripts/patch-et-windows-byproducts.sh`, invoked from
`build-runtime.sh`'s `IS_WINDOWS` block the same way `scripts/patch-et-sources.sh` is already
invoked (unconditionally, but this new script is a no-op with a clear message on non-Windows, so
a future caller who forgets the guard fails safe rather than corrupting a Linux checkout):

```
Usage: patch-et-windows-byproducts.sh <et-src>
```

Behavior:
- Broaden the existing `flatc`/`flatcc` byproduct-suffix fix into ONE sed whose pattern matches
  both (`bin/flatc` optionally followed by one more `c`, anchored at end-of-line) rather than two
  near-duplicate lines — this is what keeps `flatbuffers_ep`'s already-working fix and the new
  `flatcc_ep` fix expressible as one rule instead of accidentally reintroducing the exact
  bug class (an anchor that matches one target and not its sibling).
- A second sed inserts `-DCMAKE_BUILD_TYPE=Release` into `flatcc_ep`'s `CMAKE_ARGS`, anchored
  after the `-DFLATCC_INSTALL=ON` line (the exact edit verified live).
- Idempotent: re-running on an already-patched file must be a no-op, not a duplicate insert. The
  `.exe`-suffix sed is naturally idempotent (a second run finds no unsuffixed anchor to match).
  The `-DCMAKE_BUILD_TYPE=Release` insertion is NOT naturally idempotent (a plain "insert after
  this line" sed run twice inserts twice) — guard it with a `grep -q` check first, mirroring how
  `apply_patch` in `scripts/patch-et-sources.sh` treats "already applied" as success rather than
  a second mutation.
- On any failure (file missing, unexpected content), exit non-zero with an actionable message —
  no `|| true`. `build-runtime.sh`'s call site should NOT swallow this either; if a future ET bump
  moves either anchor, the build should fail loudly at the patch step, not three build minutes
  later with an opaque ninja error (the failure mode this design was itself debugged through).

### 3.3 Testing

New `test/patch_et_windows_byproducts.test.sh`, hermetic (no ET checkout, no build — same shape
as `test/patch_et_sources.test.sh`): build a synthetic `third-party/CMakeLists.txt` fixture
carrying just the `flatbuffers_ep`/`flatcc_ep` anchor text (both `BUILD_BYPRODUCTS` lines and the
`flatcc_ep` `CMAKE_ARGS` block, trimmed to the real file's shape at the `v1.4.1` pin — a new
fixture under `test/fixtures/etpatch/`), and assert:
- First run: both `BUILD_BYPRODUCTS` lines end in `.exe`, `flatcc_ep`'s `CMAKE_ARGS` gains
  `-DCMAKE_BUILD_TYPE=Release` exactly once.
- Second run (idempotency): identical output to the first — no duplicate `-DCMAKE_BUILD_TYPE`,
  no re-suffixed `.exe.exe`.
- Drift case: blank out the fixture (or remove the `flatcc_ep` block) → the script exits non-zero
  with an actionable message, not a silent no-op.
- A file that already carries `flatbuffers_ep`'s `.exe` suffix but not `flatcc_ep`'s (the
  REAL current state of `third-party/CMakeLists.txt` before this change) is handled correctly —
  this is the regression case the whole fix exists for, so it gets its own fixture variant or
  assertion distinguishing "already partially patched" from "not patched."

`scripts/classify-gate.sh`'s "full" trigger regex gains
`scripts/patch-et-windows-byproducts\.sh` alongside the existing `patch-et-sources\.sh` entry —
same reasoning as every other entry in that list: this script runs only as part of a full Windows
build, so an edit routed to tier1/tier2 would never exercise it. `extras-gate.yml`'s `paths:`
filter gains the same path, for the same reachability reason `patch-et-sources.sh` is already
there (a rule that never starts the workflow is dead). `test/classify_gate.test.sh`'s two
existing for-loops (the "full-surface change forces full" loop and the "workflow triggers on"
reachability loop) both gain this path as one more entry — no new test file needed there, just
extending the existing lists.

## 4. CI matrix changes

`release.yml`'s `build-windows` job:

```yaml
strategy:
  fail-fast: false
  matrix:
    variant: [logging, devtools]
    platform: [windows-x86_64, windows-x86_64-static]
```

(currently `variant: [logging]`). No other change to that job — `Package`, `Relocatability
smoke`, and `CRT consistency scan` steps are already variant-generic (they read
`matrix.variant`/`matrix.platform` as opaque strings, no hardcoded list).

`extras-gate.yml`'s `full-build-windows` job gets the identical matrix change, for the same
"green gate means release builds" reasoning documented in that job's existing comment block. Its
"Assert the OpenVINO delegate was actually built" step is unaffected (OpenVINO is enabled for
both variants already; this step doesn't branch on variant).

This doubles the Windows job count in both workflows (2 → 4 combos each). Both jobs already run
`fail-fast: false`, so a `devtools` failure won't mask a `logging` result or vice versa. No change
to runner type (`windows-2022`/`windows-latest`, no container) or to any Linux job.

## 5. What does not change

Confirmed by reading each, not assumed — all already variant/platform-generic:

- `scripts/lib/variants.sh`, `cmakeflags.sh`, `configure-base.sh`, `openvino.sh`, `naming.sh`
- `scripts/gen-pin.sh`, `discover-pin-rows.sh`, `check-windows-crt.sh`, `package.sh`,
  `gen-buildinfo.sh`
- `test/consumer/CMakeLists.txt` (the relocatability-smoke consumer target) — links `executorch`
  only on Windows, not `etdump` directly, but `find_package(executorch)` resolving at all already
  exercises every exported target in `ExecuTorchTargets.cmake`, including `etdump`/`flatccrt`; a
  broken export would fail there regardless of what the consumer links.
- `patches/et-devtools-headers.patch` (the header-install patch from #57) — the spike confirmed
  it applies and installs cleanly on Windows with no changes needed; it's platform-agnostic
  (`install(FILES ...)`/`install(DIRECTORY ...)` under `if(EXECUTORCH_BUILD_DEVTOOLS)`, no
  Windows-specific branch).
- `test/pin.test.sh`, `discover_pin_rows.test.sh` — already assert asymmetric variant coverage as
  the normal case (e.g. "Windows logging-only" is one of several fixture scenarios, not a
  hardcoded invariant the new row would violate).

## 6. Docs

- `README.md`: the "Variants" section currently doesn't scope by platform per-variant explicitly
  beyond "each release builds three variants... for `linux-x86_64`"; add a line noting `devtools`
  also ships for both Windows platforms once this lands, alongside the existing `event_tracer`
  BUILDINFO sentence added in #57.
- `docs/devtools-header-install-handover.md` §8 / header status: flip from "remains a separate,
  unstarted workstream" to done, once implemented and released.

## 7. Release

Out of scope for the implementation plan itself — same pattern as #57: cut a new tag
(`v1.4.1-3` or later, whatever `derive-version.sh` computes at the time) only after the user
explicitly approves, per this repo's tag-push-is-the-only-release-trigger convention.
