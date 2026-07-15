# Windows (amd64) artifacts — design

**Date:** 2026-07-15
**Status:** Approved (design); implementation plan to follow
**Scope:** Add `windows-x86_64` release artifacts to the ExecuTorch runtime build/package/CI pipeline.

## Goal

Produce attested, hash-pinned, relocatable ExecuTorch runtime tarballs for **Windows amd64**,
consumable by the same two downstream paths that already consume the Linux artifacts: a
**JNI/JVM** consumer and a **Python package**, both of which `find_package(ExecuTorch)` against
the extracted prefix.

## Scope decisions (settled during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Purpose | Consumer parity (JNI/JVM + Python pkg) | Same consumption story as Linux, MSVC-flavored |
| `extras/` (LSTM custom op) | **Out of v1** (core-only) | Upstream disables custom ops on MSVC; USDT is Linux-only. Highest-risk surface deferred |
| Variants | **`logging` only** | Ship default; add `bare`/`devtools` later once the pipeline is proven |
| Runner / toolchain | GitHub-hosted `windows-2022`, preinstalled tools | Image ships Python, CMake, Ninja, VS Enterprise 2022 — no conda, no external actions |
| Generator | **Ninja + MSVC** | Single-config; matches existing `build-runtime.sh` install/relocatability assumptions. **Spike-confirmed working at C++17.** |
| Orchestration | **Reuse `build-runtime.sh` + `scripts/lib/*` under Git-Bash** | Keeps naming/pin/provenance SSOT; only MSVC env-activation is PowerShell, and that lives in the workflow |
| CMake configure base | **Flat `-D` flags, NOT `--preset windows`** | Spike: the `windows` preset pins `toolset: ClangCL` + the VS generator, incompatible with Ninja/MSVC. Use the flat flag list (§5). |
| Feature footprint | **Mirror the Linux footprint; omit `KERNELS_OPTIMIZED`/`QUANTIZED`** | Spike: those are the only targets pulling torch `c10` headers (which break MSVC), and Linux ships neither. Torch-free, C++17 (see §6). |

> **Spike outcome (2026-07-15, see `spike/windows-msvc-spike.md`):** a torch-free single-config
> **Ninja + MSVC** build succeeds end-to-end (configure → build 1353/1353 → install) at **C++17** on
> VS 18 / MSVC 19.51, producing a coherent runtime (`executorch(_core)`, `portable_kernels`,
> XNNPACK backend, full `extension_*` set). Three corrections below (§2/§5/§6) and one new
> load-bearing ET source patch (flatc, §2) came out of it; the spike (plan Task 1) is retired.

## 1. CI topology

Aligns with the pre-existing Windows plan sketched in `release.yml:99-105`.

