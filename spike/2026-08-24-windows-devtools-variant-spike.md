# Spike: does the `devtools` variant compile under MSVC? (Windows devtools rows)

**Status:** run — **green, after two upstream-file fixes.** `devtools` compiles under MSVC
(`windows-x86_64`/MD) once `third-party/CMakeLists.txt`'s `flatcc_ep` `ExternalProject_Add` is
patched. Connectivity to `winbox` was transient in the first attempt (timed out once, worked on
retry) — not a real network blocker.
**Host:** `winbox` (VS 18 / MSVC 19.51, Ninja, cmake, Git-Bash) — same host as
`spike/2026-08-22-windows-optimized-ops-spike.md`.
**Type:** throwaway. Nothing built here ships.

## The question

`docs/devtools-header-install-handover.md` §8 proposes publishing `devtools` tarballs for
`windows-x86_64` / `windows-x86_64-static`, gating all engine-side Windows profiling work. Before
designing that release-matrix change, does ExecuTorch's `devtools` subtree — `-DEXECUTORCH_BUILD_DEVTOOLS=ON
-DEXECUTORCH_ENABLE_EVENT_TRACER=ON` (`scripts/lib/variants.sh`), pulling flatcc codegen
(`flatcc_cli`), the `etdump`/`flatccrt`/`bundled_program` targets, and now also our own
`patches/et-devtools-headers.patch` header install — actually configure and compile under MSVC at
the `v1.4.1` pin? This repo has one prior data point (the optimized-kernels spike) where an
ET flag exercised only on upstream's Linux CI silently failed to compile under MSVC; nothing
establishes `devtools` is different.

**No code change is required to probe this.** Unlike the optimized-kernels spike,
`--variant devtools --platform windows-x86_64` is already a valid combination in `main` —
`variant_flags`/`et_configure_base` compose generically — so the spike is purely "attempt the
existing build," no scratch branch, no bundle transport.

## Scope

One CRT flavor only (`windows-x86_64`, /MD) — the cheap one first, per the prior spike's finding
that if a flag breaks MSVC at all it breaks at either CRT; a second flavor only tells us something
new about CRT-object mismatches, which is orthogonal to "does this subtree compile." If Step 3
below is green, the /MT flavor (`windows-x86_64-static`) and the packaging/header-guard/CRT-scan
gates are worth running before committing to a design, since they exercise the recently-landed
`patches/et-devtools-headers.patch` (header install) and `event_tracer` BUILDINFO plumbing.

## Procedure (ssh-driven, from a workstation that can reach winbox)

This sandbox has no route to `winbox` — the commands below must be run from a workstation with
network access to it (the same one the optimized-kernels spike used), or pasted output relayed
back for interpretation. `$Dist` = the existing `executorch-runtime-dist` clone on winbox; `$EtSrc`
= the existing ExecuTorch checkout (leaf dir named exactly `executorch`).

### Step 0 — pin the workspace

```powershell
git -C $Dist fetch origin
git -C $Dist checkout main
git -C $Dist reset --hard origin/main
git -C $Dist log --oneline -1                          # expect 91fca18 (devtools headers, #57) or later
git -C $EtSrc describe --tags                           # expect v1.4.1
git -C $EtSrc status --porcelain                        # expect: nothing
git -C $EtSrc submodule foreach --recursive "git status --porcelain"   # expect: nothing
```

If `$EtSrc` is dirty, force it pristine: `checkout -f v1.4.1`, `clean -fd`,
`submodule update --init --recursive --force`,
`submodule foreach --recursive "git checkout -f; git clean -fd"`.

Delete stale prefixes/build trees so a reused CMake cache cannot paper over the answer:
remove `$Dist/out-devtools-md` and `$Dist/et-build-devtools-md` if they exist from a prior attempt.

### Step 1 — dry-run the flags (cheap, no build)

```powershell
Set-Location $Dist
& ./build-runtime.ps1 ./build-runtime.sh --print-flags --variant devtools --platform windows-x86_64
```

Expect `-DEXECUTORCH_BUILD_DEVTOOLS=ON` and `-DEXECUTORCH_ENABLE_EVENT_TRACER=ON` present exactly
once, alongside the existing Windows base flags. This just confirms flag composition; it proves
nothing about compilation.

### Step 2 — build (`windows-x86_64`, /MD)

Driver `step2-build-devtools-md.ps1`, staged on winbox, invoked per the execution-model rules in
the prior spike (no inline `-Command` strings, no detached `Start-Process`, hold one ssh call open
for the build's ~15-25 min duration, tee to a log, poll the log with short separate calls):

```powershell
param([Parameter(Mandatory)][string]$Dist, [Parameter(Mandatory)][string]$EtSrc)
$ErrorActionPreference = 'Stop'
Set-Location $Dist
& "$Dist/build-runtime.ps1" "$Dist/build-runtime.sh" --variant devtools `
    --prefix "$Dist/out-devtools-md" --et-src $EtSrc --build-dir "$Dist/et-build-devtools-md" `
    --platform windows-x86_64
