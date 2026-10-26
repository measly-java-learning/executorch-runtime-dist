# Ship the `.ptd` writer — design

**Issue:** [#63](https://github.com/measly-java-learning/executorch-runtime-dist/issues/63)
**Part of:** torch-free training, tracked in
[corey-cole/executorch-numpy-runtime#23](https://github.com/corey-cole/executorch-numpy-runtime/issues/23)
**Evidence:** `spike/2026-10-25-ptd-writer-build-spike.md` (green on all three platforms)
**ET pin:** v1.5.1

## Why

Upstream's training flow keeps trainable weights inside the loaded method's memory. Reloading the
`.pte` resets them to the exported values. A `.ptd` (flat-tensor external-data file) is how trained
weights leave a training program: checkpoint, resume, and hand off to an inference `.pte` exported
with external weights. The numpy runtime runs the optimizer in numpy and copies weights into the
method (its own issues #19/#20). This repo's job is to make it possible to *write* `.ptd` files
from a consumer binary built against our tarball, and to *read* one back by name.

Reading through `Module(pte, ptd)` already works in shipped tarballs. Writing does not, and nobody
can include the reader's headers.

## Goals

1. Every shipped variant on every shipped platform carries a `save_ptd` implementation as an
   **ExecuTorch-exported CMake target**, so a `find_package(ExecuTorch)` consumer links it by name
   like any other ET extension. This covers `linux-x86_64`, `linux-aarch64`, `windows-x86_64` (/MD)
   and `windows-x86_64-static` (/MT), and whatever variants each platform ships today.
2. `save_ptd` writes correct bytes on Windows (see *Upstream bug* below).
3. The headers a consumer needs to write a `.ptd`, and to enumerate/read one directly, are
   installed:
   - `extension/flat_tensor/serialize/serialize.h` (writer API)
   - `extension/flat_tensor/flat_tensor_data_map.h` and its include
     `extension/flat_tensor/serialize/flat_tensor_header.h` (reader: keys, layouts, data)
   - the `extension/named_data_map/` public header(s) (`merged_data_map.h`), which back the
     `Module` multi-`.ptd` constructor
4. The flat-tensor and named-data-map build flags are explicit in `common_cmake_flags`
   (`scripts/lib/cmakeflags.sh`) rather than inherited from the Linux preset, so `--print-flags`
   and `BUILDINFO` say what is built.
5. Tests prove each of the above, and a consumer doc explains how to use it.

## Non-goals

- **No `extension_training`. We do not ship upstream's `TrainingModule` or C++ `SGD`.**
  *Decided 2026-10-25.* Upstream marks the whole extension experimental: its README calls it
  "experimental and under heavy active development" and "more of a technical preview", and every
  public class (`TrainingModule`, `state_dict_util`, `SGD`, `SGDOptions`, `SGDParamGroup`,
  `SGDParamState`) is declared `ET_EXPERIMENTAL`. Only SGD exists upstream as of 1.5.1. The
  consumer (executorch-numpy-runtime) runs its optimizer (Adam/SGD) in numpy and copies weights in,
  so shipping an unstable C++ optimizer would add surface and upkeep for no consumer. The spike
  showed it *would* build cleanly with no new dependency (finding 5), so this is a product choice,
  not a technical constraint. Revisit if upstream stabilizes the API or a consumer needs it. Note
  that this does **not** drop the numpy runtime's "`TrainingModule` approach": that approach uses
  upstream's joint-graph `.pte` format driven from numpy, not the C++ class. `save_ptd` itself is
  also `ET_EXPERIMENTAL`. We ship it anyway because there is no alternative writer in the runtime
  and its format is pinned by `kSchemaVersion` and checked by the reader.
- No pure-Python `.ptd` writer (an open option on #23; out of this repo's scope). Upstream's
  Python writer is in flight: pytorch/executorch#8542, with PR #22616 open as of 2026-10-25. That
  PR sits on `exir`'s `FlatTensorSerializer` and takes `dict[str, torch.Tensor]`, so it needs torch.
  For the torch-free consumer, the C++ writer shipped here remains the Python write path, through
  that consumer's bindings, even after it lands. We don't wait on it, but section 7 keeps the C++
  writer's output interchangeable with Python-written files so the two can be used side by side.
- No upstream issue/PR filed by this work. As of 2026-10-25 no pytorch/executorch issue (open or
  closed) mentions `save_ptd`, and upstream `main` still has the text-mode open. Whether and when to
  file is the maintainer's call, outside this work.
- No change to `executorch-config.cmake`'s `optional_lib_list`. Exported targets are visible
  through `ExecuTorchTargets.cmake` regardless. Adding the writer to the list would only fold it
  into `EXECUTORCH_LIBRARIES` for every consumer, which nobody asked for.

## Anti-goals

- A writer that builds but silently writes corrupt files on one platform. The Windows text-mode
  bug is exactly this, so a byte-level check on Windows is required, not optional.
- A new patch that quietly stops applying when the pin moves (idempotency contract, below).

## Constraints (existing repo contracts this must obey)

- **Patches**: the build target and the bug fix are vendored `patches/*.patch` applied by
  `scripts/patch-et-sources.sh`. Idempotent, and a moved anchor is a HARD error. Keep the patch
  and `test/fixtures/etpatch/` in lockstep, with fixtures copied from the real v1.5.1 anchor files.
  The script's header comment lists each concern; add this one.
- **SSOT libs**: flags change in `scripts/lib/cmakeflags.sh` only. `effective_cmake_flags` carries
  them to the build, `--print-flags` and `BUILDINFO`.
- **Hermetic unit suite**: anything needing a built prefix stays out of the `test/*.test.sh` glob.
- **Windows** builds through `build-runtime.ps1` → the same `build-runtime.sh` under Git-Bash/MSVC.
  The Windows flag list `_ET_WINDOWS_COMMON` already passes FLAT_TENSOR/NAMED_DATA_MAP. Dedup in
  `effective_cmake_flags` makes stating them again in `common_cmake_flags` harmless.

## How (decided)

### 1. Build target — vendored patch, upstream-style, exported

A new patch `patches/et-flat-tensor-serialize.patch` against
`extension/flat_tensor/serialize/CMakeLists.txt` adds a static library target
`extension_flat_tensor_serialize`:
- sources: `serialize.cpp`
- links `extension_flat_tensor` (which brings `executorch_core` and `flat_tensor_header.cpp`)
- private dependency on the existing `flat_tensor_schema` INTERFACE target, for the generated
  headers, the flatbuffers include and `FLATBUFFERS_MAX_ALIGNMENT`
- uses `${_common_compile_options}`, inherits `CMAKE_POSITION_INDEPENDENT_CODE`
- `install(TARGETS ... EXPORT ExecuTorchTargets ...)` like its sibling `extension_flat_tensor`
- must not leak build-tree-only include paths into the exported interface. Link
  `flat_tensor_schema` as `$<BUILD_INTERFACE:flat_tensor_schema>`. A plain `PRIVATE` link is
  not enough: for an exported *static* library CMake carries a private dependency into the export
  as `$<LINK_ONLY:>`, and `flat_tensor_schema` is in no export set, so `install(EXPORT)` would
  refuse it. *(Design-review call.)* The existing relocatability gate (no absolute prefix in
  `lib/cmake`) must stay green.

The target name follows upstream's `extension_<thing>` scheme. Builder's call whether it lives in
`serialize/CMakeLists.txt` or `extension/flat_tensor/CMakeLists.txt`, whichever gives the smaller,
more stable anchor.

The header installs (Goal 3) go in the same patch or a sibling. Builder's call, but group by
anchor file so a pin bump fails in one obvious place.

### 2. Upstream bug — `save_ptd(path, ...)` opens in text mode

`serialize.cpp`'s path overload does `file.open(path);` with no `std::ios::binary`. Under MSVC every
0x0A byte becomes 0x0D 0x0A. In the spike this produced a 385-byte file instead of 376, which the
runtime rejected. Fix: `file.open(path, std::ios::binary);`, verified under both CRTs. It's a
separate patch, `patches/et-flat-tensor-serialize-binary.patch`, because it's a behaviour fix
destined for upstream while the target patch is packaging. They have different lifetimes, and the
fix patch gets dropped the day upstream lands one. No upstream issue exists (checked 2026-10-25,
open and closed); if one is filed later, cite it in the patch header and in
`patch-et-sources.sh`'s concern list. The same patch fixes the silent-success paths around it: the
path overload returns `Error::AccessFailed` when the file cannot be opened, and the stream overload
returns `Error::Internal` when a write fails — flushing first, and with the path overload re-checking
after `close()`, since a small file's writes can only reach the OS there.

### 3. Flags

Add `-DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON` to
`common_cmake_flags`, and update `test/lib_cmakeflags.test.sh` expectations.

### 4. Tests

- **Hermetic** (in `test/run.sh`): `patch_et_sources.test.sh` covers both new patches against
  fixtures of the real anchor files: applies, a second run reports `already patched`, and a moved
  anchor is a hard error. `lib_cmakeflags.test.sh` covers the new flags.
- **Built prefix** (`test/build_smoke.sh`): asserts the archive (`libextension_flat_tensor_serialize.a`
  / `extension_flat_tensor_serialize.lib`), the installed headers, an exported
  `extension_flat_tensor_serialize` target in `lib/cmake/ExecuTorch/ExecuTorchTargets.cmake`, and
  a defined `save_ptd` symbol (`nm` on POSIX). These stay in the manual smoke and do **not** gate
  CI, and there is no new Windows smoke. *Decided 2026-10-25:* the behavioural round trip is the
  gate, see below.
- **Behavioural round trip** (built prefix, Linux and Windows): port the spike harness into the
  repo as a test the release/gate workflows run against each built prefix. The spike harness is a
  small CMake consumer project plus a `.pte`/`.ptd` fixture from a tiny `Linear` exported with
  `external_constants=True`. It must link against the *installed* target and headers only, no
  source tree. It asserts: `Module(pte, ptd)` baseline output; `save_ptd` via **both** overloads
  with weights ×2; byte-identical outputs from the two overloads; `Module(pte, new_ptd)` gives the
  expected output; plus the section 7 checks. On Windows, the byte-identical check is what catches
  a regression of the text-mode fix. Note: this repo commits no `.pte`/`.ptd`
  binaries. Every existing fixture is minted in CI by an emit script in the pinned AOT venv
  (`scripts/emit-xnnpack-fixtures.py`, `scripts/emit-openvino-fixtures.py`,
  `extras/lstm/aot/emit_fixtures.py`) on the linux-x86_64 `logging` leg only, and some are packaged
  as release assets.

### 5. Consumer doc

New `docs/ptd-writer-consumer.md`:
- linking: `find_package(ExecuTorch)` + `target_link_libraries(... extension_flat_tensor_serialize)`
- loading `.pte` + `.ptd` (`Module` constructors); enumerating a `.ptd` with `FlatTensorDataMap`
- writing with `save_ptd`, including the tensor-name contract (keys must match the names the
  `.pte` was exported with) and alignment (recommend 128, per section 7)
- that files are interchangeable with Python-written `.ptd` (export today; #22616 if it lands), and
  the dtype coverage the sweep proved
- **`ET_EXPERIMENTAL` warning**: it expands to `[[deprecated(...)]]`, so calls emit
  `-Wdeprecated-declarations` / C4996, and `-Werror` builds must suppress it locally
- the Windows text-mode fix, and that we patch it
- the `extension_training` non-goal and why, in one paragraph, pointing here

Also add a short entry to README's consumption section and to CLAUDE.md's patch-set paragraph
(which currently names two concerns).

### 6. Round trip is the gate; its fixture is CI-minted (decided 2026-10-25)

- **Fixture is minted, not committed.** `scripts/emit-ptd-fixtures.py` runs in the existing
  `linux-x86_64` / `logging` `build` leg of `release.yml`, which already installs torch and the
  pinned executorch package for the LSTM round trip. It uploads the `.pte`/`.ptd` as the
  `ptd-fixtures` workflow artifact. New `ptd-gate` (Linux: every variant × every `setup` platform)
  and `ptd-gate-windows` (both CRTs) jobs download that artifact plus the matching `dist-*`
  tarball, and `pin` needs both jobs, so a failing gate blocks the release. *(Corrected
  2026-10-25: this document originally put minting in a separate job that every build would wait
  on, which serialized both long build matrices behind the ~15-minute Python build for no gain.)*
  The full-mode extras gate mints the fixture the same way in `full-aot`. It is **not** a release
  asset; nothing downstream needs it. The golden output is computed by the emit script and travels
  with the fixture. No hand-recorded constants.
- **The round trip gates every shipped prefix**, Linux and Windows, before release. It compiles
  against the installed prefix only, including every Goal 3 header and linking the exported
  target, so it fails if the target or those headers are missing. That is why the structural
  checks don't also need to gate. Accepted gap: a future installed header that the round trip
  does not include could go missing unnoticed; extend the round trip's includes when adding one.

### 7. Interchangeability with Python-written `.ptd` (decided 2026-10-25)

Python write support is treated as a stated goal upstream (#8542 / PR #22616), so files from our
C++ writer must be interchangeable with Python-written ones. Three requirements:

1. **Cross-writer content check.** The `.ptd` that `export` writes already comes from the Python
   serializer (`FlatTensorSerializer`). The emit script also exports a second copy of the model with
   the ×2 weights, giving a Python-written reference `.ptd` for exactly the tensors the C++ step
   writes. The round trip compares the C++-written file against it **by content, not bytes**:
   - same key set
   - per key, the same scalar type, sizes and dim order
   - identical tensor bytes

   Alignment and padding may legitimately differ between writers, so no file-level byte compare
   here. That byte compare stays only between the two C++ overloads. If #22616 lands while this
   repo pins a release that contains it, its `save_ptd` output becomes a second reference with
   only the emit script changing. Gating on it is not required by this work.
2. **Alignment 128.** The round trip calls `save_ptd` with `tensor_alignment = 128`, matching what
   export produces (`ExecutorchBackendConfig.segment_alignment`) and #22616's default. The `16` in
   upstream's C++ examples (and in the spike) is just what those examples pass. The consumer doc
   recommends 128 and says why. Builder: confirm the default against the pinned ET's
   `ExecutorchBackendConfig` rather than trusting this number.
3. **Dtype sweep, no model.** A second check in the round trip writes a `.ptd` holding one tensor
   per dtype and reads it back via `FlatTensorDataMap`. It checks scalar type, sizes, dim order and
   bytes per key. Cover at least float32, float64, float16, bfloat16, int8, uint8, int32, int64 and
   bool, plus a 0-d scalar and a zero-element tensor. Builder's call whether this is the same
   executable or a sibling, as long as it runs wherever the round trip runs. A dtype that
   `save_ptd` or the reader rejects outright is a finding to record in the consumer doc, not a
   reason to drop it silently from the sweep. The non-contiguous-view hazard #22616 flags on the
   Python side does not apply: ET tensors carry dim order but no strided views into a larger
   storage.

## Left to the builder

- Exact patch split and anchor placement (within the "group by anchor file" rule).
- The emit script's model and export details (the spike's tiny `Linear`, weights `[[1,2,3],[4,5,6]]`,
  bias `[.5,-.5]`, `external_constants=True`, is a fine starting point), in the same pinned AOT
  venv the other emit scripts use.
- Exact step placement of the round trip within the `build` / `build-windows` / full-gate jobs,
  within section 6.
- Whether `linux-aarch64` needs anything beyond the shared path (not exercised by the spike; expect
  nothing, since the change is platform-neutral C++ and CMake).
