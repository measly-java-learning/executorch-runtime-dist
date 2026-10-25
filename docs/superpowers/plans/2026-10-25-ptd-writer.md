# `.ptd` Writer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship upstream's `save_ptd` as an ExecuTorch-exported CMake target, with its reader-side headers and a Windows binary-mode fix, in every tarball, gated by a behavioural round trip on every shipped prefix.

**Architecture:**
- Two vendored patches, applied by `scripts/patch-et-sources.sh` like the existing ones:
  - a packaging patch: a new `extension_flat_tensor_serialize` target in `ExecuTorchTargets`, plus header installs
  - a one-line behaviour fix in `serialize.cpp`
- A CI-minted `.pte`/`.ptd` fixture feeds a small consumer project in `test/ptd_writer/`. It links only the installed prefix and proves the following:
  - writes through both overloads produce identical files
  - `Module` reloads the result and the output changes as expected
  - the result matches a Python-written reference by content
  - every dtype in the sweep round-trips
- The extras gate (full mode) and the release workflow run that gate.

**Tech Stack:** CMake, C++17, bash under `set -euo pipefail`, Python (torch + the pinned executorch package) for the fixture, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-25-ptd-writer-design.md`. Evidence for every API and value used below: `spike/2026-10-25-ptd-writer-build-spike.md`. The spike's working harness, a useful starting point for Task 5, is at `/tmp/claude-1000/-home-corey-workspace-executorch-runtime-dist/13db9a3b-1e9b-4def-8467-93d9a3ab01c0/scratchpad/ptd-spike/harness/` if that path still exists. It is not required.

## Global Constraints

- ET pin is v1.5.1. Fixtures in `test/fixtures/etpatch/` are verbatim v1.5.1 files (README there names the commit, `3b60683`).
- Target name: `extension_flat_tensor_serialize`. Archive: `libextension_flat_tensor_serialize.a` (POSIX) and `extension_flat_tensor_serialize.lib` (MSVC).
- Installed headers, each under `include/executorch/...` at its source-relative path:
  - `extension/flat_tensor/serialize/serialize.h`
  - `extension/flat_tensor/serialize/flat_tensor_header.h`
  - `extension/flat_tensor/flat_tensor_data_map.h`
  - `extension/named_data_map/merged_data_map.h`
- Link `flat_tensor_schema` as `$<BUILD_INTERFACE:flat_tensor_schema>`. A plain PRIVATE link breaks `install(EXPORT)`.
- Do NOT add the target to `executorch-config.cmake`'s `optional_lib_list`.
- Do NOT build `extension_training` (spec non-goal; the reason must appear in the consumer doc).
- `save_ptd` is always called with `tensor_alignment = 128`. This matches `ExecutorchBackendConfig.segment_alignment` and the `FlatTensorConfig.segment_alignment` default, both 128 at v1.5.1.
- Patches are idempotent: a second run prints `already patched`, and a moved anchor is a HARD error. Patch files and fixtures change in the same commit.
- Hermetic suite (`bash test/run.sh`) stays green from a clean checkout; nothing needing a built prefix goes in a `*.test.sh`.
- No complex Python inside shell scripts (CLAUDE.md conventions).
- No upstream issue/PR is filed by this work.
- Branch: `feature/ptd-writer`. All work lands through one PR.

## Review Focus

Things the spec implies but doesn't spell out. The test for each lives in the owning task:

1. **A `.ptd` missing a key the `.pte` needs.** Expected: `Module` load/forward returns an error, never garbage output. Test: Task 5, `missing_key_fails`.
2. **Overwriting an existing checkpoint with a smaller one.** Expected: the file is truncated and reloads correctly. This is the shape a training loop hits every step, and it pins that the binary-mode fix kept truncation. Test: Task 5, `overwrite_truncates`.
3. **Saving into a directory whose name contains a space** (common Windows home dirs). Expected: it works. Test: Task 5, both overloads write into `<out>/dir with space/`.
4. **Requested alignment actually honoured.** Expected: the header's segment base offset and each segment offset are multiples of 128. Test: Task 5, `alignment_128`.
5. **Saving to a path that cannot be opened** (nonexistent parent dir). Upstream's path overload does not check the open, so the result may be `Error::Ok` with no file. Expected: the behaviour is known and documented, not silent. Test: Task 5, `unopenable_path`, asserts whatever the observed behaviour is, and Task 9 documents it.

---

### Task 0: Branch and commit the design

**Files:** `docs/superpowers/specs/2026-10-25-ptd-writer-design.md`, `spike/2026-10-25-ptd-writer-build-spike.md`, this plan. All three are already on disk and untracked.

- [ ] **Step 1:** `git checkout -b feature/ptd-writer`
- [ ] **Step 2:** Commit the three files. Leave the other untracked files on `main` alone, notably `patches/et-eigen-openmp.patch` and two `docs/superpowers/notes/2026-09-20-*`. They are unrelated work in progress.

```bash
git add docs/superpowers/specs/2026-10-25-ptd-writer-design.md spike/2026-10-25-ptd-writer-build-spike.md docs/superpowers/plans/2026-10-25-ptd-writer.md
git commit -m "docs: .ptd writer spike, design, and plan (#63)"
```

### Task 1: Explicit flat-tensor / named-data-map flags

**Files:**
- Modify: `scripts/lib/cmakeflags.sh` (`common_cmake_flags`, and its header comment)
- Test: `test/lib_cmakeflags.test.sh`

**Interfaces:** Produces `common_cmake_flags <platform>`, which now always contains `-DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON`.

- [ ] **Step 1: Write the failing test.** Append to `test/lib_cmakeflags.test.sh`, before `exit`:

```bash
# The .ptd reader/writer depend on these. The Linux preset happens to turn them on; pin them so
# --print-flags and BUILDINFO say so, and so a preset change cannot silently drop the writer.
for p in linux-x86_64 linux-aarch64 windows-x86_64 windows-x86_64-static; do
  assert_contains "$(common_cmake_flags "$p")" "-DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON" "flat tensor pinned on $p"
  assert_contains "$(common_cmake_flags "$p")" "-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON" "named data map pinned on $p"