exit $LASTEXITCODE
```

Invoke it teed to a log:

```powershell
ssh winbox 'pwsh -NoProfile -File <staging>/step2-build-devtools-md.ps1 -Dist <dist> -EtSrc <etsrc> 2>&1 | Tee-Object <dist>/spike-devtools-md.log; exit $LASTEXITCODE'
```

A failure here **is** the finding — stop and record the first error and surrounding context
verbatim in this file's Findings section below. Things to watch for specifically:

- **flatcc codegen** (`flatcc_cli -cwr -o ...` in `devtools/etdump/CMakeLists.txt`) — a host tool
  built during the same configure; failing here would be a new failure mode, not the
  C++20-designated-initializer class the optimized-kernels spike found.
- **`bundled_program`** and **`etdump_flatcc.cpp`** — C++ compiled against MSVC; watch for the same
  class of upstream C++20-vs-MSVC-C++17 incompatibility as the optimized-kernels spike
  (`c10/util/StringUtil.h` C7555, `c10/core/AutogradState.h` C7582) — `etdump`/`bundled_program`
  do not depend on torch's c10, so that specific defect should not recur, but any comparable
  MSVC-rejects-upstream-C++20 pattern is the thing to look for.
- **our own header-install patch** (`patches/et-devtools-headers.patch`) — confirm it reports
  `applied` (pristine tree) during this run, not `already patched` or a failure.

### Step 3 — assert the install (only if Step 2 is green)

```powershell
Get-ChildItem $Dist/out-devtools-md/lib/etdump.lib, $Dist/out-devtools-md/lib/flatccrt.lib
Get-ChildItem $Dist/out-devtools-md/include/executorch/devtools/etdump/etdump_flatcc.h
Get-ChildItem $Dist/out-devtools-md/include/executorch/devtools/etdump/data_sinks/buffer_data_sink.h
Get-ChildItem $Dist/out-devtools-md/include/flatcc/flatcc_builder.h
Select-String -Path $Dist/out-devtools-md/lib/cmake/ExecuTorch/ExecuTorchTargets.cmake -Pattern "add_library.*etdump"
```

All five must be present/match. The header-install patch was written and tested hermetically
(`test/patch_et_sources.test.sh`) against a pristine ET tree, but nothing so far has proven it
survives a real MSVC `cmake --install` — that's what this step is for.

### Step 4 — package + event_tracer/header guard (only if Step 3 passes)

```powershell
Set-Location $Dist
& ./build-runtime.ps1 -Command 'set -euo pipefail; ./scripts/package.sh --prefix "$PWD/out-devtools-md" --etver 1.4.1 --variant devtools --platform windows-x86_64 --package-tag v1.4.1-spike --outdir "$PWD/dist" --toolchain msvc-2022'
```

Expect success (not the "devtools prefix missing header" hard error added by
`scripts/package.sh`'s guard). Then:

```powershell
tar -xzOf $Dist/dist/executorch-runtime-1.4.1-devtools-windows-x86_64.tar.gz executorch-runtime-1.4.1-devtools-windows-x86_64/BUILDINFO | Select-String event_tracer
```

Expect `event_tracer=on`.

## Findings

Ran Steps 0-4 (single CRT flavor, `windows-x86_64`/MD only — /MT not attempted; see *Scope*
above for why one flavor answers the compile-feasibility question). `$Dist` was at `91fca18`
(post-#57), `$EtSrc` at pristine `v1.4.1` plus the repo's existing idempotent patches.

**First attempt failed at configure→build with two distinct, previously-unexercised MSVC defects
in ET's `third-party/CMakeLists.txt`'s `flatcc_ep` `ExternalProject_Add` — nothing in either fix
touches this repo's own `devtools/etdump/CMakeLists.txt` header-install patch
(`patches/et-devtools-headers.patch`), which applied and installed cleanly on the first try.**
Neither defect is the C++20-vs-MSVC-C++17/c10 class the optimized-kernels spike found —
`etdump`/`bundled_program` do not depend on torch's c10, and no such error occurred anywhere in
this run.

1. **Missing `.exe` on `flatcc_ep`'s `BUILD_BYPRODUCTS`** (`third-party/CMakeLists.txt:128`,
   `BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc`). This repo's `build-runtime.sh` already sed-patches
   the *sibling* `flatbuffers_ep`'s byproduct (`BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc` →
   `flatc.exe`, added for the Windows relocatability work) with an anchored regex
   (`s#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)$#\1.exe#`). That anchor does **not** match
   `.../bin/flatcc` (the `$` anchors immediately after `flatc`, and `flatcc` has one more
   character before end-of-line), so the second declaration was never touched. Nothing exercised
   `flatcc_ep` on Windows before this spike — it is only reached when `devtools` is enabled — so the
   gap was invisible. First symptom: `ninja: error: 'third-party/flatcc_ep/bin/flatcc.exe', needed
   by '...etdump_schema_flatcc_builder.h', missing and no known rule to make it`.

   **Fix (verified live):** broaden the existing sed's pattern to make the trailing `c` optional —
   `s#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)c\?$#\1c.exe#` is wrong (loses idempotency
   framing); the concrete edit applied on winbox was a second, parallel `-replace` targeting
   `BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc$` → `...flatcc.exe`. **The plan should express this as
   one generalized sed** (`bin/flatc` optionally followed by a second `c`, i.e. matching both
   `flatc` and `flatcc`) rather than two near-duplicate `sed -i` lines, to keep
   `build-runtime.sh`'s comment ("upstream flatc byproduct bug") accurate for both targets.

