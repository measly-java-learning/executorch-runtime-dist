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
| Generator | **Ninja + MSVC** | Single-config; matches existing `build-runtime.sh` install/relocatability assumptions |
| Orchestration | **Reuse `build-runtime.sh` + `scripts/lib/*` under Git-Bash** | Keeps naming/pin/provenance SSOT; only MSVC env-activation is PowerShell, and that lives in the workflow |
| CMake preset | **`--preset windows`** (ET 1.3.1 ships it) | Symmetric with our existing `--preset linux`; supplies the platform base |
| Feature footprint | windows-preset base + spike-verified consumer overrides | Honest "consumer-parity", not byte-parity (see §6) |

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

1. **Configure with `-G Ninja --preset windows`** (symmetric with the Linux `--preset linux`).
   `common_cmake_flags` + `variant_flags` layer on top exactly as today (§5).
2. **Skip phase 2 (`build_extras`)** entirely — the `build_extras` call, the Highway license step,
   and the extras `.etnp_usdt` writer do not run (core-only).
3. **Skip Linux-only syslib normalization** (`build-runtime.sh:228-235`, the `/usr/lib64/...`
   rewrite) — the pattern cannot occur on MSVC. The generic prefix-leak rewrite (`210-218`) still runs.
4. **Toolchain-version echo:** replace `gcc/g++ --version` (`190-191`) with `cl` version on Windows.
5. **Parallelism:** `nproc` (`202`) → `${NUMBER_OF_PROCESSORS}`, or bare `cmake --build` (Ninja
   auto-detects). Extras' `108` is moot on Windows.
6. **`.etnp_usdt` sentinel:** because packaging requires it (§4), the core-only path writes
   `.etnp_usdt = n/a` so the "required, fail-loud" invariant is preserved and provenance stays complete.

Harmless no-ops on Windows: the `HOST_UID` chown trap (no `HOST_UID` in CI); `git rev-parse` for
`.et_commit` (Git-Bash has git); `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` (MSVC ignores PIC).

## 3. Relocatability on Windows — measure-first

The relocatability repair is the repo's core value-add; on Windows we treat it as **measure-first**,
not assume-clean.

- **Generic prefix-leak rewrite reused as-is:** if the configure prefix leaks into
  `lib/cmake/ExecuTorch/*.cmake`, the existing `sed` → `${PACKAGE_PREFIX_DIR}` fixes it identically.
- **`/usr/lib64` syslib normalization has no Windows analog** and is skipped — MSVC references
  system libs (`kernel32.lib`, etc.) by bare name, not absolute path.
- **Windows-specific risk to measure:** absolute paths to the VS/Windows SDK `.lib`s or the build
  tree baked into `INTERFACE_LINK_LIBRARIES` (e.g. XNNPACK's exported targets). The recipe will
  **measure and warn** (mirroring the existing "measuring relocatability" step); a Windows-specific
  rewrite is added **only if the spike shows a real leak**. See §7 spike item 4.

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

Invariant to preserve (contract C5): **one function computes the flags, two callers consume it**
(the build in `build-runtime.sh`, the recorded provenance in `package.sh:46-48`).

- **`windows.cmake` preset enables** (all `set_overridable_option`): `PROGRAM_VERIFICATION`,
  `EXECUTOR_RUNNER`, extensions `DATA_LOADER`/`EVALUE_UTIL`/`FLAT_TENSOR`/`MODULE`/`NAMED_DATA_MAP`/
  `RUNNER_UTIL`/`TENSOR`, `KERNELS_OPTIMIZED`, `KERNELS_QUANTIZED`, `XNNPACK`.
- Our `common_cmake_flags` layer (`XNNPACK`, `EXTENSION_MODULE`, `DATA_LOADER`, `TENSOR`,
  `CMAKE_BUILD_TYPE=Release`, PIC) either **matches the preset's value or is a harmless no-op** — so
  it composes cleanly, exactly as with `--preset linux`.
- `variant_flags logging` (`EXECUTORCH_ENABLE_LOGGING=ON`) is **not** set by the preset, so it stays
  cleanly our knob (identical to Linux).
- Custom ops are **absent from the windows preset**, so core-only needs no explicit
  `KERNELS_CUSTOM=OFF`; they are simply off. (Spike confirms `default.cmake` doesn't flip them on.)

Design: make the flag SSOT **platform-aware in one place** — the preset name (`windows` vs `linux`)
becomes a function of target platform, and the same layered flags feed both the build and the
recorded provenance. No divergent Windows flag list.

## 6. Feature footprint — honest consumer-parity

The two ET presets are **not feature-identical**:

- `linux` preset includes `llm.cmake` (LLM extensions), **not** quantized kernels.
- `windows` preset enables `KERNELS_QUANTIZED` + `KERNELS_OPTIMIZED`, **not** the LLM extensions.

Decision: **take the windows preset as the base; in the spike, diff the actually-installed
feature/target set against what the JVM + Python consumers link; add explicit overrides (e.g.
`EXECUTORCH_BUILD_EXTENSION_LLM=ON`, as upstream's own workflow does) only where a consumer needs
them.** This yields honest consumer-parity rather than byte-parity, and any override that survives
the spike is recorded through the same flag SSOT (§5) into BUILDINFO.

## 7. Scope boundaries & spike-gated unknowns

**In scope (v1):** `windows-x86_64`, `logging` only, core runtime + XNNPACK (+ preset's optimized/
quantized kernels), relocatable install, `.tar.gz` + `.sha256` + `BUILDINFO`, attestation, pin-row
inclusion, release upload.

**Explicitly deferred:** `extras/` LSTM custom op; USDT (Linux-only by contract); `bare`/`devtools`
variants; macOS; the LSTM round-trip gate (stays `logging`+Linux-gated); fixtures emission (already
x86_64-Linux-only, unchanged).

**Spike (first task of the implementation plan) resolves:**

1. ~~Does ET 1.3.1 ship a `windows` preset?~~ **Resolved:** yes (`tools/cmake/preset/windows.cmake`).
2. Does the core (no-pybindings) build need `torch` at configure/codegen time on Windows? (If not,
   trim `torch` install on the Windows path.)
3. Does `logging` compile clean on MSVC with `--preset windows` + our layered flags?
4. What (if anything) leaks into `lib/cmake` on Windows — does §3 need a Windows-specific rewrite?
5. Consumer feature diff (§6): which overrides, if any, are actually required?

The plan front-loads the spike because items 2–5 could shift specifics of §2/§3/§5/§6.

## Reuse summary

| Component | Windows treatment |
|---|---|
| `naming.sh`, `gen-pin.sh`, `derive-version.sh`, `gen-buildinfo.sh` | Reused verbatim |
| `variants.sh` (`logging`) | Reused verbatim |
| `cmakeflags.sh` / preset selection | Made platform-aware in one place (§5) |
| `build-runtime.sh` | OS-guarded Windows branch (§2); phase 2 skipped |
| `package.sh` | Two SSOT parameterizations (§4) |
| Relocatability repair | Generic rewrite reused; syslib step skipped; measure-first (§3) |
| `release.yml` | New `build-windows` job (§1). `pin` → filesystem discovery is a **separate prerequisite work item**, assumed in place here |
