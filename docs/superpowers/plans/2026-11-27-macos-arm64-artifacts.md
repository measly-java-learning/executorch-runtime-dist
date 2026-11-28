# macOS arm64 Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `bare`/`logging`/`devtools` tarballs for `macos-arm64` (minimum macOS 14.0),
built natively on Apple silicon, with extras, gated and attested like the Linux ones.

**Architecture:** Four PRs, in order:
- **A** makes the shell tooling and unit suite BSD-portable. It is useful even without macOS.
- **B** is a spike on the dev Mac that answers the spec's open questions.
- **C** adds the platform to the SSOT libraries, `build-runtime.sh`, extras, and the gates.
- **D** wires up CI and docs.

**Tech Stack:** Bash (`set -euo pipefail`, bash ≥ 4), CMake + Ninja, Apple Clang, GitHub Actions
(`macos-15`), and the hermetic `test/*.test.sh` harness.

**Spec:** `docs/superpowers/specs/2026-11-27-macos-arm64-artifacts-design.md`

## Global Constraints

- The Linux and Windows artifacts must come out byte-for-byte the same in content and flags. The
  `--print-flags` output for every existing platform × variant is snapshotted before PR C and
  diffed after it.
- `macos-arm64` always uses a flat flag list. Never `--preset macos` or `--preset llm` (spec §2).
- The deployment target and arch come from one SSOT (`configure-base.sh`). The configure flags
  and the minos gate both read it.
- `bash test/run.sh` stays hermetic and green on both `ubuntu-latest` and `macos-latest`.
- No release tag is cut as part of this plan. The first `v1.5.1-N` with macOS needs explicit user
  approval.

---

## Task 1 (PR A, `fix/bsd-portability`): portable shell helpers + green unit suite on macOS

Today 11 test files fail on macOS.

- [ ] Add `scripts/lib/portable.sh` with:
  - `require_bash4`: checks `BASH_VERSINFO`; on failure, says to run `brew install bash`.
  - `sed_inplace <sed-args…> <file>`: `sed -i.etnp-bak … && rm -f file.etnp-bak`.
  - `ncpu`: `nproc`, then `sysctl -n hw.ncpu`, then `$NUMBER_OF_PROCESSORS`, then 4.
  - `sha256_file <file>`: prints `<hex>  <name>`, using `sha256sum` or falling back to `shasum -a 256`.
- [ ] `test/lib_portable.test.sh`: unit tests for each helper, including `sed_inplace` leaving no
  backup file behind.
- [ ] Switch `scripts/patch-et-windows-byproducts.sh` to `sed_inplace`. This is the
  `invalid command code f` failure. Switch `build-runtime.sh`'s two `sed -i` loops too.
- [ ] Switch every `sha256sum` call in `package.sh`, `package-fixtures.sh`,
  `package-openvino-fixtures.sh` and `install-ccache.sh` to `sha256_file`. Leave
  `vendor-openvino.sh` as is if it only runs in manylinux, and note that in a comment.
- [ ] Replace `$(nproc)` / `NUMBER_OF_PROCESSORS` in `build-runtime.sh` with `ncpu`.
- [ ] Fix the `wc -l` left-padding in `test/lib_openvino.test.sh` and `test/lib_licenses.test.sh`
  (`| tr -d ' '`, or count with `grep -c ''`).
- [ ] Make `test/run.sh` check for `python3 -c 'import yaml'` up front and fail with one line
  naming the fix, rather than producing five `ModuleNotFoundError` tracebacks. CI already has it.
  Add a `requirements/unit.txt` lock if the existing locks don't cover it.
- [ ] `unit.yml`: run the existing job as a matrix over `[ubuntu-latest, macos-latest]`.
- [ ] Acceptance: `bash test/run.sh` passes on this Mac and on both CI legs.

## Task 2 (PR B, `docs/macos-arm64-spike`): native build spike on the dev Mac

Output: `spike/2026-11-27-macos-arm64-spike.md`, which answers spec §10 Q1–Q6 with logs.

- [ ] Prerequisites: `python3.12 -m venv ~/.venvs/etnp-macos`, `pip install cmake ninja`, and clone
  ExecuTorch `v1.5.1` with submodules into `~/workspace/executorch`. The clone is several GB.
- [ ] Using a scratch edit of `configure-base.sh` with the spec §2 list, run
  `./build-runtime.sh --platform macos-arm64 --variant logging --prefix $PWD/out-macos --et-src ~/workspace/executorch`.
  Record anything that has to be bypassed by hand.