2. **`flatcc_ep` never passes `-DCMAKE_BUILD_TYPE=Release`, so its single-config Ninja sub-build
   defaults to a debug-postfixed binary** (`flatcc_d.exe`), which does not match the
   `IMPORTED_LOCATION` (`${INSTALL_DIR}/bin/flatcc.exe`) ET's `add_executable(flatcc_cli IMPORTED
   GLOBAL)` declares — even after fix 1 makes the *byproduct declaration* say `.exe`, the actual
   built file is still named `flatcc_d.exe`. This is asymmetric with the neighboring
   `flatbuffers_ep`: ET's own comment there says "flatbuffers does not use CMAKE_BUILD_TYPE.
   Internally, the build forces Release config" — `flatcc` has no such internal forcing.
   Symptom (only visible after fix 1 stopped ninja from refusing to run the rule at all): `'...\\
   third-party\\flatcc_ep\\bin\\flatcc.exe' is not recognized as an internal or external command`,
   because that file never gets built — only `flatcc_d.exe` does.

   **Fix (verified live):** add `-DCMAKE_BUILD_TYPE=Release` to `flatcc_ep`'s `CMAKE_ARGS` block in
   `third-party/CMakeLists.txt` (inserted after `-DFLATCC_INSTALL=ON`). After this plus fix 1, a
   clean reconfigure of just the `flatcc_ep` external-project subtree (deleting its stamp/build
   dirs under `$BUILD_DIR/third-party/flatcc_ep`) produces `flatcc.exe` and the build proceeds.

