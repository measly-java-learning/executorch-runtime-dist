# macOS arm64 native build spike

**Date:** 2026-11-27
**Host:** macOS 26.6.2, Apple silicon (10 cores, 64 GB), Command Line Tools only (Apple clang 21.0.0,
MacOSX SDK 26.5), Homebrew cmake 4.5.1 + ninja 1.13.2, Python 3.12.16 venv, ccache.
**ET:** v1.5.1 (`3b60683`), submodules at tag.
**Answers:** spec `docs/superpowers/specs/2026-11-27-macos-arm64-artifacts-design.md` §10.

## Method

The spike ran in a detached worktree of `main` with throwaway edits, none of which are meant to be
merged. The real changes are plan Tasks 3–5.

- `configure-base.sh`: a `macos-arm64)` arm returning the spec §2 flat list verbatim.
- `build-runtime.sh`:
  - skip `dnf` on Darwin
  - `nproc` → `sysctl -n hw.ncpu`
  - BSD `sed -i ''`
  - clang/SDK banner
  - `torch==2.14.0` from PyPI instead of `+cpu` from the CPU index
- `extras/CMakeLists.txt`: the `check-usdt-notes.sh` POST_BUILD wrapped in `if(Linux)`.
- After findings 1 and 4: `build_extras` gets `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DCMAKE_OSX_ARCHITECTURES=arm64`, and the `APPLE` branch of `ETNPExtras.cmake.in` is removed.

## Results

| # | Question | Answer |
|---|---|---|
| Q1 | OPTIMIZED/QUANTIZED/LLM kernels compile with Apple clang 21 at C++17? | **Yes.** No source changes, no extra flags. Unlike MSVC, there is no Linux/macOS feature gap. |
| Q2 | Vendored patches apply; workspace-size `nm` guard passes on Mach-O? | **Yes.** All five patches apply. `nm -C --defined-only` (llvm-nm) finds all three symbols. |
| Q3a | Absolute SDK/toolchain paths in `lib/cmake`? | **None.** No prefix leak either, and no absolute paths in any `INTERFACE_LINK_LIBRARIES`. Only `-lm` is referenced. |
| Q3b | Every shipped object `minos 14.0`, arm64 only? | **No, a real defect.** 12 objects were `minos 26.0`: all of `libetnp_ops_lstm.a` and `libhwy.a`. ET's own 2087 objects were 14.0, every archive was arm64-only, and none used the legacy `LC_VERSION_MIN_MACOSX`. See finding 1. |
| Q4 | Extras link probe, `-force_load`, registrar nm guard on Apple ld? | **Yes.** CMake lowers `$<LINK_LIBRARY:WHOLE_ARCHIVE>` to `-Xlinker -force_load`. The guard finds both registrar TUs. Both kernel tests pass. The only failure was `check-usdt-notes.sh` → `readelf: command not found` (rc 127), as predicted. |
| Q5 | AOT wheel + LSTM round-trip | **Yes, after one fix.** `install_executorch.sh` builds and installs natively in 345 s with no changes (setup-python/Homebrew CPython already ships an embeddable libpython, so `aot.sh`'s `dnf` step just becomes a check). The round-trip **failed at first**: 3 of 18 tests, all consumer links, with undefined `hwy::GetChosenTarget()`/`hwy::SupportedTargets()`. This was a bug in the shipped `ETNPExtras.cmake` (finding 4). After the fix, **18/18 pass**, forward and training, matching eager. |
| Q6 | Wall time / size | `logging`: 188 s cold (ccache empty, includes the torch download). The tarball is 11.5 MB, the prefix 47 MB, 137 archives. `devtools`: 113 s (ccache warm from `logging`), 11.7 MB tarball. All 2104 objects are `minos 14.0`, including the ExternalProject-built `libflatccrt.a`. `etdump_flatcc.h` is installed and the `package.sh` devtools guard passes. |

Other gates run against the spike prefix:
- `test/relocatability.sh`: **GATE PASS** with no changes. `cp -a` works on BSD, and
  `libpic_probe.dylib` links from a moved prefix.
- `test/extras_members.sh`: **OK** with no changes.
- `scripts/package.sh`: produces the tarball and sidecar, but BUILDINFO is wrong in two places, both
  already in the plan:
  - `torch_version=2.14.0+cpu` (Task 3, `torch.sh`)
  - `usdt=off`, which should be `n/a` (Task 5)
- `test/ptd_writer_run.sh`: **GATE PASS** on `logging` and `devtools` (11 dtypes/shapes, both
  overloads), with fixtures freshly minted by `scripts/emit-ptd-fixtures.py` on macOS. No script
  changes.
- `test/xnnpack_workspace_run.sh`: **GATE PASS**. The workspace grows from 0 to 11296 bytes after
  load. No script changes.
- `bare`: 123 s, 9.9 MB tarball. All 2099 objects are `minos 14.0`, and relocatability passes.
- CMake 4.5: deprecation warnings only (gflags, flatcc, FXdiv, pthreadpool declare
  `cmake_minimum_required` < 3.10). **`CMAKE_POLICY_VERSION_MINIMUM` is not needed.**

## Findings that change the plan

1. **The extras phase ignores the deployment target (Q3b).** `build_extras` configures `extras/` as
   a separate CMake project and passes only `CMAKE_BUILD_TYPE`, PIC, and the prefix paths, so
   AppleClang defaults `minos` to the host SDK (26.0). A 14.0 consumer would get "built for newer
   macOS version" link warnings and could crash at runtime on macOS 14/15. It also affects
   `--extras-only`, which the PR gate uses. Passing `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
   -DCMAKE_OSX_ARCHITECTURES=arm64` brings all 2099 objects to 14.0 (verified).
   → **Plan Task 4 addition:** an SSOT `extras_cmake_flags <platform>` (empty off macOS) used by
   `build_extras`. `--extras-only` callers must then pass `--platform`. The extras-gate macOS
   `fast-gate` leg passes `--platform macos-arm64`.
   → **This validates spec §5's minos gate.** It caught a real defect on the first build, in our own
   code rather than in an upstream ExternalProject.
2. Spec §3.6's "rewrite SDK paths if found" contingency is unnecessary. Keep the hard-fail scan
   anyway, since it costs nothing.
3. The CMake-4 policy workaround I flagged earlier isn't needed at this pin.
4. **The shipped `ETNPExtras.cmake` helper is broken for every macOS consumer (Q5).** Its `APPLE`
   branch links the raw archive path (`-Wl,-force_load,<IMPORTED_LOCATION>`) instead of the
   `etnp_ops_lstm` target, so the target's `INTERFACE_LINK_LIBRARIES etnp_hwy` never reaches the
   link and Highway is missing. Nothing exercised this branch before. The fix is to delete it:
   `$<LINK_LIBRARY:WHOLE_ARCHIVE,target>`, the form the Linux branch already used, keeps the target
   (and its deps), and CMake ≥ 3.24 lowers it to `-force_load` on Apple. The extras link probe uses
   that exact form and passed. The required CMake version doesn't change, since the Linux branch
   already needed 3.24. → **Plan Task 5 addition.** The round-trip gate is what caught this, so it
   must stay in the macOS release job.

## Verdict

**Go.** All three variants build natively on Apple silicon with Linux feature parity. Every
existing gate passes once the two defects above are fixed, and both are small, understood changes
in this repo's code, with no ET patches needed. Proceed with plan Tasks 3–9, including the
additions from findings 1 and 4.
