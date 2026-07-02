# Some targets install to `${CMAKE_BINARY_DIR}/lib`, breaking `find_package(executorch)` from an install prefix

## Summary

Four `CMakeLists.txt` install their targets to `DESTINATION ${CMAKE_BINARY_DIR}/lib`
(the **build** directory) instead of `${CMAKE_INSTALL_LIBDIR}` like every other
target. As a result, on `cmake --install`:

1. the target's static library is **not** placed into the install prefix, and
2. the exported `ExecuTorchTargets-release.cmake` bakes an **absolute build-tree
   path** into `IMPORTED_LOCATION_RELEASE`.

Any downstream `find_package(executorch CONFIG REQUIRED)` against the installed
tree then fails at configure time (or the build tree cannot be deleted/relocated),
because the imported target points at a file that isn't in the prefix.

## Affected targets / files

| File | Target |
|------|--------|
| `extension/evalue_util/CMakeLists.txt` | `extension_evalue_util` |
| `devtools/etdump/CMakeLists.txt` | `etdump` |
| `devtools/bundled_program/CMakeLists.txt` | `bundled_program` |
| `third-party/CMakeLists.txt` | `flatccrt` |

All 55 other installed targets in the tree already use `${CMAKE_INSTALL_LIBDIR}`.

## Environment

- ExecuTorch `v1.3.1` (commit `e2f18eb23c45bd22ca332b0b8b49a81de304b472`)
- `torch==2.12.0+cpu`
- Container: `quay.io/pypa/manylinux_2_28_x86_64` (AlmaLinux 8, gcc-toolset-14), CPython 3.12
- CMake 3.28, Ninja

## Reproduction

Configure + build + install with a prefix distinct from the build dir:

```bash
cmake -B /tmp/et-build -S <executorch> -G Ninja --preset linux \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/tmp/et-install \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DEXECUTORCH_ENABLE_LOGGING=ON \
  -DEXECUTORCH_BUILD_XNNPACK=ON \
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON \
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON
cmake --build /tmp/et-build -j"$(nproc)"
cmake --install /tmp/et-build --prefix /tmp/et-install
```

Then observe the leak and the missing library:

```bash
# absolute build-tree path baked into the exported config:
grep -n 'et-build' /tmp/et-install/lib/cmake/ExecuTorch/ExecuTorchTargets-release.cmake
#   IMPORTED_LOCATION_RELEASE "/tmp/et-build/lib/libextension_evalue_util.a"

# ...and the archive is absent from the install prefix:
ls /tmp/et-install/lib/libextension_evalue_util.a   # No such file or directory
```

Finally, a trivial consumer fails at `find_package` time:

```cmake
cmake_minimum_required(VERSION 3.24)
project(probe LANGUAGES CXX)
find_package(executorch CONFIG REQUIRED)   # <-- fails here
add_library(probe SHARED probe.cpp)
target_link_libraries(probe PRIVATE executorch)
```

```
CMake Error at .../ExecuTorchTargets.cmake:569 (message):
  The imported target "extension_evalue_util" references the file
     "/tmp/et-build/lib/libextension_evalue_util.a"
  but this file does not exist.
```

## Expected vs. actual

- **Expected:** installed targets land in `<prefix>/lib` and the exported config
  references them via `${_IMPORT_PREFIX}/lib/...`, so the install tree is
  relocatable and `find_package` works from any location.
- **Actual:** the four targets above install into the build dir and their imported
  locations are absolute build-tree paths.

## Root cause

These `install(TARGETS ...)` calls use `DESTINATION ${CMAKE_BINARY_DIR}/lib`.
`CMAKE_BINARY_DIR` is the build directory, not the install prefix, so `install`
copies the artifact back into the build tree (a no-op for the prefix) and CMake
records the absolute build path in the exported target file. The correct
destination is `${CMAKE_INSTALL_LIBDIR}` (relative to the install prefix), which
every sibling target already uses, e.g. `extension/data_loader/CMakeLists.txt`:

```cmake
install(
  TARGETS extension_data_loader
  EXPORT ExecuTorchTargets
  DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ...
)
```

## Proposed fix

Replace `${CMAKE_BINARY_DIR}/lib` with `${CMAKE_INSTALL_LIBDIR}` in the four files:

```diff
--- a/extension/evalue_util/CMakeLists.txt
+++ b/extension/evalue_util/CMakeLists.txt
@@ install(
     TARGETS extension_evalue_util
     EXPORT ExecuTorchTargets
-  DESTINATION ${CMAKE_BINARY_DIR}/lib
+  DESTINATION ${CMAKE_INSTALL_LIBDIR}
     INCLUDES
     DESTINATION ${_common_include_directories}
   )
--- a/devtools/etdump/CMakeLists.txt
+++ b/devtools/etdump/CMakeLists.txt
@@ install(
-  DESTINATION ${CMAKE_BINARY_DIR}/lib
+  DESTINATION ${CMAKE_INSTALL_LIBDIR}
--- a/devtools/bundled_program/CMakeLists.txt
+++ b/devtools/bundled_program/CMakeLists.txt
@@ install(
-  DESTINATION ${CMAKE_BINARY_DIR}/lib
+  DESTINATION ${CMAKE_INSTALL_LIBDIR}
--- a/third-party/CMakeLists.txt
+++ b/third-party/CMakeLists.txt
@@
-install(TARGETS flatccrt DESTINATION ${CMAKE_BINARY_DIR}/lib)
+install(TARGETS flatccrt DESTINATION ${CMAKE_INSTALL_LIBDIR})
```

## Verification

With the patch applied and the same build/install commands:

- `ls /tmp/et-install/lib/libextension_evalue_util.a` → present.
- `grep -r et-build /tmp/et-install/lib/cmake/` → no hits (no absolute build paths).
- The consumer above configures, and linking it as a **SHARED** library succeeds
  (also confirming the libs are position-independent).

Verified end-to-end for `extension_evalue_util` (the `logging` configuration).
`etdump` / `bundled_program` are reached by the `devtools` configuration and
`flatccrt` by the third-party build; they share the identical mistake and fix.

## Notes

- Confirmed on `v1.3.1`; please check whether `main` still carries these four
  `${CMAKE_BINARY_DIR}/lib` destinations before landing.