**End-to-end result after both fixes, from a from-scratch reconfigure of just the `flatcc_ep`
subtree** (the rest of the build tree was reused incrementally): `build-runtime.sh --variant
devtools --platform windows-x86_64` completed with exit 0. Verified on the installed prefix
(`out-devtools-md`):

| Check | Result |
|---|---|
| `lib/etdump.lib`, `lib/flatccrt.lib` | present |
| `include/executorch/devtools/etdump/etdump_flatcc.h` | present |
| `include/executorch/devtools/etdump/data_sinks/{buffer_data_sink,data_sink_base}.h` | present |
| `include/flatcc/flatcc_builder.h` | present |
| `lib/cmake/ExecuTorch/ExecuTorchTargets.cmake` declares `add_library(etdump STATIC IMPORTED)` | yes |
| `scripts/package.sh --variant devtools --platform windows-x86_64 --toolchain msvc-2022` | succeeds — the devtools-header packaging guard does not fire (header present) |
| packaged `BUILDINFO` | `event_tracer=on`, `variant=devtools`, `platform=windows-x86_64`, `openvino_version=2025.4.1`, `usdt=n/a` — all as expected for a Windows devtools tarball |

Not measured this run (left for the implementation plan / real CI, since none of it bears on
feasibility): C4530 exception-boundary warning count (the optimized-kernels spike's metric for
whether `/EHsc` scoping is worth revisiting — devtools' codegen'd flatcc code plus
`etdump_flatcc.cpp`'s use of `ETDUMP_VERSION`/status codes is a plausible new source of these,
unconfirmed), the `windows-x86_64-static` (/MT) flavor (flatcc_ep is a host-tool external project
with its own isolated CMAKE_ARGS that do not inherit `CMAKE_MSVC_RUNTIME_LIBRARY` from the parent
configure, so CRT should not affect whether it builds — but this is inference, not measurement),
and Windows extras (`build-runtime.sh` skips phase 2 on Windows unconditionally, `devtools`
included — unrelated to and unaffected by this spike).

**Bottom line: `devtools` on Windows is buildable, gated on exactly two small, well-understood
upstream-file fixes to `third-party/CMakeLists.txt`'s `flatcc_ep` block** (same file this repo
already patches with an inline `sed` in `build-runtime.sh`, not a `patches/*.patch` — precedent
favors extending that sed over a new git patch, since both fixes target the same
`ExternalProject_Add` this repo already reaches into). No devtools-specific MSVC/C++20
incompatibility was found. This unblocks designing the release-matrix change with the two fixes
as a known, scoped prerequisite rather than an open risk.

## Afterwards

**Green run:** no branch to delete (none was created). `$Dist/out-devtools-md`,
`$Dist/et-build-devtools-md`, `$Dist/dist/*devtools*windows*`, and the scratch drivers
(`spike-step-package.sh`, `spike-debug.sh`, `spike-devtools-md.log`) are **still on winbox as of
this writing** — deliberately not cleaned up yet, since the implementation plan's flatcc_ep sed
fix should be verified by reconstructing this exact result before the host is reset. `$EtSrc`
still carries the two live edits to `third-party/CMakeLists.txt` (the `.exe` byproduct fix and the
`-DCMAKE_BUILD_TYPE=Release` addition) alongside the repo's other pre-existing idempotent patches
— these are NOT committed anywhere; they exist only in winbox's `$EtSrc` working tree and must be
re-expressed as a `build-runtime.sh` sed change before they take effect for anyone else. Whoever
picks up the implementation plan should not assume a clean host.

**Failing run:** keep `$Dist/et-build-devtools-md` (CMakeCache, compile_commands.json, .ninja_log),
`$Dist/spike-devtools-md.log`, and `$Dist/out-devtools-md` (even partial) exactly as the prior
spike's *Afterwards* section prescribes — the failing command line and its real include order are
only recoverable from the build tree, and re-issuing one command against the failed tree is the
cheapest diagnostic loop available. Do not re-pristine `$EtSrc`.
