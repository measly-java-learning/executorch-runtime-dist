# macOS (arm64) artifacts — design

**Date:** 2026-11-27
**Status:** Approved; spike done (go). Tasks 1 (#67) and 3–7 implemented. The plan is
`docs/superpowers/plans/2026-11-27-macos-arm64-artifacts.md`.
**Scope:** Add `macos-arm64` release artifacts to the ExecuTorch runtime build/package/CI pipeline.

## Goal

Produce attested, hash-pinned, relocatable ExecuTorch runtime tarballs for **macOS on Apple
silicon**. Downstream consumers (JNI/JVM and Python packages) should consume them exactly as they
consume the Linux tarballs: pull `EtRuntimePin.cmake`, `FetchContent` the pinned tarball, then
`find_package(ExecuTorch)` against the extracted prefix.

## Scope decisions

| Decision | Choice | Rationale |
|---|---|---|
| Platform string | **`macos-arm64`** | Follows `<os>-<arch>`. `discover-pin-rows.sh` splits on the first `-` after the variant, so the platform needs no special handling. |
| Architectures | **arm64 only** | Native on the dev Mac and on GitHub's `macos-15` runners. GitHub is retiring its Intel macOS runners, so an x86_64 slice would be cross-compiled and its gates couldn't run natively. No universal2. |
| Minimum macOS | **14.0** (`CMAKE_OSX_DEPLOYMENT_TARGET`) | This is the target upstream's `macos` preset uses, so it's the one ET is actually tested at. |
| Configure base | **Flat `-D` flag list, Linux feature parity** (not `--preset macos`, not `--preset llm`) | See §2. |
| Variants | **`bare`, `logging`, `devtools`** | All three, as on Linux. They differ only in a few flags. |
| `extras/` (LSTM op) | **In.** Built and gated, as on Linux | The op is torch-free C++ plus Highway. `ETNPExtras.cmake` already has an `APPLE` → `-force_load` arm. |
| USDT probes | **Out** (`usdt=n/a`) | The probes are SystemTap/ELF notes. DTrace USDT on macOS is a possible follow-up, but it's a separate probe ABI and would need its own contract. |
| OpenVINO | **Out** | `ov_enabled_for_platform` already returns false for anything except linux-x86_64 and Windows. No bundle and no pin row, which `gen-pin.sh` already supports (same as linux-aarch64). |
| CoreML / MLX / Metal | **Out** | Not part of Linux parity. CoreML adds Apple framework link deps and a new backend to gate. MLX needs full Xcode. Possible follow-up. |
| Build host | **No container.** Native `macos-15` runner, Apple Clang from Xcode/CLT, Python 3.12 venv | Docker can't produce Mach-O binaries. |
| Orchestration | **Reuse `build-runtime.sh` + `scripts/lib/*`**, behind an OS guard | Same approach Windows took: the SSOT libraries keep naming, flags, provenance and pin consistent. |

## 1. Why this isn't just a new row in `env.PLATFORMS`

`env.PLATFORMS` drives the **manylinux container** matrix: every entry runs inside the pinned
`.build-image`. macOS can't run that container, so it gets its own `build-macos` job, as Windows did.
The `release.yml` comment above `build-windows` already planned for this ("macOS remains future
work and would follow this job's pattern"). Uploads use the existing `dist-<variant>-<platform>`
artifact naming, and `pin` already discovers rows from the filesystem, so nothing downstream of
upload needs to know about macOS beyond adding the job to `pin`'s `needs`.

## 2. Configure base: a flat flag list

`et_configure_base macos-arm64` returns a flat list, not a preset, because both candidate presets
pull in things we don't want:

- **`--preset macos`** sets `CMAKE_TOOLCHAIN_FILE=third-party/ios-cmake/ios.toolchain.cmake` and
  includes `apple_common.cmake`. That turns on CoreML, MLX (when `metal` is found), the Objective-C
  `EXTENSION_APPLE`/`ETDUMP_APPLE`/`LLM_APPLE` extensions, `KERNELS_TORCHAO`, `EXTENSION_IMAGE` and
  `XNNPACK_ENABLE_WEIGHT_CACHE`. It also forces `EXECUTORCH_ENABLE_EVENT_TRACER ON`, which would make
  `bare`/`logging` silently ship the event tracer.
- **`--preset llm`** (what `--preset linux` includes) turns on `EXECUTORCH_BUILD_COREML` and, on
  arm64, `KERNELS_TORCHAO` when `CMAKE_SYSTEM_NAME` is Darwin. We could override both with `-D...=OFF`,
  but the next ET bump could add another Darwin-only `ON` that we would then ship without noticing.
  A flat list fails closed: a new upstream feature stays off until someone decides to turn it on.

The list is the Linux effective feature set at the v1.5.1 pin (`linux.cmake` + `llm.cmake`, Linux
branch), plus the Apple target settings:

```
-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON
-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON -DEXECUTORCH_BUILD_EXTENSION_ASR_RUNNER=ON
-DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON
-DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_LLM=ON
-DEXECUTORCH_BUILD_EXTENSION_LLM_RUNNER=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON
-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON
-DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON -DEXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON
-DEXECUTORCH_BUILD_KERNELS_QUANTIZED=ON -DEXECUTORCH_BUILD_KERNELS_LLM=ON
-DEXECUTORCH_BUILD_XNNPACK=ON
-DEXECUTORCH_BUILD_COREML=OFF -DEXECUTORCH_BUILD_MLX=OFF -DEXECUTORCH_BUILD_KERNELS_TORCHAO=OFF
```

The explicit `=OFF` lines protect against ET's top-level defaults rather than presets. They're
cheap insurance, and `--print-flags`/BUILDINFO then record the decision.

`common_cmake_flags` and `variant_flags` layer on top unchanged. `effective_cmake_flags` stays the
only composer, so the build, `--print-flags` and BUILDINFO can't diverge.

**Parity check (a new unit test):** the macOS list must contain every `EXECUTORCH_BUILD_*=ON` that
the Linux preset turns on at the pin. Linux's set comes from a preset file we don't vendor, so the
test checks a committed list, `scripts/lib/configure-base.sh:_ET_LINUX_PARITY_FEATURES`, which the
ET-bump checklist refreshes. That keeps the test hermetic.

Expected risk, to confirm in the spike: `KERNELS_OPTIMIZED` includes the torch `c10` headers that
broke MSVC at C++17. Linux GCC accepts them as an extension. Apple Clang is closer to upstream
clang, which ET's own macOS CI builds, so it should be fine, but this is the first thing the spike
checks.

## 3. `build-runtime.sh` on macOS

An `IS_MACOS` guard next to the existing `IS_WINDOWS` one. Not a rewrite.

1. **Host/platform agreement.** `--platform macos-*` on a non-Darwin host fails immediately with
   exit 2, and so does a `linux-*`/`windows-*` platform on Darwin. The default `--platform` stays
   `linux-x86_64`, so on a Mac `--platform macos-arm64` must be passed explicitly. Without this, a
   Mac build would silently use the Linux preset, whose `CMAKE_SYSTEM_NAME=Linux` condition then
   fails confusingly.
2. **Python.** No container, so there's no throwaway interpreter. Homebrew's Python is
   PEP 668-managed and `pip install` into it fails. On macOS the script requires an active venv
   (`VIRTUAL_ENV` set, or `sys.prefix != sys.base_prefix`) and fails with a one-line fix otherwise.
   CI uses `actions/setup-python` 3.12 plus a venv, so local and CI behave the same.
3. **torch spec becomes an SSOT.** `torch==2.14.0+cpu` from the CPU index exists only for Linux and
   Windows. On macOS the CPU wheel is plain `torch==2.14.0` from PyPI. A new `scripts/lib/torch.sh`
   provides `torch_pip_args <platform>` and `torch_version_for_platform <platform>`.
   `build-runtime.sh` installs through the first. `package.sh`, which currently hardcodes
   `TORCH_VERSION="2.14.0+cpu"`, records the second in BUILDINFO, so provenance matches what was
   installed.
4. **Tooling portability.** BSD userland on macOS:
   - `sed -i` → a `sed_inplace` helper in a new `scripts/lib/portable.sh`, written as
     `sed -i.etnp-bak … && rm`, which works on GNU and BSD sed. Used everywhere the recipe edits
     files in place.
   - `nproc` → `ncpu` helper: `nproc`, then `sysctl -n hw.ncpu`, then `$NUMBER_OF_PROCESSORS`. This
     replaces the three separate job-count derivations.
   - `sha256sum` exists at `/sbin/sha256sum` on macOS 14+, but the packaging scripts call a
     `sha256_file` helper that falls back to `shasum -a 256`, so nothing depends on that.
   - **bash ≥ 4 is required.** `package.sh` uses `${v,,}`, and `/bin/bash` on macOS is 3.2.
     `#!/usr/bin/env bash` picks up Homebrew's bash 5 on GitHub runners and on this Mac. Every
     entry script sources `portable.sh`, which asserts `BASH_VERSINFO[0] >= 4` and names the fix
     (`brew install bash`), so a 3.2 shell fails clearly instead of with a confusing syntax error.
5. **Toolchain banner.** `clang --version` instead of `gcc --version`. `xcrun --show-sdk-path`
   and `xcrun --show-sdk-version` are logged and recorded in the `--toolchain` string passed to
   `package.sh` (§6).
6. **Relocatability repair, macOS edition.** The prefix-leak rewrite works as is (it already runs
   on all OSes). The `/usr/lib64/lib*.so` normalization doesn't apply. Its macOS equivalent is a
   **hard-fail scan** (not a rewrite) for absolute SDK/toolchain paths in `lib/cmake`:
   `/Applications/Xcode*.app/`, `/Library/Developer/CommandLineTools/`, `*.sdk/`. Consumers have
   different Xcode installs, so a baked-in SDK path breaks their link. We expect none, since
   nothing in the feature set links a framework. If the spike finds one, it gets a targeted rewrite
   to `-framework X`/`-l<name>` with a comment, like the Linux one.
7. **`nm` guard.** Apple's `nm` is llvm-nm and accepts `-C --defined-only`. Mach-O symbols carry a
   leading `_`, but the guard already uses substring matching, so it should work unchanged. The
   spike confirms this.
8. **extras phase.** Skip the `dnf install systemtap-sdt-devel` step (it's Linux-only, so guard it
   on `IS_LINUX` rather than `!IS_WINDOWS`). `pip install pyyaml` stays.

## 4. extras on Apple

- **USDT.** `extras/CMakeLists.txt` already sets `ETNP_USDT_EFFECTIVE OFF` off Linux. Two changes:
  - The marker word for a non-Linux build becomes `n/a`, matching Windows. `off` means "USDT
    supported but disabled" (`-DETNP_ENABLE_USDT=OFF` on Linux). BUILDINFO keeps meaning that.
  - The `check-usdt-notes.sh` POST_BUILD guard is attached only `if(CMAKE_SYSTEM_NAME STREQUAL
    "Linux")`. Its `--expect off` path still runs `readelf`, which macOS doesn't have and which
    would read nothing useful from Mach-O anyway.
- **Negative-control probe.** `-Wl,--gc-sections` is GNU ld. On Apple it becomes `-Wl,-dead_strip`
  (generator expression on `APPLE`).
- **Whole-archive.** The link probe uses `$<LINK_LIBRARY:WHOLE_ARCHIVE,…>`. CMake ≥ 3.24 lowers it
  to `-force_load` on Apple. `ETNPExtras.cmake.in` already has an explicit `APPLE` branch for
  consumers. Both get exercised for the first time on a real Apple linker, so the nm guard is what
  actually proves the registrar survives.
- **Highway** 1.4.0 supports arm64 macOS (NEON; Apple has no SVE, so dynamic dispatch picks NEON).
  No change expected.

## 5. Deployment-target gate (new; macOS's counterpart to the Windows CRT scan)

The rule for macOS ABI consistency is the minimum OS version. Every Mach-O object records
`LC_BUILD_VERSION` (platform, `minos`, sdk). An object built with a higher `minos` than the consumer
gets a linker warning ("was built for newer macOS version than being linked") and can crash at
runtime on older systems. The risk is the same as with Windows CRTs: **a dependency that ignores the
top-level setting.** In ET those are `ExternalProject`s (flatcc/flatbuffers, built as host tools and,
for `devtools`, the shipped `libflatccrt.a`) and `FetchContent` deps that don't inherit
`CMAKE_OSX_*`.

New `scripts/check-macos-minos.sh <prefix> <minos> <arch>`, modeled on `check-windows-crt.sh`:
for every member of every `lib/*.a`, assert platform `MACOS`, `minos ≤ <minos>`, and arch
`<arch>` only (no stray x86_64 slice). It uses `otool -l` / `vtool -show-build`. Hermetic unit tests
run it on canned `otool` text through a test hook, the same way `USDT_READELF_TEXT` works. The
target version and arch come from one SSOT, `macos_deployment_target`/`macos_arch` in
`configure-base.sh`, which feeds both the configure flag and the gate. Same pattern as
`crt_for_platform`.

## 6. Packaging and provenance

- `package.sh --toolchain "apple-clang-<ver> macos-sdk-<sdkver> minos-14.0"`. BUILDINFO's
  `toolchain=` is already per-artifact.
- `usdt=n/a`, `openvino_version=n/a`, `torch_version=2.14.0` (from `torch.sh`).
- Tarball layout (C2 members) is unchanged.

## 7. Gates on macOS

| Gate | Linux today | macOS |
|---|---|---|
| `test/extras_members.sh` | yes | yes. Check it for `.so`/ELF assumptions |
| `test/relocatability.sh` (moved prefix + SHARED link) | yes | yes. Manylinux provisioning is already `[ -f … ] &&`-guarded. On arm64 macOS all code is PIC, so the gate mainly proves relocatability and that a `.dylib` links with no undefined symbols. Still worth running |
| `check-macos-minos.sh` | n/a | **new** (§5) |
| LSTM round-trip (`lstm-roundtrip` action) | logging | logging. `scripts/lib/aot.sh`'s `dnf install pythonX.Y-devel` is manylinux-only; on macOS `et_aot_install_build_deps` instead asserts that `python3-config --ldflags --embed` resolves (setup-python ships a shared framework build). `install_executorch.sh` supports macOS natively |
| `.ptd` writer round trip | all variants | all variants (`ptd-gate-macos`) |
| XNNPACK workspace-size behavioral gate | extras-gate full | extras-gate full-build-macos |
| OpenVINO gates | linux-x86_64, Windows | n/a |

Each gate script gets the same portability pass as §3.4 (`sed_inplace`, `ncpu`, no `ldd`/`readelf`).

## 8. CI

**`release.yml`**
- `build-macos`: `runs-on: macos-15` (arm64), no container, matrix `variant: [bare, logging,
  devtools]`, `platform: [macos-arm64]`. Steps: checkout → `actions/setup-python@v5` 3.12 → venv
  plus `pip install cmake ninja` (pinned through a new `requirements/macos-build.txt` lock, so the
  build's cmake/ninja are hash-pinned the way the manylinux image is digest-pinned) → derive version
  → `checkout-executorch` → `build-runtime.sh --platform macos-arm64` → package → extras-members →
  relocatability → minos scan → LSTM round-trip (logging) → attest → upload
  `dist-<variant>-macos-arm64`.
- `ptd-gate-macos` (needs `build`, which produces `ptd-fixtures`, plus `build-macos`).
- `pin.needs` += `build-macos`, `ptd-gate-macos`.
- Delete the "macOS remains future work" comment.

**`extras-gate.yml`**
- `full-build-macos` + `full-gates-macos`, mirroring the Windows pair, so a `build-runtime.sh`
  change is proven on macOS before a tag.
- `fast-gate` (tier1/tier2) gets a macOS leg that downloads the release tarball and runs
  `--extras-only`. This needs a published release that contains `macos-arm64`. Until one exists,
  `classify-gate.sh`'s existing "no matching release → full" fallback covers it, but the macOS leg
  must look up its own platform's asset, or it would fall back on every PR forever. That needs a
  `classify_gate` unit test.

**`unit.yml`** adds a `macos-latest` leg, so the hermetic suite (which the macOS developer now runs
locally) stays green on BSD userland. **Today 11 unit-test files fail on this Mac**, all for
portability reasons: BSD `sed -i` in `patch-et-windows-byproducts.sh`, `wc -l` left-padding in
`lib_openvino`/`lib_licenses` assertions, and missing `pyyaml` for the `test/lib/*.py` workflow
checks. Those fixes are the first PR (plan Task 1) and are worth landing even if macOS artifacts
were dropped.

**Cost.** The repo is public, so macOS runner minutes are free. Expect about 3 × 15–20 min per
release, plus the full-mode gate legs.

## 9. Consumer-facing docs

- `README.md` platform table and "Consuming downstream": macOS row, minimum 14.0, arm64 only.
- `docs/handover-to-engine.md`: JNI on macOS loads a `.dylib` (`System.loadLibrary` maps to
  `lib<name>.dylib`); extras are whole-archived with `-force_load` (the `ETNPExtras.cmake` helper
  does this); the consumer's own `CMAKE_OSX_DEPLOYMENT_TARGET` must be ≥ 14.0.
- `CLAUDE.md`: platform list, local macOS build command (venv, no Docker), the minos gate.

## 10. Open questions for the spike (plan Task 2)

1. Do `KERNELS_OPTIMIZED`/`QUANTIZED`/`LLM` compile with Apple Clang 21 at the ET default C++17?
2. Do all of `patches/*.patch` apply cleanly, and does the `nm` workspace-size guard pass on
   Mach-O archives?
3. Do any absolute SDK paths land in `lib/cmake`? Does every shipped object carry `minos 14.0`
   (especially flatcc in `devtools`)?
4. Do the extras link probe, `-force_load`, and the registrar nm guard work on ld64/ld-prime?
5. Does `install_executorch.sh` (AOT wheel) build on macOS against the same pin, and does the LSTM
   round-trip pass?
6. Wall time and tarball size per variant, for setting CI timeouts.

## Out of scope / follow-ups

- CoreML delegate (`macos-arm64` with `EXECUTORCH_BUILD_COREML=ON`, or a separate flavor).
- DTrace USDT probes with a macOS probe contract.
- OpenVINO on macOS arm64 (its ARM CPU plugin exists, but it's a separate bundle and license review).
- `macos-x86_64` / universal2.
- ccache on macOS (`scripts/lib/ccache.sh` pins a Linux binary).
