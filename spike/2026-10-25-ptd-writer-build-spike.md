# Spike: can we build + ship the `.ptd` writer? (issue #63)

**Status:** run — **green on all three platforms, one upstream bug found (Windows-only, one-line fix).**
**Type:** throwaway. Nothing built here ships. Harness lived in the session scratchpad; the Windows
copy is still at `winbox:C:\Users\cored\ptd-win`.
**Pin:** ExecuTorch `v1.5.1` (fresh clone with submodules), consumed against the published
`v1.5.1-1` `logging` tarballs (`linux-x86_64`, `windows-x86_64`, `windows-x86_64-static`).
**Hosts:** manylinux_2_28 container (`.build-image`); `winbox` (VS 18 / MSVC 19.51, Ninja, pwsh).

## The question

The torch-free training effort (corey-cole/executorch-numpy-runtime#23) depends on #63. The risk to
retire before any design work: does building and packaging the flat-tensor serializer (`save_ptd`),
and optionally `extension_training`, hit a dependency or toolchain snag that would stall the effort?

## Findings

1. **Upstream has no CMake library for the writer.** `extension/flat_tensor/serialize/serialize.cpp`
   is in no CMake target at v1.5.1 (or on `main`). Its only CMake consumer is the `train_xor` example
   (`TRAIN_XOR_SRCS`, which carries an upstream `# REVIEW: removing this breaks the build` comment).
   Buck has a `serialize_cpp` target; CMake does not. **We must own a small target** — a patch or a
   recipe-side `add_library`. It's ongoing upkeep, not a blocker.

2. **The public surface is clean.** `serialize.h` includes only `exec_aten.h`. The flatbuffers
   builder, `flat_tensor_generated.h`/`scalar_type_generated.h` and `flat_tensor_header.h` are
   private to the `.cpp`. **Consumers need no flatbuffers headers.** We ship one header
   (`serialize.h`) + one archive. The generated headers are platform-independent and come from the
   flatc (24.3.25, matching 1.5.1's vendored flatbuffers) that the build already produces
   (`flat_tensor_schema` target). Compile with `FLATBUFFERS_MAX_ALIGNMENT=1024` to match
   `EXECUTORCH_FLATBUFFERS_MAX_ALIGNMENT`. flatbuffers is Apache-2.0 and already in
   THIRD-PARTY-NOTICES via the reader side — verify during implementation.

3. **The writer compiles and round-trips on all three platforms.** The harness built `serialize.cpp`
   as a standalone static archive against the *shipped* tarball (Linux `-fPIC`; Windows `/MD` and
   `/MT`). It exported a tiny `Linear` with `external_constants=True`, ran it via `Module(pte, ptd)`,
   read the keys back with `FlatTensorDataMap`, wrote new weights (×2) with `save_ptd`, reloaded via
   `Module(pte, new_ptd)`, and checked the output: `[6.5, 14.5]` → `[13, 29]` exactly. That's the
   real train → inference handoff, not just the file format.

4. **Upstream bug: `save_ptd(const std::string& path, ...)` corrupts files on Windows.** It calls
   `std::ofstream::open(path)` without `std::ios::binary`, so MSVC's text mode turns each 0x0A byte
   into 0x0D 0x0A. Observed: 385-byte file vs the correct 376. The runtime rejects it (`/MD`:
   "schema version 1048576 is newer…"; `/MT`: "named_data is nullptr, malformed PTD") and `Module`
   fails with 0x24. The `std::ostream&` overload is fine. **Fix verified on winbox under both CRTs:**
   `file.open(path, std::ios::binary);` → 376 bytes, round trip passes. Still present on upstream
   `main` as of 2026-10-25. Vendor it as a patch (same idempotency + fixture lockstep rules as the
   other `patches/*.patch`) and file it upstream. A secondary nit: the path overload never checks
   that the file opened.

5. **`EXECUTORCH_BUILD_EXTENSION_TRAINING=ON` adds no new dependency.** A full Linux `logging` build
   with the flag added to `common_cmake_flags` went green end to end. That covered relocatability
   repair, the workspace-size `nm` guard, extras, license passthrough, and `test/build_smoke.sh`
   (SMOKE PASS). It installs `libextension_training.a` plus the `training_module.h`,
   `state_dict_util.h` and `sgd.h` headers. `gflags` (needed by `train_xor`) is already built
   unconditionally in `third-party/`. Cosmetic: upstream's header `install(DIRECTORY ...
   FILES_MATCHING)` leaves empty `module/test/` and `optimizer/test/` dirs in the prefix. **Not
   tried:** training ON under MSVC. Turning it on also compiles the `train_xor` example (and so
   `serialize.cpp` in-tree under MSVC), which this spike did not exercise.

6. **Shipping `extension_training` does not ship the writer.** Neither `libextension_training.a` nor
   `libextension_flat_tensor.a` defines (or references) `save_ptd`. The two halves of #63 are
   independent.

7. **Shipped tarballs have no `flat_tensor` / `named_data_map` headers** (as #63 says). The harness
   had to take `flat_tensor_data_map.h` from the source tree to read keys/layouts. A consumer that
   wants to read a `.ptd` written by its own training step needs those installed too. In-scope for
   #63 alongside `serialize.h`.

## Verdict

**No blocker.** The `.ptd` writer is buildable and packageable on all three shipped platforms with
work this repo already knows how to do: one owned CMake target, one vendored one-line patch, a
header install. #62 is not gated on a #63 problem.
