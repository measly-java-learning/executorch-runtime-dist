# Windows MSVC spike — findings

Ran interactively on the `winbox` host (VS 18 Community, MSVC 19.51, Ninja 1.13, cmake 4.3, ET 1.3.1 clone at `C:\Users\cored\workspace\executorch`, project `.venv` with torch). Goal: de-risk the Windows amd64 build direction for `docs/superpowers/plans/2026-07-15-windows-amd64-artifacts.md`.

## Bottom line

A **torch-free, single-config Ninja + MSVC** build of the ExecuTorch runtime succeeds on Windows at **C++17** and installs a coherent, functional runtime — **provided** we drive it with flat `-D` flags (not `--preset windows`) and omit the optimized/quantized kernels. Three concrete corrections to the design fell out of the spike.

## Findings

### 1. `--preset windows` is unusable for us (design correction)
The ET `windows` *configure* preset pins `toolset: ClangCL` and expects the Visual Studio generator:
```
CMake Error: Generator Ninja does not support toolset specification, but toolset ClangCL was specified.
```
So the design's "use `--preset windows` for symmetry with Linux" (§5 / Global Constraints) does not hold — it would force clang-cl + the multi-config VS generator. This is also why upstream's MSVC CI script avoids the preset ("MSVC not ClangCL") and passes flat flags.
**→ Windows path uses flat `-D` flags + `-G Ninja` + MSVC.** `cmake --list-presets` confirms `windows` exists but it's the wrong toolchain for us.

### 2. `flatc_ep` ExternalProject byproduct bug breaks Ninja (needs a recipe patch)
`third-party/CMakeLists.txt:56` declares `BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc` (no extension), but on WIN32 the consumer uses `IMPORTED_LOCATION ${INSTALL_DIR}/bin/flatc.exe`. Ninja needs the byproduct path to match exactly, so:
```
ninja: error: 'third-party/flatc_ep/bin/flatc.exe', needed by
'schema/include/executorch/schema/program_generated.h', missing and no known rule to make it
```
Non-Ninja generators rely on the target-level `add_dependencies(flatc flatbuffers_ep)` and never hit this (why upstream's VS-generator build is fine). Upstream bug.
**→ Recipe patch (matches our existing ET-source-patch pattern): add `.exe` to `BUILD_BYPRODUCTS` on WIN32.** Verified workaround: build the `flatbuffers_ep` target first (`cmake --build <b> --target flatbuffers_ep`), which produces `flatc.exe`; the main build then finds it as an existing input. File upstream alongside pytorch/executorch#20709.

### 3. Mirror the *Linux* footprint, not the windows preset — omit optimized/quantized kernels (design correction)
Enabling `EXECUTORCH_BUILD_KERNELS_OPTIMIZED`/`QUANTIZED` (as the windows preset does) pulls torch's `c10` headers into the kernel targets:
```
kernels/portable/CMakeLists.txt:70  if(... AND EXECUTORCH_BUILD_KERNELS_OPTIMIZED)
  target_include_directories(optimized_portable_kernels PRIVATE ${TORCH_INCLUDE_DIRS})
  target_compile_definitions(... "ET_USE_PYTORCH_HEADERS=...")
```
On MSVC that fails two ways GCC tolerates (GCC allows the C++20 syntax at C++17 as an extension):
- `c10/util/StringUtil.h(169): error C7555: designated initializers require '/std:c++20'`
- `op_add.cpp: error C2672: 'apply_bitensor_elementwise_fn': no matching overloaded function` (torch c10 types vs ET kernel templates)

Our **Linux** build does **not** enable these kernels (they're absent from the linux preset), so omitting them on Windows is both the MSVC fix **and** true footprint parity (design §6). The base `portable_kernels`/`portable_ops_lib` still build (torch-free), so the runtime remains functional.
**→ No C++20 needed, no torch headers, C++17.**

### 4. torch at configure time
ET configure/build needs a Python that `find_package(Python3)` locates; the project `.venv` (with torch) works. torch is used only for codegen tooling here, **not** compiled into the runtime once `KERNELS_OPTIMIZED` is off (finding 3). Keep installing torch in the CI recipe (parity with Linux); the produced artifact is torch-free.

### 5. Relocatability (the last unknown) — no new Windows-specific leak
Installed `lib/cmake/ExecuTorch/*.cmake`: **19/20** exported locations are correct; the **only** leak is `extension_evalue_util` → its **build-tree** path. No torch / Windows SDK / `Program Files` / install-prefix leaks. This build was raw ET (spike didn't apply the recipe's relocatability repair). Note `extension/evalue_util/CMakeLists.txt:27` already uses the correct `DESTINATION ${CMAKE_INSTALL_LIBDIR}`, so this is a *different* export-path quirk than the `${CMAKE_BINARY_DIR}/lib` bug — and it is **not Windows-specific** (Linux builds evalue_util too). Implementation item: confirm the recipe's measure-and-repair covers/where-needed handles this on both platforms.

## Validated Windows flag set (flat, no preset)
```
-G Ninja
-DCMAKE_BUILD_TYPE=Release
-DCMAKE_POSITION_INDEPENDENT_CODE=ON        # harmless no-op on MSVC
-DEXECUTORCH_ENABLE_LOGGING=ON              # variant knob
-DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON
-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON
-DEXECUTORCH_BUILD_XNNPACK=ON
-DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON
-DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON
-DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON
-DEXECUTORCH_BUILD_EXTENSION_MODULE=ON
-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON   # required by EXTENSION_MODULE (preset validation)
-DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON
-DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON
# NO KERNELS_OPTIMIZED, NO KERNELS_QUANTIZED
```
Result: `configure 0`, `build 0` (1353/1353), `install 0`. Installed libs: `executorch(_core)`, `portable_kernels`, `portable_ops_lib`, full `extension_*` set, `xnnpack_backend`/`XNNPACK`/`xnnpack-microkernels-prod`, `pthreadpool`, `cpuinfo`, `extension_threadpool`, `kernels_util_all_deps`. Also links `executor_runner.exe`.

## Build orchestration notes (host)
- MSVC + cmake/ninja only exist after `Launch-VsDevShell.ps1 -Arch amd64`; `python` = project `.venv`.
- flatc byproduct: two-step (`--target flatbuffers_ep` then full build) OR the WIN32 `.exe` byproduct patch.
- Driver: base64 `-EncodedCommand` PowerShell over SSH; native tool output captured via `cmd /c "... > log 2>&1"` then read with `type` (avoids CLIXML mangling).