- [ ] Inspect the result:
  - `grep -rE '/Applications/Xcode|CommandLineTools|\.sdk/' out-macos/lib/cmake`
  - `for a in out-macos/lib/*.a; do otool -l "$a" | grep -A4 LC_BUILD_VERSION; done | sort | uniq -c`
  - `lipo -info` on each archive
- [ ] Repeat the build for `devtools`, to check flatcc's `minos` and the etdump header guard.
- [ ] Link `test/consumer` as a dylib from a moved copy of the prefix, then run the AOT install and
  the LSTM round-trip.
- [ ] Record wall time and tarball size for each variant.
- [x] **Done 2026-11-27.** Verdict: go. See `spike/2026-11-27-macos-arm64-spike.md`.
- [ ] Decision point: if Q1 fails (OPTIMIZED kernels don't compile), stop and bring options back
  to the user before PR C. The fallback is the Windows approach: drop `KERNELS_OPTIMIZED`/
  `QUANTIZED` and document the gap.

## Task 3 (PR C, `feature/macos-arm64`): SSOT libraries

- [ ] `configure-base.sh`:
  - Add `macos_deployment_target` (`14.0`) and `macos_arch` (`arm64`).
  - Add `_ET_MACOS_COMMON`, the flat list.
  - Add a `macos-*)` arm to `et_configure_base`. Unknown `macos-*` platforms return 2.
  - Add `_ET_LINUX_PARITY_FEATURES`.
- [ ] `test/lib_configure_base.test.sh`:
  - The macOS base contains every parity feature.
  - It contains the explicit `COREML/MLX/TORCHAO=OFF` and the deployment target and arch flags.
  - It contains no `--preset` and no `EVENT_TRACER`.
  - `macos-x86_64` → rc 2.
- [ ] `test/lib_cmakeflags.test.sh`: add `macos-arm64` to the platform loops. Assert OpenVINO is
  absent and the variant flags are layered on.
- [ ] Add `scripts/lib/torch.sh` (`torch_pip_args`, `torch_version_for_platform`) with a unit
  test. Use it in `build-runtime.sh` (replacing `TORCH_SPEC`) and in `package.sh` (replacing the
  hardcoded `2.14.0+cpu`). Update the ET-bump checklist, since it touches the torch pin.
- [ ] Snapshot `--print-flags` for all existing platform × variant pairs, compare with the
  pre-change snapshot, and require zero diff.

## Task 4 (PR C): `build-runtime.sh` macOS path

- [ ] Add `IS_MACOS`/`IS_LINUX` detection. Enforce host/platform agreement (rc 2 on a mismatch).
  `test/build_cli.test.sh` covers it through `--print-flags`, so it needs no build.
  - `--print-flags` must still work on any host for any platform, since that's how flags get
    inspected. Enforce agreement only on the real-build path.
- [ ] macOS: require a venv, with a one-line hint. Skip `dnf`. Print the `clang` banner and the
  `xcrun` SDK path and version.
- [ ] Guard the systemtap install on `IS_LINUX`. Guard the `/usr/lib64` normalization on
  `IS_LINUX`.
- [ ] Add the macOS SDK-path leak scan (hard fail). Unit-test it by factoring the scan into a
  function in a lib, with a fake prefix tree.
- [ ] Keep the workspace-size `nm` guard on non-Windows. The spike confirmed it works on Mach-O
  unchanged.
- [ ] **Spike finding 1:** the extras phase must use the platform's deployment target and arch.
  Without them, `libetnp_ops_lstm.a` and `libhwy.a` came out `minos 26.0`.
  - Add `extras_cmake_flags <platform>` to `configure-base.sh` (empty off macOS, read from the
    same `macos_deployment_target`/`macos_arch` SSOT) and use it in `build_extras`.
  - `--extras-only` gets `--platform`, and callers pass it.
  - Unit-test that the flags appear for macOS and are absent for Linux and Windows.
- [ ] Update the header comment and `usage()`: the manylinux requirement applies to Linux only;
  document the macOS invocation.

## Task 5 (PR C): extras on Apple

- [ ] `extras/CMakeLists.txt`:
  - The USDT marker word is `n/a` off Linux.
  - Attach the `check-usdt-notes.sh` POST_BUILD only on Linux.
  - The neg probe uses `-Wl,-dead_strip` on `APPLE` and `-Wl,--gc-sections` elsewhere.
- [ ] **Spike finding 4:** delete the `APPLE` branch of `etnp_extras_whole_archive` in
  `extras/cmake/ETNPExtras.cmake.in`. The raw `-force_load,<path>` dropped the target's
  `etnp_hwy` dependency, so every macOS consumer link failed on `hwy::*`. Use
  `$<LINK_LIBRARY:WHOLE_ARCHIVE,target>` for GNU and Apple. Add a hermetic test that the rendered
  helper contains no raw `-force_load` and that every non-MSVC branch links the target, not
  `IMPORTED_LOCATION`. Note it in `docs/lstm-op-consumer-guide.md`.
- [ ] Update `test/buildinfo.test.sh` and `test/package.test.sh` expectations if they enumerate
  the allowed marker words.
- [ ] Check `test/extras_members.sh` for ELF/`.so` assumptions and fix any.
- [ ] Acceptance: the extras phase completes on the Mac, and the registrar nm guard prints
  `all extras registrar TUs present`.

## Task 6 (PR C): minos gate

- [ ] `scripts/check-macos-minos.sh <prefix> <minos> <arch>` (spec §5).
  - The test hook env var `MINOS_OTOOL_TEXT` stands in for `otool`.
  - Treat an object with no `LC_BUILD_VERSION` (an old `LC_VERSION_MIN_MACOSX`) as a failure,
    with a message.
- [ ] `test/check_macos_minos.test.sh`, using canned otool text:
  - pass
  - a higher minos fails
  - the wrong platform (`IOS`) fails
  - an x86_64 slice fails
  - no load command fails
  - an empty prefix fails
- [ ] Run it at the end of `build-runtime.sh` on macOS, so local builds are gated too. Also run it
  as an explicit CI step on the packaged prefix.

## Task 7 (PR C): gates portable to macOS

- [ ] `test/relocatability.sh`:
  - Already provision-guarded. Make the `cp -a`/`mktemp` usage BSD-safe.
  - Run the probe link on macOS.
- [ ] `test/ptd_writer_run.sh` and `test/xnnpack_workspace_run.sh`: remove GNU-isms (`nproc`,
  `sed -i`, `readlink -f`) and `LD_LIBRARY_PATH` assumptions.
- [ ] `scripts/lib/aot.sh`: on Darwin, `et_aot_install_build_deps` asserts that an embeddable
  libpython exists (`python3-config --embed --ldflags`) and does not call `dnf`. Extend
  `test/lib_aot.test.sh`.
- [ ] `.github/actions/lstm-roundtrip/action.yml`: make the `/opt/python` PATH prepend
  conditional (it's harmless if missing, but make that deliberate).
- [ ] Acceptance on the Mac:
  - The full `logging` build, `package.sh`, `extras_members.sh`, `relocatability.sh`, the minos
    scan, the ptd writer gate and the LSTM round-trip all pass.
  - Then `bare` and `devtools` pass build, package, and the minos scan.

## Task 8 (PR D, `feature/macos-arm64-ci`): CI

- [ ] Add a `requirements/macos-build.in` + lock (cmake, ninja), generated by the existing
  compile-requirements tooling.
- [ ] Every macOS job installs Homebrew bash before running repo scripts. `macos-latest`'s only
  bash is `/bin/bash` 3.2, and `require_bash4` refuses it (learned on PR #67's unit leg). Factor
  this into a small composite action, `.github/actions/macos-bash`, so release and extras-gate
  can't drift.
- [ ] `release.yml`:
  - Add `build-macos` (spec §8) and `ptd-gate-macos`.
  - Add both to `pin.needs`.
  - Remove the "future work" comment.
- [ ] `extras-gate.yml`: add `full-build-macos` and `full-gates-macos`, plus a macOS `fast-gate`
  leg that resolves its own platform's asset.
- [ ] `classify-gate.sh` + `test/classify_gate.test.sh`: per-platform release-asset lookup, so a
  release with no macOS asset sends only the macOS leg to `full`.
- [ ] Structural YAML tests in `test/lib/extras_gate_macos.py` + `test/extras_gate_macos.test.sh`
  (follow the CLAUDE.md rule: Python in a `.py`, thin shell invoker):
  - The `build-macos` matrix equals the `full-build-macos` matrix.
  - Both jobs are in `pin.needs`.
  - No `container:` on macOS jobs.
- [ ] Acceptance: a PR touching `build-runtime.sh` runs `full` mode with green macOS legs.

## Task 9 (PR D): docs

- [ ] `README.md`: platform table, macOS consumption notes.
- [ ] `docs/handover-to-engine.md`: macOS JNI `.dylib`, `-force_load`, deployment target ≥ 14.0.
- [ ] `CLAUDE.md`:
  - Add `macos-arm64` to the platform list.
  - Add the local macOS build command (venv, no Docker) to Key commands.
  - Mention the minos gate under Architecture.
- [ ] Update the spec's status to Implemented and link the PRs.

## Follow-ups (not in this plan)

- Cut the first release with macOS (needs user approval).
- CoreML delegate, DTrace USDT, OpenVINO macOS, ccache on macOS.