done
# Windows already passes both in _ET_WINDOWS_COMMON; dedup must leave exactly one of each.
assert_eq "$(printf '%s\n' $(effective_cmake_flags windows-x86_64 logging) | grep -c -- '-DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON')" \
  "1" "flat tensor flag appears once on windows after dedup"
```

- [ ] **Step 2:** Run `bash test/lib_cmakeflags.test.sh`. Expected: FAIL on `flat tensor pinned on linux-x86_64`.
- [ ] **Step 3:** Append both flags to the `flags=` string in `common_cmake_flags`. Add one sentence to the header comment saying why they're pinned.
- [ ] **Step 4:** Run `bash test/lib_cmakeflags.test.sh && bash test/run.sh`. Expected: all pass, including `buildinfo.test.sh`. If a BUILDINFO or print-flags test hard-codes the full flag string, update its expectation in this task.
- [ ] **Step 5:** `./build-runtime.sh --print-flags --variant logging` and `--platform windows-x86_64-static`. Expected: both flags present once.
- [ ] **Step 6:** Commit: `feat: pin flat-tensor and named-data-map build flags (#63)`

### Task 2: Packaging patch — exported `extension_flat_tensor_serialize` + header installs

**Files:**
- Create: `patches/et-flat-tensor-serialize.patch`. It touches `extension/flat_tensor/serialize/CMakeLists.txt` and `extension/named_data_map/CMakeLists.txt`.
- Create fixtures, verbatim from v1.5.1:
  - `test/fixtures/etpatch/flat_tensor-serialize-CMakeLists.txt`
  - `test/fixtures/etpatch/named_data_map-CMakeLists.txt`
- Modify: `scripts/patch-et-sources.sh` (header concern list item 4; one `apply_patch "$ET_SRC" ...` line; the `>> patching` echo)
- Modify: `test/fixtures/etpatch/README.md` (name the new files)
- Test: `test/patch_et_sources.test.sh`

**Interfaces:** Produces a patched tree where configuring ET defines an exported static target `extension_flat_tensor_serialize`, and `cmake --install` lays down the four Global Constraints headers.

- [ ] **Step 1: Write the failing test.** In `test/patch_et_sources.test.sh`:
  - `mk_tree` copies the two new fixtures to `extension/flat_tensor/serialize/CMakeLists.txt` and `extension/named_data_map/CMakeLists.txt`.
  - After the first apply, add these assertions on rule content, not comment prose:

```bash
f="$(cat "$tmp/et/extension/flat_tensor/serialize/CMakeLists.txt")"
assert_contains "$f" "add_library(extension_flat_tensor_serialize" "serialize target defined"
assert_contains "$f" 'serialize.cpp' "serialize target compiles serialize.cpp"
assert_contains "$f" '$<BUILD_INTERFACE:flat_tensor_schema>' "schema linked build-interface only"
assert_contains "$f" "EXPORT ExecuTorchTargets" "serialize target exported"
assert_contains "$f" "serialize.h" "serialize.h installed"
assert_contains "$f" "flat_tensor_header.h" "flat_tensor_header.h installed"
assert_contains "$f" "flat_tensor_data_map.h" "flat_tensor_data_map.h installed"
assert_contains "$(cat "$tmp/et/extension/named_data_map/CMakeLists.txt")" "merged_data_map.h" "merged_data_map.h installed"
```

  - After the second apply: `assert_eq "$(grep -c 'add_library(extension_flat_tensor_serialize' ...)" "1" ...`.
  - Add a drift case `drift5` that empties `extension/flat_tensor/serialize/CMakeLists.txt`. It must exit 1 with `does not apply`.
- [ ] **Step 2:** Run `bash test/patch_et_sources.test.sh`. Expected: FAIL. The fixtures are copied but the patch isn't applied yet.
- [ ] **Step 3: Write the patch.** Generate it with `git diff` in a scratch copy of the v1.5.1 tree. A fresh clone with submodules is needed for Task 4 anyway, so clone it now if absent: `git clone --depth 1 --branch v1.5.1 --recurse-submodules --shallow-submodules https://github.com/pytorch/executorch.git <scratch>/executorch`.
  - **Target**, appended to `serialize/CMakeLists.txt` after the schema targets:
    - `add_library(extension_flat_tensor_serialize ${EXECUTORCH_ROOT}/extension/flat_tensor/serialize/serialize.cpp)`
    - `target_link_libraries(... PUBLIC extension_flat_tensor PRIVATE $<BUILD_INTERFACE:flat_tensor_schema>)`
    - `target_include_directories(... PUBLIC ${_common_include_directories})`
    - `target_compile_options(... PUBLIC ${_common_compile_options})`
    - `install(TARGETS ... EXPORT ExecuTorchTargets DESTINATION ${CMAKE_INSTALL_LIBDIR} INCLUDES DESTINATION ${_common_include_directories})`. This mirrors `extension_flat_tensor` in the parent `CMakeLists.txt`.
  - **Header installs**, in the same file:
    - `install(FILES serialize.h flat_tensor_header.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/executorch/extension/flat_tensor/serialize)`
    - `install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../flat_tensor_data_map.h DESTINATION .../executorch/extension/flat_tensor)`
    - In `named_data_map/CMakeLists.txt`: `install(FILES merged_data_map.h DESTINATION .../executorch/extension/named_data_map)`.
  - Comment each block in the house style used by `patches/et-devtools-headers.patch`: what it installs and why a consumer needs it.
- [ ] **Step 4:** Wire `apply_patch "$ET_SRC" "$ROOT/patches/et-flat-tensor-serialize.patch"` into `patch-et-sources.sh`. Add concern 4 to the header: ".ptd WRITER — upstream builds serialize.cpp into no CMake library…" with a pointer to the spec.
- [ ] **Step 5:** Run `bash test/patch_et_sources.test.sh && bash test/run.sh`. Expected: PASS.
- [ ] **Step 6:** Apply to the real clone (`bash scripts/patch-et-sources.sh <scratch>/executorch`). Expected: `et-flat-tensor-serialize.patch: applied`, and a re-run says `already patched`.
- [ ] **Step 7:** Commit: `feat: export extension_flat_tensor_serialize and install .ptd headers (#63)`

### Task 3: Binary-mode fix patch

**Files:**
- Create: `patches/et-flat-tensor-serialize-binary.patch` (one hunk in `extension/flat_tensor/serialize/serialize.cpp`)
- Create: `test/fixtures/etpatch/serialize.cpp` (verbatim v1.5.1)
- Modify: `scripts/patch-et-sources.sh` (concern 5, apply line), `test/fixtures/etpatch/README.md`
- Test: `test/patch_et_sources.test.sh`

- [ ] **Step 1: Write the failing test.** `mk_tree` copies `serialize.cpp`. Assert after the first apply:

```bash
s="$(cat "$tmp/et/extension/flat_tensor/serialize/serialize.cpp")"
assert_contains "$s" "file.open(path, std::ios::binary);" "save_ptd(path) opens in binary mode"
assert_eq "$(grep -c 'file.open(path);' "$tmp/et/extension/flat_tensor/serialize/serialize.cpp")" "0" "text-mode open is gone"
```

  Add a drift case that empties `serialize.cpp`.
- [ ] **Step 2:** Run the test. Expected: FAIL.
- [ ] **Step 3: Write the patch.** It changes exactly `file.open(path);` → `file.open(path, std::ios::binary);`. Its header comment says:
  - MSVC text mode turns every 0x0A into 0x0D 0x0A (385 bytes vs 376 in the spike), so the runtime rejects the file
  - no upstream issue exists as of 2026-10-25
  - drop this patch when upstream fixes it

  Keep it separate from Task 2's patch (different lifetime). Wire it in after Task 2's line.
- [ ] **Step 4:** Run `bash test/patch_et_sources.test.sh && bash test/run.sh`. Expected: PASS. Apply to the real clone and confirm `applied`, then `already patched` on a re-run.
- [ ] **Step 5:** Commit: `fix: open save_ptd's output file in binary mode (Windows corruption) (#63)`

### Task 4: Fixture emitter

**Files:** Create `scripts/emit-ptd-fixtures.py`, in the house style of `scripts/emit-xnnpack-fixtures.py`: module docstring explaining why each output exists, `main(outdir)`, and the usage check.

**Interfaces:** `python scripts/emit-ptd-fixtures.py <outdir>` writes:
- `linear.pte`: `nn.Linear(3, 2)`, weight `[[1,2,3],[4,5,6]]`, bias `[0.5,-0.5]`, exported with `ExecutorchBackendConfig(external_constants=True)`
- `linear.ptd`: export's external-data file, renamed from whatever `write_tensor_data_to_file` names it
- `linear_x2.ptd`: the same module with weight and bias multiplied by exactly 2, exported the same way. This is the Python-written reference.
- `in.bin`: float32 `[1,1,1]`, shape `[1,3]`
- `out_base.bin` / `out_x2.bin`: eager float32 outputs (expected `[6.5, 14.5]` and `[13, 29]`)

The script asserts before writing:
- both exports produce the same key set
- `linear.pte` contains no inline constants. Check that the `.ptd` keys include `lin.weight` and `lin.bias`.

- [ ] **Step 1:** Write the script.
- [ ] **Step 2: Verify.** Run it locally. The machine's AOT venv is `~/workspace/executorch/.venv`, which is ET 1.4.1; that's fine for a local check, and the spike showed a 1.4.1 `.pte` loads in 1.5.1. Put flatc on PATH from `et-build-logging/third-party/flatc_ep/bin`.

```bash
PATH=$PWD/et-build-logging/third-party/flatc_ep/bin:$PATH ~/workspace/executorch/.venv/bin/python -I scripts/emit-ptd-fixtures.py /tmp/<scratch>/ptdfx && ls /tmp/<scratch>/ptdfx
```

  Expected: the six files, and `in/out_base/out_x2` at 12/8/8 bytes.
- [ ] **Step 3:** Commit: `feat: emit .pte/.ptd fixtures for the .ptd writer gate (#63)`

### Task 5: Round-trip consumer project and gate scripts

**Files:**
- Create: `test/ptd_writer/CMakeLists.txt`. This is a standalone consumer: `find_package(ExecuTorch REQUIRED CONFIG)`, two executables, linked to `extension_flat_tensor_serialize extension_module_static extension_data_loader extension_tensor extension_flat_tensor extension_named_data_map executorch portable_kernels`. The spike showed that adding `portable_ops_lib` whole-archive on top of `executorch` double-registers kernels and aborts. Don't.
- Create: `test/ptd_writer/ptd_roundtrip.cpp`, which includes all four Global Constraints headers by their installed paths.
- Create: `test/ptd_writer/ptd_dtype_sweep.cpp`
- Create: `test/ptd_writer_run.sh <et-prefix> <fixture-dir>` (Linux), shaped like `test/xnnpack_workspace_run.sh`:
  - source gcc-toolset-14 if present
  - validate inputs
  - configure and build `test/ptd_writer` against the prefix into a mktemp dir
  - run both executables
  - end with `GATE PASS: .ptd writer round-trips`
- Create: `test/ptd_writer_run-windows.sh <et-prefix> <fixture-dir>`, the sibling shaped like `test/openvino_fixture_run-windows.sh`. It runs under `build-runtime.ps1`, does `cygpath` conversion, reads the CRT from `BUILDINFO` via `crt_for_platform`, and passes the same `CMAKE_MSVC_RUNTIME_LIBRARY` and `CMAKE_BUILD_TYPE=Release` flags that file documents.
- Create (hermetic): `test/ptd_writer_run.test.sh`

**Interfaces:**
- Consumes: Task 2's target and headers, and Task 4's fixture file names.
- Produces: `test/ptd_writer_run.sh` and `test/ptd_writer_run-windows.sh`, both with the signature `<et-prefix> <fixture-dir>` and exit 0 on pass. Tasks 7–8 call them.
- `ptd_roundtrip <fixture-dir> <out-dir>` and `ptd_dtype_sweep <out-dir>` each print one `ok:`/`FAIL:` line per check and exit non-zero on any FAIL.

`ptd_roundtrip` checks. Compare floats at 1e-6. Doubling is exact, so the reference comparisons are bit-exact.

| Check | Assertion |
|---|---|
| `baseline` | `Module(linear.pte, linear.ptd)` forward on `in.bin` equals `out_base.bin` |
| `write_both_overloads` | Doubled tensors (from `linear.ptd` via `FlatTensorDataMap`) are saved with `save_ptd(path, m, 128)` and with `save_ptd(std::ofstream(p, std::ios::binary), m, 128)`, both into `<out>/dir with space/`. Both return `Error::Ok` and the files are byte-identical. |
| `reload_single` | `Module(linear.pte, written)` forward equals `out_x2.bin` |
| `reload_merged` | The `Module(pte, std::vector<std::string>{written})` constructor (MergedDataMap path) forward equals `out_x2.bin` |
| `cross_writer_content` | Written file vs `linear_x2.ptd`: same key set; per key the same `scalar_type()`, `sizes()`, `dim_order()`, and identical data bytes. Do not compare whole files. |
| `alignment_128` | `FlatTensorHeader::Parse` on the written file's first bytes: `segment_base_offset % 128 == 0`, and each segment's offset from the flatbuffer is a multiple of 128. If segment offsets aren't reachable through installed headers, assert only the base offset and say so in a comment. |
| `overwrite_truncates` | First write a larger `.ptd` to path P (doubled tensors plus an extra 4096-float tensor `pad`), then the normal doubled set to P via the path overload. P's size equals the stream-written file's size, and `reload_single` passes on P. |
| `missing_key_fails` | Save a `.ptd` with only `lin.weight`. Loading/forwarding `linear.pte` with it returns a non-Ok error. Assert the error, not a crash. |
| `unopenable_path` | `save_ptd("<out>/no/such/dir/x.ptd", m, 128)`. Assert the observed result: Ok-with-no-file or an error. Print which, and make the line's text match what Task 9 documents. |

`ptd_dtype_sweep`:
- Build one tensor per dtype with `make_tensor_ptr(sizes, std::vector<uint8_t> bytes, {}, {}, type)` and distinct non-zero byte patterns: Float, Double, Half, BFloat16, Char, Byte, Int, Long, Bool, with Bool bytes limited to 0/1.
- Add a 0-d Float scalar (sizes `{}`) and a zero-element Float tensor (sizes `{0, 3}`).
- Save all in one `.ptd` at alignment 128, reload via `FileDataLoader` + `FlatTensorDataMap`, and assert per key: scalar type, sizes, dim order, and bytes.
- A dtype or shape that `save_ptd` or the loader rejects must produce a distinct `FAIL: <key> rejected: <error>` line. If that happens, stop. The owner decides between a documented expected-failure (an explicit `xfail:` line asserting the rejection) and a fix. **Never drop the case.**

- [ ] **Step 1: Write the hermetic test** `test/ptd_writer_run.test.sh`, modelled on `test/xnnpack_workspace_run.test.sh`:
  - no args → exit 1
  - for each of `linear.pte linear.ptd linear_x2.ptd in.bin out_base.bin out_x2.bin` removed → exit 1 and the message names it
  - source-contract greps on `ptd_roundtrip.cpp`: it includes the four installed header paths; it calls `save_ptd` with `128` and no other alignment literal; it uses `std::ios::binary` for the stream overload; and the check names `cross_writer_content`, `overwrite_truncates`, `missing_key_fails` and `dir with space` all appear
- [ ] **Step 2:** Run `bash test/ptd_writer_run.test.sh`. Expected: FAIL (scripts missing).
- [ ] **Step 3:** Write the gate scripts and the consumer project.
- [ ] **Step 4:** Run `bash test/ptd_writer_run.test.sh && bash test/run.sh`. Expected: PASS.
- [ ] **Step 5: Red against a stock tarball.** Run the gate against the published `v1.5.1-1` logging linux-x86_64 tarball (`gh release download v1.5.1-1 -R measly-java-learning/executorch-runtime-dist -p '*logging-linux-x86_64.tar.gz'`) inside the build container. Expected: FAIL at configure or link, because `extension_flat_tensor_serialize` doesn't exist. This proves the gate catches a missing target.
- [ ] **Step 6:** Commit: `test: .ptd writer round-trip gate (#63)`

### Task 6: Local end-to-end verification on a real build

No new files, unless a fix is needed.

- [ ] **Step 1:** Build `logging` in the container from this branch against the patched v1.5.1 clone from Task 2. Use a `git archive HEAD` copy of the repo so untracked files (e.g. `patches/et-eigen-openmp.patch`) can't leak in:

```bash
docker run --rm -v "<copy>":/work -v "<scratch>/executorch":/executorch -w /work -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) "$(cat .build-image)" \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; ./build-runtime.sh --variant logging --prefix /work/out --et-src /executorch'
```

  Expected: `build-runtime.sh done`. In the log, `et-flat-tensor-serialize.patch: applied` and `et-flat-tensor-serialize-binary.patch: applied`.
- [ ] **Step 2:** Check:
  - `bash test/build_smoke.sh <copy>/out` → `SMOKE PASS`
  - `nm -C --defined-only <copy>/out/lib/libextension_flat_tensor_serialize.a | grep save_ptd` → two definitions
  - `grep -c extension_flat_tensor_serialize <copy>/out/lib/cmake/ExecuTorch/ExecuTorchTargets.cmake` ≥ 1
  - `grep -rn "<copy>\|/work/" <copy>/out/lib/cmake` → nothing (no leaked build paths)
- [ ] **Step 3:** Run the gate in the container: `bash test/ptd_writer_run.sh <copy>/out <fixture-dir from Task 4>`. Expected: every check `ok:` and `GATE PASS`. Record `unopenable_path`'s observed behaviour for Task 9.
- [ ] **Step 4:** Run `bash test/relocatability.sh <copy>/out` in the container. Expected: pass. This is the PIC + relocatability gate the release runs.
- [ ] **Step 5:** Extend `test/build_smoke.sh`. It's a manual script and doesn't gate:
  - assert the archive (either name)
  - assert the four headers
  - grep `ExecuTorchTargets.cmake` for the target
  - on POSIX, assert a defined `save_ptd` via `nm`

  Re-run it on `<copy>/out`, then commit: `test: build_smoke checks the .ptd writer (#63)`.

Windows is verified by the PR's full gate (Task 7). If it fails there and needs local iteration, `winbox` (ssh alias, VS 18, pwsh, Git-Bash) has the spike copy at `C:\Users\cored\ptd-win`. Its ET checkout is v1.4.1, so a v1.5.1 clone would be needed for a full build.

### Task 7: Extras gate wiring (PR-time, full mode)

**Files:**
- Modify: `.github/workflows/extras-gate.yml`
- Modify: `scripts/classify-gate.sh` (the `full` regex at line 52)
- Test: `test/classify_gate.test.sh`, and the Windows structural tests in `test/lib/extras_gate_windows.py` if they enumerate `full-gates-windows` steps

- [ ] **Step 1: Write the failing test.** In `test/classify_gate.test.sh`, add cases mirroring the existing `emit-xnnpack-fixtures.py` / `test/xnnpack_workspace` ones. Each of these, alone in the changed-file list, must classify as `full`:
  - `scripts/emit-ptd-fixtures.py`
  - `test/ptd_writer_run.sh`
  - `test/ptd_writer_run-windows.sh`
  - `test/ptd_writer/ptd_roundtrip.cpp`
- [ ] **Step 2:** Run it. Expected: FAIL (they classify as tier1/none).
- [ ] **Step 3:** Extend the regex, e.g. `|scripts/emit-ptd-fixtures\.py|test/ptd_writer(_run(-windows)?\.sh|/.*)`. Add the same paths to the workflow's `on.pull_request.paths` with a comment in the existing "runs only in full" style.
- [ ] **Step 4:** Add the jobs' steps in `extras-gate.yml`:
  - `full-aot`: a step `Emit .ptd writer fixtures` that runs `python scripts/emit-ptd-fixtures.py "$PWD/fixtures-dryrun/ptd"`. It is already covered by the `full-fixtures` upload glob.
  - `full-gates`: a step `.ptd writer round trip` that runs `bash test/ptd_writer_run.sh "$PWD/out" "$PWD/fixtures-dryrun/ptd"`.
  - `full-gates-windows`: a step running `& pwsh -File build-runtime.ps1 test/ptd_writer_run-windows.sh "$PWD/prefix" "$PWD/fixtures-dryrun/ptd"`, in the same throw-on-nonzero form as its neighbours. It runs on both CRT legs. That job unpacks only the logging tarball, which is acceptable here: the release gate in Task 8 covers devtools.
- [ ] **Step 5:** Run `bash test/run.sh`. Expected: PASS, including the workflow structural tests and the YAML parse.
- [ ] **Step 6:** Commit: `ci: run the .ptd writer gate in the full extras gate (#63)`

### Task 8: Release workflow wiring

**Files:**
- Modify: `.github/workflows/release.yml`
- Test: `test/release_workflow.test.sh`

**Decision (plan-level, corrects spec §6's mechanism and keeps its intent):** the fixture is NOT minted in a new job that the builds wait on. Minting needs the ~15-min executorch Python build, so every build would sit behind it. Instead:
- The existing `build` leg `linux-x86_64` / `logging` already installs torch + executorch (LSTM round-trip action) and already mints the LSTM/OpenVINO fixtures. It also runs `emit-ptd-fixtures.py` and uploads them as artifact `ptd-fixtures`.
- New jobs `ptd-gate` (Linux: matrix = `variant [bare, logging, devtools]` × `combo` from `needs.setup.outputs.platforms`, in the build container, `runs-on: matrix.combo.runs_on`) and `ptd-gate-windows` (matrix = `variant [logging, devtools]` × `platform [windows-x86_64, windows-x86_64-static]`, `windows-2022`).
- Each downloads `dist-<variant>-<platform>` and `ptd-fixtures`, unpacks the tarball (`--strip-components=1`), and runs the matching gate script. Windows goes through `build-runtime.ps1`.
- `pin` needs `[build, build-windows, openvino, ptd-gate, ptd-gate-windows]`. A failing gate therefore blocks the release even though attestation already ran in `build`.

Task 9 updates spec §6 to say this.

- [ ] **Step 1: Write the failing test.** Append to `test/release_workflow.test.sh`:

```bash
assert_contains "$(cat "$wf")" "emit-ptd-fixtures.py" "release emits the .ptd fixture"
assert_contains "$(cat "$wf")" "  ptd-gate:" "linux .ptd gate job exists"
assert_contains "$(cat "$wf")" "  ptd-gate-windows:" "windows .ptd gate job exists"
assert_contains "$(cat "$wf")" "test/ptd_writer_run.sh" "linux gate runs the gate script"
assert_contains "$(cat "$wf")" "test/ptd_writer_run-windows.sh" "windows gate runs the gate script"
assert_contains "$needs_line" "ptd-gate" "pin depends on the linux .ptd gate"
assert_contains "$needs_line" "ptd-gate-windows" "pin depends on the windows .ptd gate"
```

  These must sit after the existing `needs_line=` assignment. If a matrix-equality check is wanted (gate matrix == build matrix), put it in `test/lib/release_ptd_gate.py` with a thin `.test.sh` invoker, per the CLAUDE.md no-embedded-Python rule.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Edit `release.yml` as decided above. The emit step goes inside the existing `Emit + package LSTM fixtures` step's `if:` condition, or a sibling step with the same `if:`, followed by an `actions/upload-artifact@v7` of `ptd-fixtures/` named `ptd-fixtures`. Don't package it as a release asset.
- [ ] **Step 4:** Run `bash test/release_workflow.test.sh && bash test/run.sh`. Expected: PASS.
- [ ] **Step 5:** Commit: `ci: gate every release prefix on the .ptd writer round trip (#63)`

### Task 9: Docs

**Files:**
- Create: `docs/ptd-writer-consumer.md`
- Modify: `README.md` (one entry in the consumption section)
- Modify: `CLAUDE.md` (the "Vendored XNNPACK workspace-size patches" paragraph names the concerns; add the `.ptd` writer and the binary fix)
- Modify: the spec's §6, replacing "Both `build` … and `build-windows` gain a dependency on that job" with Task 8's mechanism

- [ ] **Step 1: Write `docs/ptd-writer-consumer.md`**, covering spec §5 item by item:
  - linking `extension_flat_tensor_serialize`
  - the `Module(pte, ptd)` and `Module(pte, {ptds})` constructors
  - enumerating a `.ptd` with `FlatTensorDataMap` (`load`, `get_num_keys`, `get_key`, `get_tensor_layout`, `get_data`)
  - `save_ptd`'s two overloads, and: keys must match the export's names; use alignment 128 and why; open streams with `std::ios::binary`
  - the `unopenable_path` behaviour Task 6 observed
  - `ET_EXPERIMENTAL` → `[[deprecated]]` → `-Wdeprecated-declarations` / C4996, and how a `-Werror` consumer suppresses it locally
  - interchangeability with Python-written `.ptd`, and the dtypes the sweep proved, including any `xfail`
  - the Windows binary-mode patch
  - the `extension_training` non-goal paragraph: upstream marks `TrainingModule`/`SGD` `ET_EXPERIMENTAL` and calls the extension a technical preview; consumers run their own optimizer

  Link the spec.
- [ ] **Step 2:** README entry and CLAUDE.md paragraph update. Each is a sentence or two pointing at the consumer doc.
- [ ] **Step 3:** Spec §6 correction.
- [ ] **Step 4:** `bash test/run.sh`. Expected: PASS.
- [ ] **Step 5:** Commit: `docs: .ptd writer consumer guide (#63)`

### Task 10: PR

- [ ] **Step 1:** Push `feature/ptd-writer` and open a PR referencing #63. The body summarizes:
  - the two patches
  - the gate
  - the `extension_training` non-goal and its reason
  - the release-workflow mechanism change from spec §6

  End the body with the attribution line.
- [ ] **Step 2:** Watch the extras gate. It must classify `full` (patches changed). Required: `full-gates` and both `full-gates-windows` legs run the `.ptd` round trip green. A Windows failure is investigated, not retried blindly.
- [ ] **Step 3:** Report the result to the maintainer. Merging, and tagging `v1.5.1-2`, are the maintainer's calls.
