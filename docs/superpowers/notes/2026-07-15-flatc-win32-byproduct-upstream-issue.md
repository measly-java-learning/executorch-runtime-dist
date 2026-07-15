# flatc_ep BUILD_BYPRODUCTS omits .exe on WIN32 → Ninja "no known rule to make flatc.exe"

## Environment

- **Platform:** Windows 11
- **Generator:** `-G Ninja` (Ninja 1.13+)
- **Compiler:** MSVC (tested on VS 18 Community, MSVC 19.51)
- **ExecuTorch version:** 1.3.1
- **CMake version:** 4.3+

## Reproduction

Configure and build ExecuTorch on Windows with Ninja and MSVC:

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON \
  -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON \
  -DEXECUTORCH_BUILD_XNNPACK=ON \
  [... other flags ...]

cmake --build build
```

**Error:**

```
ninja: error: '.../third-party/flatc_ep/bin/flatc.exe', needed by
'.../schema/include/executorch/schema/program_generated.h', missing and no known
rule to make it
```

The build succeeds on Windows with the Visual Studio generator (multiple-configuration) because it relies on target-level `add_dependencies(flatc flatbuffers_ep)` and does not enforce byproduct path matching.

## Root Cause

In `third-party/CMakeLists.txt`, the `flatc_ep` ExternalProject declares (using the `ExternalProject` `<INSTALL_DIR>` placeholder):

**Line ~56:**
```cmake
BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc
```

However, on WIN32, the imported target is configured a few lines later to:

```cmake
if(WIN32)
  set_target_properties(flatc PROPERTIES
    IMPORTED_LOCATION <INSTALL_DIR>/bin/flatc.exe
  )
else()
  set_target_properties(flatc PROPERTIES
    IMPORTED_LOCATION <INSTALL_DIR>/bin/flatc
  )
endif()
```

**The mismatch:** The declared byproduct path omits `.exe`, but the consumer (`IMPORTED_LOCATION`) expects `.exe`. Under Ninja, the byproduct path must match exactly what the consuming rule references. Non-Ninja generators (e.g., Visual Studio's multi-config generator) use the target-level dependency graph (`add_dependencies(flatc flatbuffers_ep)`) and do not validate byproduct paths, so they do not expose this bug.

## Proposed Fix

Give `BUILD_BYPRODUCTS` the platform-correct suffix so the declared byproduct matches the file the WIN32 `IMPORTED_LOCATION` consumes. A generator expression keeps it to a single line:

```diff
--- a/third-party/CMakeLists.txt
+++ b/third-party/CMakeLists.txt
@@ ExternalProject_Add(flatc_ep
   ...
-  BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc
+  BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc$<$<BOOL:${WIN32}>:.exe>
 )
```

(`$<$<BOOL:${WIN32}>:.exe>` expands to `.exe` on Windows and to the empty string elsewhere, so the byproduct path becomes `.../bin/flatc.exe` on WIN32 and `.../bin/flatc` on every other platform — exactly mirroring the existing `if(WIN32)` `IMPORTED_LOCATION` block.)

## Notes

- This bug is specific to Ninja on Windows; Visual Studio's multi-config generator works because it does not enforce byproduct-to-consumer path matching in the same way.
- A workaround without patching the source is to build the `flatbuffers_ep` target first (`cmake --build <b> --target flatbuffers_ep`), which produces `flatc.exe`; the subsequent main build then finds the existing byproduct and proceeds.
- This repo (executorch-runtime-dist) carries a temporary `sed` patch in the build recipe (appends `.exe` to the `BUILD_BYPRODUCTS` line on WIN32) to work around this upstream bug until it is fixed.