- **New separate `build-windows` job** on `runs-on: windows-2022`, **no `container:`** (the Linux
  matrix bakes a manylinux container into every `PLATFORMS` entry; Windows can't use it). Matrix is
  trivial: `variant: [logging]`. Recipe steps run under `shell: bash` (Git-Bash); a single
  `shell: pwsh` step activates MSVC (§2).
- Uploads via the **existing `dist-${variant}-${platform}` artifact pattern**, platform string
  **`windows-x86_64`** — nothing downstream of upload needs Windows awareness.
- **`pin` job switches from `$PLATFORMS`-driven to filesystem discovery.** The current job loops a
  hardcoded `platform × {bare,logging,devtools}` (`release.yml:123-128`) and would fail looking for
  nonexistent `windows bare/devtools` shas. New behavior: discover the actual `*.tar.gz.sha256`
  files present in the merged `dist/` and emit one pin row per discovered `(variant, platform)`.
  This is required for a heterogeneous matrix and makes the pipeline genuinely data-driven for
  future platforms.
  **This is extracted as a separate, prerequisite work item** (its own spec → plan → PR): it is a
  self-contained change to the existing Linux path that produces the same set of pin rows
  (order-independent) for today's Linux-only matrix, so it can land and be verified by an ordinary Linux release *before* any
  Windows job exists. The Windows plan below **assumes filesystem-discovery pin is already in
  place** and does not modify the `pin` job itself. Keeps each PR reviewable in isolation
  (refactor-shipping-behavior vs. add-a-platform).
- **Release notes** drop the hardcoded `manylinux` string; toolchain provenance becomes per-artifact
  via `BUILDINFO` (§4).

Everything from `attest` onward (attestation, upload-artifact, release) reuses the existing Linux
steps unchanged.

## 2. `build-runtime.sh` — Windows path

A small, OS-guarded branch (`case "$(uname -s)" in MINGW*|MSYS*)`), not a rewrite.

**MSVC activation (workflow, not recipe):** one `pwsh` step runs `Enter-VsDevShell` (via the
preinstalled VS's `Microsoft.VisualStudio.DevShell.dll`) and, in that same activated session,
invokes `build-runtime.sh`, so `cl.exe` + the MSVC environment propagate into Git-Bash. No external
action, no install.

**Recipe deltas on Windows:**

1. **Configure with `-G Ninja` + the flat Windows flag list** (NOT `--preset windows` — the preset
   pins ClangCL + the VS generator, spike finding 1). The flag list is the windows-preset feature
   set **minus** `KERNELS_OPTIMIZED`/`QUANTIZED` (§5/§6). `common_cmake_flags` + `variant_flags`
   still layer on top. No `-DCMAKE_CXX_STANDARD` needed — C++17 (the default) compiles clean once
   the optimized kernels are off.
2. **Apply the `flatc_ep` `.exe` byproduct patch (Windows only) — a second load-bearing ET source
   patch** alongside the existing #20709 install-dest patch. `third-party/CMakeLists.txt:56` declares
   `BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc` without `.exe`, but the WIN32 consumer imports
   `bin/flatc.exe`; Ninja then has "no known rule" for the schema-gen dependency and the build fails.
   The recipe `sed`-patches the byproduct to `bin/flatc.exe` on Windows (idempotent, mirrors the
   #20709 patch pattern). This is to be **filed upstream** — the plan produces an issue-draft markdown.
3. **Skip phase 2 (`build_extras`)** entirely — the `build_extras` call, the Highway license step,
   and the extras `.etnp_usdt` writer do not run (core-only).
4. **Skip Linux-only syslib normalization** (`build-runtime.sh:228-235`, the `/usr/lib64/...`
   rewrite) — the pattern cannot occur on MSVC. The generic prefix-leak rewrite (`210-218`) still runs.
5. **Toolchain-version echo:** replace `gcc/g++ --version` (`190-191`) with `cl` version on Windows.
6. **Parallelism:** `nproc` (`202`) → `${NUMBER_OF_PROCESSORS}`, or bare `cmake --build` (Ninja
   auto-detects). Extras' `108` is moot on Windows.
7. **`.etnp_usdt` sentinel:** because packaging requires it (§4), the core-only path writes
   `.etnp_usdt = n/a` so the "required, fail-loud" invariant is preserved and provenance stays complete.

Harmless no-ops on Windows: the `HOST_UID` chown trap (no `HOST_UID` in CI); `git rev-parse` for
`.et_commit` (Git-Bash has git); `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` (MSVC ignores PIC).

## 3. Relocatability on Windows — measured, near-clean

The relocatability repair is the repo's core value-add. **Spike result:** the installed
`lib/cmake/ExecuTorch/*.cmake` is near-clean — **19/20** exported target locations are correct; the
**only** leak is `extension_evalue_util`, whose `IMPORTED_LOCATION_RELEASE` points at the **build
tree**. **No** torch / VS-SDK / `Program Files` / install-prefix leaks.

- **Generic prefix-leak rewrite reused as-is** for any leaked configure prefix → `${PACKAGE_PREFIX_DIR}`.
- **`/usr/lib64` syslib normalization has no Windows analog** and is skipped — MSVC references
  system libs (`kernel32.lib`, etc.) by bare name, not absolute path.
- **The one leak (`extension_evalue_util` → build tree) is NOT Windows-specific.** Its
  `extension/evalue_util/CMakeLists.txt:27` already uses the correct `DESTINATION
  ${CMAKE_INSTALL_LIBDIR}`, so it is a *different* export-path quirk than the `${CMAKE_BINARY_DIR}/lib`
  bug the recipe patches — and Linux builds `evalue_util` too, so it is a shared (pre-existing)
  concern, not a new Windows blocker. The recipe keeps its **measure-and-warn** step so any build-tree
  or prefix leak is loud; handling `evalue_util` (if needed) is a shared implementation item, not
  Windows-gating.

## 4. Packaging — two surgical SSOT changes

`package.sh` needs two parameterizations, both preserving single-source-of-truth (no Windows fork):

1. **`.etnp_usdt` requirement (`package.sh:33-34`).** Written only by the extras install, so a
   core-only build has none and `package.sh` would FATAL. Fix: the build always writes the sentinel
   (`n/a` for core-only) — chosen over relaxing package.sh so the "required, fail-loud" invariant and
   complete BUILDINFO are preserved.
2. **`TOOLCHAIN` hardcoded** `"manylinux_2_28 gcc-toolset-14"` (`package.sh:49`). Parameterize (env or
   `--toolchain`) so Windows records e.g. `"msvc-2022"` (exact detected VS version). This is what lets
   release notes stop hardcoding `manylinux`.

Unchanged and reused: **`.tar.gz` stays the wire format** (cmake `FetchContent` extracts `.tar.gz` on
Windows; Git-Bash and Windows both ship `tar`/`sha256sum`), so **`naming.sh` needs no change** —
`windows-x86_64` is just a new platform-string value. `gen-pin.sh`, `derive-version.sh`,
`gen-buildinfo.sh` are platform-agnostic and reused verbatim.

## 5. Flag SSOT + provenance consistency

Invariant to preserve (contract C5): **one function computes the platform base, two callers consume
it** (the build in `build-runtime.sh`, the recorded provenance in `package.sh:46-48`).

Because the `windows` preset is unusable (finding 1), Linux and Windows differ in their **configure
base**, not just a preset name:
- **Linux base:** `--preset linux` (unchanged).
- **Windows base (flat, spike-validated):**
  ```
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON
  -DEXECUTORCH_BUILD_XNNPACK=ON
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON
  -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON
  -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON
  # NO KERNELS_OPTIMIZED, NO KERNELS_QUANTIZED (finding 3)
  ```
  This is the windows-preset feature set minus the two kernel options. `EXTENSION_MODULE` **requires**
  `EXTENSION_NAMED_DATA_MAP` (ET preset validation), so the full extension set is kept together.

- `variant_flags logging` (`EXECUTORCH_ENABLE_LOGGING=ON`) layers on both, unchanged — it's our knob.
- `common_cmake_flags` overlaps the Windows base (XNNPACK, extensions, build-type, PIC) with identical
  values, so re-applying it is harmless.

Design: make the flag SSOT **platform-aware in one place** — a single function returns the *configure
base* per platform (`--preset linux` vs the flat Windows list above), and the same base + layered
`variant`/`common` flags feed **both** the build and the recorded `BUILDINFO` provenance. (This
supersedes the earlier `et_preset` name-only idea, since Windows has no usable preset.)

## 6. Feature footprint — resolved: omit optimized/quantized kernels

**Spike-resolved.** Enabling `KERNELS_OPTIMIZED`/`QUANTIZED` (as the windows preset does) is what
pulls torch's `c10` headers into the kernel targets (`kernels/portable/CMakeLists.txt:70`,
`kernels/optimized/CMakeLists.txt:64` add `${TORCH_INCLUDE_DIRS}` + `ET_USE_PYTORCH_HEADERS`), and
MSVC rejects those headers two ways GCC tolerates:
- `c10/util/StringUtil.h: error C7555: designated initializers require '/std:c++20'`
- `op_add.cpp: error C2672: 'apply_bitensor_elementwise_fn': no matching overloaded function`

Our **Linux** build does **not** enable these kernels, so **omitting them on Windows is both the
MSVC fix and true footprint parity** — no divergence to reconcile, no C++20, and the artifact stays
**torch-free** (torch is used only as codegen tooling, not compiled in). The base
`portable_kernels`/`portable_ops_lib` still build, so the runtime remains functional. If a consumer
later needs optimized kernels, that's a follow-up requiring the torch-header/MSVC work (out of v1).

## 7. Scope boundaries & spike-gated unknowns

**In scope (v1):** `windows-x86_64`, `logging` only, core runtime + XNNPACK + base portable kernels
(**no** optimized/quantized kernels), relocatable install, `.tar.gz` + `.sha256` + `BUILDINFO`,
attestation, pin-row inclusion, release upload.

**Explicitly deferred:** `extras/` LSTM custom op; USDT (Linux-only by contract); `bare`/`devtools`
variants; macOS; the LSTM round-trip gate (stays `logging`+Linux-gated); fixtures emission (already
x86_64-Linux-only, unchanged); optimized/quantized kernels (would require torch-header/MSVC work).

**Spike — RESOLVED (2026-07-15, `spike/windows-msvc-spike.md`):**

1. ~~ET `windows` preset?~~ Exists but **unusable** — pins ClangCL + VS generator → flat flags (§5).
2. ~~torch at configure?~~ Needed only as codegen tooling; artifact is **torch-free** once optimized
   kernels are off. Keep the `torch` install for parity (§2 unchanged on that point).
3. ~~`logging` compiles on MSVC?~~ **Yes**, Ninja + MSVC, **C++17**, torch-free (§6).
4. ~~`lib/cmake` leaks?~~ One non-Windows-specific leak (`extension_evalue_util` → build tree); no
   torch/SDK/prefix leaks (§3).
5. ~~Consumer feature diff / overrides?~~ Base set (no optimized/quantized) matches Linux; no
   overrides needed for v1 (§6).

Plus a build blocker not on the original list: the **`flatc_ep` `.exe` byproduct bug** on
Ninja/Windows → new load-bearing recipe patch, to be filed upstream (§2).

## Reuse summary

| Component | Windows treatment |
|---|---|
| `naming.sh`, `gen-pin.sh`, `derive-version.sh`, `gen-buildinfo.sh` | Reused verbatim |
| `variants.sh` (`logging`) | Reused verbatim |
| `cmakeflags.sh` / configure base | Platform-aware in one place: `--preset linux` vs flat Windows flag list (§5) |
| `build-runtime.sh` | OS-guarded Windows branch (§2); flat flags; **new flatc `.exe` byproduct patch**; phase 2 skipped |
| `package.sh` | Two SSOT parameterizations (§4) |
| Relocatability repair | Generic rewrite reused; syslib step skipped; measured near-clean (§3) |
| Upstream issue draft | Plan produces a markdown to file the flatc byproduct bug upstream (like #20709) |
| `release.yml` | New `build-windows` job (§1). `pin` → filesystem discovery is a **separate prerequisite work item**, assumed in place here |
