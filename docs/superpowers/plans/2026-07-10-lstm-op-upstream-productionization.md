# LSTM Op Upstream Productionization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the custom `etnp::lstm.out` operator inside every variant of the relocatable ExecuTorch tarball this repo builds, with an AOT definition and a live torch round-trip test proving export→lower→run matches `torch.nn.LSTM`.

**Architecture:** A new standalone `extras/` CMake project builds the torch-free LSTM kernel into `libetnp_ops_lstm.a` *after* the pure-ET install, links it against the just-built prefix (XNNPACK comes from the prefix; Highway 1.4.0 is hash-pinned/fetched), and installs the archive + header + a self-describing `ETNPExtras.cmake` (whose helper applies the correct per-OS whole-archive flags) into the prefix. `package.sh` tars it as today. A static nm-guard runs on every build; a live torch round-trip gates the executable target(s).

**Tech Stack:** C++17, CMake ≥ 3.24, ExecuTorch 1.3.1 runtime, XNNPACK f32 FC, Google Highway 1.4.0 (SIMD), PyTorch 2.12.0+cpu (AOT + test only), bash, GitHub Actions, manylinux_2_28.

## Global Constraints

- **Op namespace is frozen:** `etnp::lstm.out` (and functional `etnp::lstm`). Baked into `.pte`s — never rename. (Strategy Decision 1 / 4.)
- **Op scope is frozen — do not widen:** single-layer, unidirectional, `batch_first=False`, float32, contiguous. `input [T,B,I]`, `h0/c0 [B,H]`, `w_ih [4H,I]`, `w_hh [4H,H]`, optional biases `[4H]`; `output [T,B,H]`, `hn/cn [B,H]`. Gate row order **i,f,g,o** (PyTorch).
- **Canonical schema (byte-identical across faces):**
  ```
  lstm(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh, Tensor? b_ih, Tensor? b_hh) -> (Tensor, Tensor, Tensor)
  lstm.out(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh, Tensor? b_ih, Tensor? b_hh, *, Tensor(a!) output, Tensor(b!) hn, Tensor(c!) cn) -> (Tensor(a!), Tensor(b!), Tensor(c!))
  ```
- **Always-on in every variant** (bare/logging/devtools) — not behind a build flag.
- **Highway pin:** `1.4.0`, `SHA256=e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c`. A SHA change is the supply-chain review gate.
- **Parity tolerance:** rtol/atol **1e-4** vs torch eager.
- **Position-independent** (`-DCMAKE_POSITION_INDEPENDENT_CODE=ON`) and **relocatable** (no absolute build-prefix in any installed `*.cmake`) — same C2 guarantees as the ET tree.
- **Port, don't rewrite.** Source repo `SRC=/home/corey/workspace/executorch-numpy-runtime`, pinned commit **`95a5efd`**. Resolve any file with `git -C $SRC show 95a5efd:<path>`.
- **Do NOT** edit `docs/handover-to-engine.md` (frozen, different work item); reintroduce torch into the numpy repo; port the throwaway bench/feasibility/advisor tooling; or build a plugin framework (LSTM is extra #1 — glob + convention only).

---

### Task 1: De-risk spikes (no production code)

Resolve the three version-sensitive unknowns before porting. Output is a committed findings note.

**Files:**
- Create: `docs/superpowers/notes/2026-07-10-lstm-derisk-findings.md`

- [ ] **Step 1: Check the `make_boxed` output cap in our ET version**

The op has 3 mutable outputs; if `make_boxed_from_unboxed_functor.h` still `static_assert`s a 1-output cap, we keep the hand-rolled boxed registrar (expected).

Run:
```bash
grep -rn "num_nonconst_tensors\|static_assert" \
  /home/corey/workspace/executorch/runtime/kernel/make_boxed_from_unboxed_functor.h \
  /home/corey/workspace/executorch/extension/kernel_util/make_boxed_from_unboxed_functor.h 2>/dev/null
```
Expected: a `static_assert(... num_nonconst_tensors == 1 ...)`. Record the exact file+line and the assertion text.

- [ ] **Step 2: Confirm XNNPACK is exposed by a built prefix**

Run:
```bash
ls out-logging/lib/libXNNPACK.a out-logging/lib/libpthreadpool.a \
   out-logging/include/xnnpack.h out-logging/include/pthreadpool.h
```
Expected: all four exist (already verified). Record.

- [ ] **Step 3: Determine whether the `linux-aarch64` CI runner executes natively**

Inspect `.github/workflows/release.yml`: the aarch64 combo uses `runs_on: ubuntu-24.04-arm` (a native ARM runner), so it *can* execute a built binary. Record this conclusion (it decides whether the round-trip in Task 8 runs on aarch64 too, not only x86_64).

- [ ] **Step 4: Write and commit the findings note**

Write `docs/superpowers/notes/2026-07-10-lstm-derisk-findings.md` capturing Steps 1–3 (boxed-registrar decision, XNNPACK availability, aarch64-executes decision).

```bash
git add docs/superpowers/notes/2026-07-10-lstm-derisk-findings.md
git commit -m "docs: LSTM productionization de-risk findings (boxed cap, xnnpack, aarch64)"
```

---

### Task 2: `extras/` manifest + schema-header generator (single source of truth)

Establish the bundle skeleton and the mechanism that makes op-name drift impossible: one `extra.yaml`, from which both the C++ op-name constant and the Python AOT schema derive.

**Files:**
- Create: `extras/lstm/extra.yaml`
- Create: `extras/generate_schema_header.py`
- Test: `extras/test_generate_schema_header.py`

**Interfaces:**
- Produces: `extras/lstm/extra.yaml` with keys `name: etnp`, `op: lstm`, `variants: [all]`, `schema.functional`, `schema.out`.
- Produces: `generate_schema_header.py <extra.yaml> <out_header>` → writes a header defining `namespace etnp::schema { inline constexpr char kLstmName[]="etnp::lstm"; inline constexpr char kLstmOutName[]="etnp::lstm.out"; }` (consumed by Task 3's registrar) and reading it back (`load_schema(extra_yaml) -> dict`, consumed by Task 6's AOT).

- [ ] **Step 1: Write `extras/lstm/extra.yaml`**

```yaml
# One op = one bundle. This file is the SINGLE SOURCE OF TRUTH for the op name
# and schema; both the C++ registrar (via a generated header) and the Python AOT
# read from here so the two faces cannot drift.
namespace: etnp
op: lstm
# variants this op ships in. [all] => every tarball variant (bare/logging/devtools).
# Designed in now though everything is always-on; annoying to retrofit later.
variants: [all]
schema:
  functional: >-
    lstm(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh,
    Tensor? b_ih, Tensor? b_hh) -> (Tensor, Tensor, Tensor)
  out: >-
    lstm.out(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh,
    Tensor? b_ih, Tensor? b_hh, *, Tensor(a!) output, Tensor(b!) hn,
    Tensor(c!) cn) -> (Tensor(a!), Tensor(b!), Tensor(c!))
```

- [ ] **Step 2: Write the failing test `extras/test_generate_schema_header.py`**

```python
import subprocess, sys, pathlib, tempfile
HERE = pathlib.Path(__file__).parent

def test_header_has_qualified_op_names():
    out = pathlib.Path(tempfile.mkdtemp()) / "etnp_lstm_schema.h"
    subprocess.run([sys.executable, str(HERE / "generate_schema_header.py"),
                    str(HERE / "lstm" / "extra.yaml"), str(out)], check=True)
    text = out.read_text()
    assert 'constexpr char kLstmName[] = "etnp::lstm";' in text
    assert 'constexpr char kLstmOutName[] = "etnp::lstm.out";' in text
    assert "#pragma once" in text

def test_load_schema_roundtrip():
    sys.path.insert(0, str(HERE))
    from generate_schema_header import load_schema
    s = load_schema(HERE / "lstm" / "extra.yaml")
    assert s["qualified_name"] == "etnp::lstm"
    assert s["functional"].startswith("lstm(")
    assert s["out"].startswith("lstm.out(")
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `python -m pytest extras/test_generate_schema_header.py -v`
Expected: FAIL (`generate_schema_header.py` does not exist).

- [ ] **Step 4: Write `extras/generate_schema_header.py`**

```python
#!/usr/bin/env python3
"""Emit the C++ op-name header from an extra.yaml (single source of truth).

Usage: generate_schema_header.py <extra.yaml> <out_header.h>
Also importable: load_schema(path) -> dict for the Python AOT face.
The generated header defines qualified op-name constants the C++ registrar uses,
so the name it registers cannot drift from the name the AOT/schema declares.
"""
import sys, pathlib, yaml


def load_schema(extra_yaml) -> dict:
    d = yaml.safe_load(pathlib.Path(extra_yaml).read_text())
    ns, op = d["namespace"], d["op"]
    return {
        "namespace": ns,
        "op": op,
        "qualified_name": f"{ns}::{op}",
        "qualified_out_name": f"{ns}::{op}.out",
        "functional": " ".join(d["schema"]["functional"].split()),
        "out": " ".join(d["schema"]["out"].split()),
    }


def render_header(s: dict) -> str:
    guard_ns = s["namespace"]
    return (
        "// GENERATED from extras/{op}/extra.yaml — do not edit.\n"
        "#pragma once\n"
        "namespace {ns} {{\n"
        "namespace schema {{\n"
        '  inline constexpr char kLstmName[] = "{qn}";\n'
        '  inline constexpr char kLstmOutName[] = "{qon}";\n'
        "}}  // namespace schema\n"
        "}}  // namespace {ns}\n"
    ).format(op=s["op"], ns=guard_ns, qn=s["qualified_name"],
             qon=s["qualified_out_name"])


def main() -> int:
    extra_yaml, out_header = sys.argv[1], sys.argv[2]
    s = load_schema(extra_yaml)
    p = pathlib.Path(out_header)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(render_header(s))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `python -m pytest extras/test_generate_schema_header.py -v`
Expected: PASS (2 passed).

- [ ] **Step 6: Commit**

```bash
git add extras/lstm/extra.yaml extras/generate_schema_header.py extras/test_generate_schema_header.py
git commit -m "feat(extras): LSTM bundle manifest + schema-header generator (single source of truth)"
```

---

### Task 2b: Note on running Python tests

The extras Python tests need `pyyaml` and (later) `torch`. In the manylinux build container `build-runtime.sh` already `pip install`s `pyyaml` and `torch==2.12.0+cpu`. For local runs: `pip install pyyaml pytest`. This is documentation only — no commit.

---

### Task 3: Port Face 1 (runtime kernel) → `libetnp_ops_lstm.a` + analytic unit test

Port the five kernel sources verbatim from the pinned commit, wire the extras runtime CMake (XNNPACK-from-prefix + Highway fetch, header generation), and port the torch-free analytic correctness test.

**Files:**
- Create (verbatim port): `extras/lstm/runtime/{etnp_lstm.cpp,lstm_cell.h,lstm_cell.cc,xnn_linear.h,xnn_linear_cache.h}`
- Create: `extras/lstm/runtime/CMakeLists.txt`
- Create: `extras/CMakeLists.txt`
- Test (port): `extras/lstm/test/lstm_kernel_test.cpp`

**Interfaces:**
- Produces target `etnp_ops_lstm` (STATIC, PIC) — the whole-archive registration archive; registrar TU symbol `_GLOBAL__sub_I_etnp_lstm.cpp`.
- Produces `ETNP_EXTRAS_EXPECT_TUS` in the extras scope: list of registrar TU symbols (for the Task 4 guard).
- Consumes `generate_schema_header.py` (Task 2) at configure time → generated `etnp_lstm_schema.h`.

- [ ] **Step 1: Port the kernel sources verbatim from `95a5efd`**

```bash
SRC=/home/corey/workspace/executorch-numpy-runtime
mkdir -p extras/lstm/runtime
for f in etnp_lstm.cpp lstm_cell.h lstm_cell.cc xnn_linear.h xnn_linear_cache.h; do
  git -C "$SRC" show "95a5efd:examples/custom_kernels/lstm/$f" > "extras/lstm/runtime/$f"
done
ls extras/lstm/runtime
```
Expected: all five files present.

- [ ] **Step 2: Wire the registrar to the generated name constant (Face 2)**

Edit `extras/lstm/runtime/etnp_lstm.cpp`: add the generated-header include next to the other project includes, and replace the literal op name in the registrar.

Add after `#include "xnn_linear_cache.h"`:
```cpp
#include "etnp_lstm_schema.h"  // GENERATED — kEtnp... op-name constants (single source of truth)
```
Replace:
```cpp
const auto etnp_lstm_registrar = executorch::runtime::register_kernel(
    executorch::runtime::Kernel("etnp::lstm.out", lstm_boxed));
```
with:
```cpp
const auto etnp_lstm_registrar = executorch::runtime::register_kernel(
    executorch::runtime::Kernel(etnp::schema::kLstmOutName, lstm_boxed));
```

- [ ] **Step 3: Write `extras/lstm/runtime/CMakeLists.txt`**

```cmake
# Builds the LSTM op into libetnp_ops_lstm.a: a pure static-initializer
# registration archive, like libxnnpack_backend.a. Consumers MUST whole-archive
# it (see the installed ETNPExtras.cmake helper). Include AFTER find_package(ExecuTorch).
#
# XNNPACK (headers + libs) comes from the installed ExecuTorch prefix. Highway is
# hash-pinned/fetched (ET does not vendor it). Sets ETNP_EXTRAS_EXPECT_TUS in the
# parent scope for the nm-guard.

# --- generate the op-name header from extra.yaml (single source of truth) ---
set(_extra_yaml "${CMAKE_CURRENT_LIST_DIR}/../extra.yaml")
set(_gen_header "${CMAKE_CURRENT_BINARY_DIR}/gen/etnp_lstm_schema.h")
find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(
  COMMAND "${Python3_EXECUTABLE}"
          "${CMAKE_CURRENT_LIST_DIR}/../../generate_schema_header.py"
          "${_extra_yaml}" "${_gen_header}"
  RESULT_VARIABLE _gen_rc)
if(NOT _gen_rc EQUAL 0)
  message(FATAL_ERROR "generate_schema_header.py failed (rc=${_gen_rc})")
endif()

add_library(etnp_ops_lstm STATIC
  "${CMAKE_CURRENT_LIST_DIR}/etnp_lstm.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/lstm_cell.cc")
set_property(TARGET etnp_ops_lstm PROPERTY POSITION_INDEPENDENT_CODE ON)
target_compile_features(etnp_ops_lstm PRIVATE cxx_std_17)

# Own dir (sibling headers by bare name + Highway foreach_target re-include of
# lstm_cell.cc) and the generated-header dir.
target_include_directories(etnp_ops_lstm PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/gen")

# executorch: kernel-registration + core headers. extension_threadpool: the
# batched input projection uses the shared runtime pool. XNNPACK + pthreadpool:
# imported from the ExecuTorch prefix (find_package brought them in).
target_link_libraries(etnp_ops_lstm PUBLIC executorch extension_threadpool)
target_link_libraries(etnp_ops_lstm PRIVATE XNNPACK pthreadpool)

# --- Highway 1.4.0, hash-pinned (SHA change = supply-chain review gate) ---
set(HWY_ENABLE_CONTRIB OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
include(FetchContent)
FetchContent_Declare(highway
  URL "https://github.com/google/highway/archive/refs/tags/1.4.0.tar.gz"
  URL_HASH "SHA256=e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c")
FetchContent_MakeAvailable(highway)
target_link_libraries(etnp_ops_lstm PRIVATE hwy)

# Registrar TU the nm-guard must find post whole-archive link. etnp_lstm.cpp
# registers (register_kernel); lstm_cell.cc is an aux SIMD source (no registrar).
set(ETNP_EXTRAS_EXPECT_TUS "_GLOBAL__sub_I_etnp_lstm.cpp" PARENT_SCOPE)
```

- [ ] **Step 4: Write `extras/CMakeLists.txt` (glob driver)**

```cmake
# Standalone extras build, configured by build-runtime.sh AFTER the ET install.
# Globs each op bundle under extras/*/runtime and aggregates their registrar TUs.
# One op today (lstm); a glob now, a manifest/codegen only once ops #2-3 exist.
cmake_minimum_required(VERSION 3.24)
project(etnp_extras LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ExecuTorch from the prefix we were just installed next to.
find_package(ExecuTorch CONFIG REQUIRED)

set(ETNP_EXTRAS_LIBS "")
set(ETNP_EXTRAS_ALL_EXPECT_TUS "")
file(GLOB _op_dirs RELATIVE "${CMAKE_CURRENT_LIST_DIR}" "${CMAKE_CURRENT_LIST_DIR}/*")
foreach(_d IN LISTS _op_dirs)
  set(_rt "${CMAKE_CURRENT_LIST_DIR}/${_d}/runtime/CMakeLists.txt")
  if(EXISTS "${_rt}")
    # Mechanism refuses to build an extra with no test (strategy Decision 3).
    if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/${_d}/test")
      message(FATAL_ERROR "extra '${_d}' has no test/ dir — every extra must ship a test")
    endif()
    add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/${_d}/runtime" "${CMAKE_BINARY_DIR}/${_d}")
    list(APPEND ETNP_EXTRAS_LIBS "etnp_ops_${_d}")
    list(APPEND ETNP_EXTRAS_ALL_EXPECT_TUS ${ETNP_EXTRAS_EXPECT_TUS})
  endif()
endforeach()

# no-duplicate-op-names guard: one etnp_ops_<op> per op dir, so a dup dir name is
# impossible; assert the TU list has no repeats (dup registrar => dup op name).
list(LENGTH ETNP_EXTRAS_ALL_EXPECT_TUS _n)
list(REMOVE_DUPLICATES ETNP_EXTRAS_ALL_EXPECT_TUS)
list(LENGTH ETNP_EXTRAS_ALL_EXPECT_TUS _nd)
if(NOT _n EQUAL _nd)
  message(FATAL_ERROR "duplicate registrar TU across extras: ${ETNP_EXTRAS_ALL_EXPECT_TUS}")
endif()
message(STATUS "etnp_extras: libs=[${ETNP_EXTRAS_LIBS}] expect_tus=[${ETNP_EXTRAS_ALL_EXPECT_TUS}]")
```

- [ ] **Step 5: Port the analytic kernel test**

```bash
mkdir -p extras/lstm/test
git -C /home/corey/workspace/executorch-numpy-runtime \
  show 95a5efd:native_tests/lstm_kernel_test.cpp > extras/lstm/test/lstm_kernel_test.cpp
```
This test is torch-free: zero weights ⇒ analytic recurrence `c_t=0.5·c_{t-1}`, `h_t=0.5·tanh(c_t)`. It supplies a 4 MiB temp allocator (Gotcha D). No edit needed.

- [ ] **Step 6: Add the test target to the extras build**

Append to `extras/CMakeLists.txt` (inside the file, after the loop):
```cmake
# --- per-op tests (built against the extras libs, whole-archived) ---
set(_ET_LINK
  executorch optimized_native_cpu_ops_lib xnnpack_backend
  extension_module_static extension_data_loader extension_tensor)
if(TARGET etnp_ops_lstm)
  add_executable(lstm_kernel_test lstm/test/lstm_kernel_test.cpp)
  target_link_libraries(lstm_kernel_test PRIVATE
    ${_ET_LINK} "$<LINK_LIBRARY:WHOLE_ARCHIVE,etnp_ops_lstm>")
endif()
```

- [ ] **Step 7: Build and run the analytic test in the container**

Run (from a manylinux shell with a built `out-logging` prefix; see Task 5 for how `build-runtime.sh` drives this — for now configure standalone against an existing prefix):
```bash
cmake -B /tmp/extras-build -S extras -G Ninja \
  -DCMAKE_PREFIX_PATH="$PWD/out-logging" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build /tmp/extras-build --target lstm_kernel_test
/tmp/extras-build/lstm_kernel_test
```
Expected: `OK: etnp::lstm.out analytic recurrence correct`.

- [ ] **Step 8: Commit**

```bash
git add extras/lstm/runtime extras/lstm/test/lstm_kernel_test.cpp extras/CMakeLists.txt
git commit -m "feat(extras): port LSTM kernel -> libetnp_ops_lstm.a + analytic test"
```

---

### Task 4: Generalized manifest/nm guard (registrar survives whole-archive)

Port and generalize the shim's nm-guard so the build fails if a manifested op's registrar TU is dropped at link, or op names collide. A tiny link probe exercises it on every build (static, host-side — runs even on cross-compiled targets).

**Files:**
- Create: `cmake/assert_extras_registered.cmake`
- Create: `extras/link_probe.cpp`
- Modify: `extras/CMakeLists.txt` (probe target + POST_BUILD guard)

**Interfaces:**
- Consumes `ETNP_EXTRAS_ALL_EXPECT_TUS` (Task 3).
- The guard: `cmake -DSO=<bin> -DNM=nm -DEXPECT_TUS="<list>" -P cmake/assert_extras_registered.cmake` → fatal error if any TU absent or if a TU count implies a dropped/duplicated registrar.

- [ ] **Step 1: Write `cmake/assert_extras_registered.cmake`**

```cmake
# Post-link guard: prove each manifested op's registrar static-init TU survived
# --gc-sections/whole-archive at the final link. A dropped registrar is invisible
# until "operator not found" at model-load time. Generalized from the shim's
# assert_kernels_registered.cmake: one registrar TU per manifested op, no dups.
# Invoke: cmake -DSO=<bin> -DNM=<nm> -DEXPECT_TUS="<;-list>" -P this
if(NOT SO OR NOT EXISTS "${SO}")
  message(FATAL_ERROR "assert_extras_registered: SO not found: '${SO}'")
endif()
if(NOT NM)
  set(NM "nm")
endif()
execute_process(COMMAND "${NM}" "${SO}" OUTPUT_VARIABLE _syms
                RESULT_VARIABLE _rc ERROR_VARIABLE _err)
if(NOT _rc EQUAL 0)
  message(FATAL_ERROR "assert_extras_registered: '${NM} ${SO}' failed (rc=${_rc}): ${_err}")
endif()
foreach(_tu IN LISTS EXPECT_TUS)
  if(_tu STREQUAL "")
    continue()
  endif()
  string(REGEX REPLACE "\\." "\\\\." _tu_re "${_tu}")
  string(REGEX MATCHALL "${_tu_re}" _m "${_syms}")
  list(LENGTH _m _cnt)
  if(_cnt LESS 1)
    message(FATAL_ERROR
      "extras registrar '${_tu}' was dropped from ${SO}: static-init TU absent. "
      "whole-archive regressed -> custom op not found at model-load time.")
  endif()
endforeach()
message(STATUS "assert_extras_registered: all extras registrar TUs present in ${SO}: [${EXPECT_TUS}]")
```

- [ ] **Step 2: Write `extras/link_probe.cpp`**

```cpp
// Minimal link probe: exists only so the nm-guard can assert the extras'
// registrar TUs survive a real whole-archive link. Never run; linking is enough.
int main() { return 0; }
```

- [ ] **Step 3: Add the probe target + POST_BUILD guard to `extras/CMakeLists.txt`**

Append (after the test block from Task 3):
```cmake
# --- static registration guard (every build, incl. cross-compiled targets) ---
add_executable(etnp_extras_link_probe link_probe.cpp)
set(_probe_whole "")
foreach(_lib IN LISTS ETNP_EXTRAS_LIBS)
  list(APPEND _probe_whole "$<LINK_LIBRARY:WHOLE_ARCHIVE,${_lib}>")
endforeach()
target_link_libraries(etnp_extras_link_probe PRIVATE ${_ET_LINK} ${_probe_whole})
add_custom_command(TARGET etnp_extras_link_probe POST_BUILD
  COMMAND ${CMAKE_COMMAND} -DSO=$<TARGET_FILE:etnp_extras_link_probe> -DNM=nm
          "-DEXPECT_TUS=${ETNP_EXTRAS_ALL_EXPECT_TUS}"
          -P ${CMAKE_CURRENT_LIST_DIR}/../cmake/assert_extras_registered.cmake
  VERBATIM)
```

- [ ] **Step 4: Build the probe — guard passes on a correct link**

Run:
```bash
cmake -B /tmp/extras-build -S extras -G Ninja \
  -DCMAKE_PREFIX_PATH="$PWD/out-logging" -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build /tmp/extras-build --target etnp_extras_link_probe
```
Expected: build succeeds; STATUS line `assert_extras_registered: all extras registrar TUs present ... [_GLOBAL__sub_I_etnp_lstm.cpp]`.

- [ ] **Step 5: Prove the guard actually fails on a dropped registrar (negative test)**

Temporarily link the probe WITHOUT whole-archive to confirm the guard catches it:
```bash
cmake -B /tmp/extras-neg -S extras -G Ninja \
  -DCMAKE_PREFIX_PATH="$PWD/out-logging" -DCMAKE_POSITION_INDEPENDENT_CODE=ON
# Manually link probe against the plain archive (no whole-archive) and run the guard:
c++ extras/link_probe.cpp /tmp/extras-neg/lstm/libetnp_ops_lstm.a -o /tmp/probe_plain \
  $(pkg-config --libs 2>/dev/null; true) 2>/dev/null || \
  c++ extras/link_probe.cpp -Wl,--gc-sections /tmp/extras-neg/lstm/libetnp_ops_lstm.a -o /tmp/probe_plain
cmake -DSO=/tmp/probe_plain -DNM=nm \
  "-DEXPECT_TUS=_GLOBAL__sub_I_etnp_lstm.cpp" \
  -P cmake/assert_extras_registered.cmake; echo "guard rc=$?"
```
Expected: FATAL_ERROR ("registrar ... was dropped"), non-zero rc — proving the guard is not a no-op. (Clean up `/tmp/probe_plain`.)

- [ ] **Step 6: Commit**

```bash
git add cmake/assert_extras_registered.cmake extras/link_probe.cpp extras/CMakeLists.txt
git commit -m "feat(extras): generalized nm-guard — registrar TUs survive whole-archive"
```

---

### Task 5: Install `ETNPExtras.cmake` (whole-archive helper) + wire into `build-runtime.sh`

Install the archive, header, and a self-describing `ETNPExtras.cmake` into the prefix; make `build-runtime.sh` build+install the extras after the ET install (so every variant ships the op) and pass Highway's license through. Verified by a consumer-style shell test.

**Files:**
- Create: `extras/cmake/ETNPExtrasConfig.cmake.in`
- Modify: `extras/lstm/runtime/CMakeLists.txt` (install rules for the archive + header)
- Modify: `extras/CMakeLists.txt` (install the config + set install of headers)
- Modify: `build-runtime.sh` (extras build/install step; Highway license passthrough)
- Test: `test/extras_members.test.sh`

**Interfaces:**
- Produces installed `lib/libetnp_ops_lstm.a`, `include/etnp/lstm.h`, `lib/cmake/ETNPExtras/ETNPExtras.cmake`.
- `ETNPExtras.cmake` provides: imported target `etnp_ops_lstm`; `set(ETNP_EXTRAS_WHOLE_ARCHIVE_LIBS etnp_ops_lstm)`; function `etnp_extras_whole_archive(<consumer_target>)`.

- [ ] **Step 1: Add install rules to `extras/lstm/runtime/CMakeLists.txt`**

Append:
```cmake
# Install the archive + a public header carrying the op-name constants.
install(TARGETS etnp_ops_lstm ARCHIVE DESTINATION lib)
install(FILES "${_gen_header}" DESTINATION include/etnp RENAME lstm.h)
```

- [ ] **Step 2: Write `extras/cmake/ETNPExtrasConfig.cmake.in`**

```cmake
# ETNPExtras.cmake — shipped INSIDE the tarball. Self-describing whole-archive
# contract for the first-party custom ops in this runtime (extras-only; ET's own
# backend/ops archives still need whole-archiving per ET's guidance — see the
# consumer guide). Include AFTER find_package(executorch).
#
#   find_package(executorch CONFIG REQUIRED PATHS "<prefix>/lib/cmake/ExecuTorch")
#   include("<prefix>/lib/cmake/ETNPExtras/ETNPExtras.cmake")
#   etnp_extras_whole_archive(my_consumer_target)
#
# Paths are relative to THIS file, so the tree stays relocatable.
get_filename_component(_etnp_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

add_library(etnp_ops_lstm STATIC IMPORTED)
set_target_properties(etnp_ops_lstm PROPERTIES
  IMPORTED_LOCATION "${_etnp_prefix}/lib/libetnp_ops_lstm.a"
  INTERFACE_INCLUDE_DIRECTORIES "${_etnp_prefix}/include")

# The archives a consumer MUST whole-archive (pure static-init registration TUs).
# Future extras append here automatically; consumers never edit a link line.
set(ETNP_EXTRAS_WHOLE_ARCHIVE_LIBS @ETNP_EXTRAS_INSTALL_LIBS@)

# Apply the correct per-OS whole-archive wrapping to <target>'s link.
function(etnp_extras_whole_archive target)
  foreach(_lib IN LISTS ETNP_EXTRAS_WHOLE_ARCHIVE_LIBS)
    if(APPLE)
      target_link_libraries(${target} PRIVATE
        "-Wl,-force_load,$<TARGET_PROPERTY:${_lib},IMPORTED_LOCATION>")
    elseif(MSVC)
      target_link_libraries(${target} PRIVATE ${_lib}
        "-WHOLEARCHIVE:$<TARGET_PROPERTY:${_lib},IMPORTED_LOCATION>")
    else()  # GNU ld / Linux
      target_link_libraries(${target} PRIVATE
        "$<LINK_LIBRARY:WHOLE_ARCHIVE,${_lib}>")
    endif()
  endforeach()
endfunction()
```

- [ ] **Step 3: Configure + install the config from `extras/CMakeLists.txt`**

Append:
```cmake
# Render ETNPExtras.cmake with the concrete whole-archive lib list and install it.
string(REPLACE ";" " " ETNP_EXTRAS_INSTALL_LIBS "${ETNP_EXTRAS_LIBS}")
configure_file("${CMAKE_CURRENT_LIST_DIR}/cmake/ETNPExtrasConfig.cmake.in"
               "${CMAKE_BINARY_DIR}/ETNPExtras.cmake" @ONLY)
install(FILES "${CMAKE_BINARY_DIR}/ETNPExtras.cmake"
        DESTINATION lib/cmake/ETNPExtras)
```

- [ ] **Step 4: Wire the extras build/install into `build-runtime.sh`**

In `build-runtime.sh`, immediately AFTER the `cmake --install "$ET_BUILD" --prefix "$PREFIX"` line and BEFORE the `>> measuring relocatability` block (so the relocatability + syslib rewrites also cover `ETNPExtras.cmake`), insert:

```bash
echo ">> building extras (custom ops) against the installed prefix"
EXTRAS_BUILD="$ET_BUILD/../etnp-extras-$VARIANT"
cmake -B "$EXTRAS_BUILD" -S "$HERE/extras" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
# Building the link probe runs the POST_BUILD nm-guard (registrar survived).
cmake --build "$EXTRAS_BUILD" -j"$(nproc)"
cmake --install "$EXTRAS_BUILD" --prefix "$PREFIX"
```

- [ ] **Step 5: Pass Highway's license through in `build-runtime.sh`**

The existing license passthrough only scans ET's `third-party/`/`backends/`. Highway is fetched by the extras build. In the `>> license passthrough` block, after the ET license loop, add:

```bash
# Highway (fetched by the extras build) — its LICENSE is not in ET's tree.
hwy_lic="$(find "$EXTRAS_BUILD" -path '*highway-src/LICENSE' -type f 2>/dev/null | head -n1 || true)"
if [ -n "$hwy_lic" ]; then
  cp "$hwy_lic" "$PREFIX/THIRD-PARTY-NOTICES/highway_LICENSE"
else
  echo ">> WARNING: Highway LICENSE not found under $EXTRAS_BUILD" >&2
fi
```

- [ ] **Step 6: Write the failing consumer-members shell test `test/extras_members.test.sh`**

```bash
#!/usr/bin/env bash
# Asserts a built prefix ships the extras members and that ETNPExtras.cmake is
# relocatable (no absolute build-prefix leaked). PREFIX defaults to out-logging.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$here/../out-logging}"
fail=0
for m in lib/libetnp_ops_lstm.a include/etnp/lstm.h lib/cmake/ETNPExtras/ETNPExtras.cmake \
         THIRD-PARTY-NOTICES/highway_LICENSE; do
  if [ ! -e "$PREFIX/$m" ]; then echo "MISSING: $m"; fail=1; fi
done
# op name baked into the header matches the frozen contract
grep -q 'etnp::lstm.out' "$PREFIX/include/etnp/lstm.h" || { echo "op-name constant missing"; fail=1; }
# relocatable: no absolute prefix path in the shipped config
if grep -q "$(cd "$PREFIX" && pwd)" "$PREFIX/lib/cmake/ETNPExtras/ETNPExtras.cmake" 2>/dev/null; then
  echo "ETNPExtras.cmake leaked an absolute prefix path"; fail=1
fi
[ "$fail" -eq 0 ] && echo "OK: extras members present + relocatable" || exit 1
```

- [ ] **Step 7: Run a full variant build, then the test**

Run (in manylinux, with an ET checkout at `./executorch`):
```bash
export PATH=/opt/python/cp312-cp312/bin:$PATH
./build-runtime.sh --variant logging --prefix "$PWD/out-logging" --et-src "$PWD/executorch"
PREFIX="$PWD/out-logging" bash test/extras_members.test.sh
```
Expected: build succeeds (extras built + guard passed + installed); test prints `OK: extras members present + relocatable`.

- [ ] **Step 8: Commit**

```bash
git add extras/cmake/ETNPExtrasConfig.cmake.in extras/lstm/runtime/CMakeLists.txt \
        extras/CMakeLists.txt build-runtime.sh test/extras_members.test.sh
git commit -m "feat(extras): install ETNPExtras.cmake whole-archive helper; wire into build-runtime.sh"
```

---

### Task 6: Port Face 3 (AOT definition), schema read from `extra.yaml`

Port the torch AOT op so a model calling `etnp::lstm` lowers to a `.pte` referencing `etnp::lstm.out`, with schema strings sourced from `extra.yaml` (no drift).

**Files:**
- Create (port + modify): `extras/lstm/aot/etnp_lstm_op.py`
- Test: `extras/lstm/test/test_aot_defines_op.py`

**Interfaces:**
- Produces importable module `etnp_lstm_op` that, on import, registers `etnp::lstm` + `etnp::lstm.out` (CompositeExplicitAutograd + fake). Consumed by Task 7's round-trip.

- [ ] **Step 1: Port the AOT source**

```bash
mkdir -p extras/lstm/aot
git -C /home/corey/workspace/executorch-numpy-runtime \
  show 95a5efd:tools/etnp_lstm_op.py > extras/lstm/aot/etnp_lstm_op.py
```

- [ ] **Step 2: Modify the two `_lib.define(...)` calls to read `extra.yaml`**

In `extras/lstm/aot/etnp_lstm_op.py`, replace the hardcoded define strings with values from the single source. Replace:
```python
_lib = Library("etnp", "DEF")
_lib.define(
    "lstm(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh, "
    "Tensor? b_ih, Tensor? b_hh) -> (Tensor, Tensor, Tensor)")
_lib.define(
    "lstm.out(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh, "
    "Tensor? b_ih, Tensor? b_hh, *, Tensor(a!) output, Tensor(b!) hn, Tensor(c!) cn) "
    "-> (Tensor(a!), Tensor(b!), Tensor(c!))")
```
with:
```python
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))  # extras/
from generate_schema_header import load_schema
_schema = load_schema(pathlib.Path(__file__).resolve().parents[1] / "extra.yaml")
_lib = Library(_schema["namespace"], "DEF")
_lib.define(_schema["functional"])
_lib.define(_schema["out"])
```
(The docstring, `_lstm_ref`, the two `@impl` CompositeExplicitAutograd registrations, and `@register_fake("etnp::lstm")` are unchanged — that is the proven "survives lowering" recipe, Gotcha C.)

- [ ] **Step 3: Write the failing test `extras/lstm/test/test_aot_defines_op.py`**

```python
import torch  # noqa: F401  (registers the dispatcher)

def test_import_registers_lstm_out():
    import extras.lstm.aot.etnp_lstm_op  # noqa: F401  side-effect: defines the op
    # The .out overload must exist under the frozen name, else exports won't lower.
    assert hasattr(torch.ops.etnp, "lstm")
    # functional fake shape-propagates
    T, B, I, H = 3, 2, 4, 5
    inp = torch.randn(T, B, I)
    h0 = torch.zeros(B, H); c0 = torch.zeros(B, H)
    w_ih = torch.randn(4 * H, I); w_hh = torch.randn(4 * H, H)
    out, hn, cn = torch.ops.etnp.lstm(inp, h0, c0, w_ih, w_hh, None, None)
    assert tuple(out.shape) == (T, B, H)
    assert tuple(hn.shape) == (B, H) and tuple(cn.shape) == (B, H)
```

- [ ] **Step 4: Run the test (needs torch)**

Run: `python -m pytest extras/lstm/test/test_aot_defines_op.py -v`
Expected: PASS (run in the export/build venv with `torch==2.12.0+cpu`).

- [ ] **Step 5: Commit**

```bash
git add extras/lstm/aot/etnp_lstm_op.py extras/lstm/test/test_aot_defines_op.py
git commit -m "feat(extras): port LSTM AOT op; schema read from extra.yaml"
```

---

### Task 7: Face 4 — live torch round-trip test + C++ runner

The definitive proof: export an `nn.LSTM` through the custom op to a `.pte`, run it against the *built tarball* via a C++ runner that uses the shipped whole-archive helper, and compare to torch eager at 1e-4.

**Files:**
- Create: `extras/lstm/test/lstm_runner.cpp`
- Create: `extras/lstm/test/CMakeLists.txt`
- Create: `extras/lstm/test/test_lstm_roundtrip.py`

**Interfaces:**
- Consumes: the installed prefix (`etnp_ops_lstm`, `ETNPExtras.cmake`), `etnp_lstm_op.py` (Task 6).
- `lstm_runner <model.pte> <inputs.bin> <out.bin>`: loads the `.pte`, runs it with the given flat float inputs, writes flat float outputs.

- [ ] **Step 1: Write the C++ runner `extras/lstm/test/lstm_runner.cpp`**

```cpp
// Loads a .pte using etnp::lstm.out and runs it against the BUILT tarball —
// the first real exercise of the shipped consumer contract (whole-archived via
// ETNPExtras.cmake). Reads flat little-endian float32 inputs, writes float32 output.
//   lstm_runner <model.pte> <inputs.bin> <out.bin>
// inputs.bin = concat of input,h0,c0,w_ih,w_hh,b_ih,b_hh (row-major, the schema order).
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <vector>

#include <executorch/extension/module/module.h>
#include <executorch/extension/tensor/tensor_ptr.h>

using executorch::extension::Module;
using executorch::extension::make_tensor_ptr;
using executorch::runtime::EValue;

static std::vector<float> read_floats(const char* p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p); std::exit(2); }
  const std::streamsize n = f.tellg(); f.seekg(0);
  std::vector<float> v(static_cast<size_t>(n) / sizeof(float));
  f.read(reinterpret_cast<char*>(v.data()), n);
  return v;
}

int main(int argc, char** argv) {
  if (argc != 4) { std::fprintf(stderr, "usage: lstm_runner model inputs out\n"); return 2; }
  // Shapes are fixed by the test that generates inputs.bin (see the .py).
  // T,B,I,H are passed via env to keep the runner tiny and shape-agnostic.
  const int T = std::atoi(std::getenv("LSTM_T"));
  const int B = std::atoi(std::getenv("LSTM_B"));
  const int I = std::atoi(std::getenv("LSTM_I"));
  const int H = std::atoi(std::getenv("LSTM_H"));

  std::vector<float> blob = read_floats(argv[2]);
  size_t off = 0;
  auto take = [&](size_t n) { const float* p = blob.data() + off; off += n; return p; };
  auto in  = take((size_t)T * B * I);
  auto h0  = take((size_t)B * H);
  auto c0  = take((size_t)B * H);
  auto wih = take((size_t)4 * H * I);
  auto whh = take((size_t)4 * H * H);
  auto bih = take((size_t)4 * H);
  auto bhh = take((size_t)4 * H);

  auto t_in  = make_tensor_ptr({T, B, I}, const_cast<float*>(in));
  auto t_h0  = make_tensor_ptr({B, H},   const_cast<float*>(h0));
  auto t_c0  = make_tensor_ptr({B, H},   const_cast<float*>(c0));
  auto t_wih = make_tensor_ptr({4 * H, I}, const_cast<float*>(wih));
  auto t_whh = make_tensor_ptr({4 * H, H}, const_cast<float*>(whh));
  auto t_bih = make_tensor_ptr({4 * H},  const_cast<float*>(bih));
  auto t_bhh = make_tensor_ptr({4 * H},  const_cast<float*>(bhh));

  Module module(argv[1]);
  std::vector<EValue> inputs = {*t_in, *t_h0, *t_c0, *t_wih, *t_whh, *t_bih, *t_bhh};
  const auto res = module.forward(inputs);
  if (!res.ok()) { std::fprintf(stderr, "forward failed\n"); return 1; }
  const auto out = res.get()[0].toTensor();  // output [T,B,H]

  std::ofstream of(argv[3], std::ios::binary);
  of.write(reinterpret_cast<const char*>(out.const_data_ptr<float>()),
           (std::streamsize)out.numel() * sizeof(float));
  return 0;
}
```

- [ ] **Step 2: Write `extras/lstm/test/CMakeLists.txt` (runner links via the installed helper)**

```cmake
# The runner links the INSTALLED extras exactly as a downstream consumer would:
# find_package(executorch) + include the shipped ETNPExtras.cmake + call the helper.
cmake_minimum_required(VERSION 3.24)
project(etnp_lstm_runner LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(executorch CONFIG REQUIRED)
include("${ETNP_PREFIX}/lib/cmake/ETNPExtras/ETNPExtras.cmake")

add_executable(lstm_runner lstm_runner.cpp)
target_link_libraries(lstm_runner PRIVATE
  executorch optimized_native_cpu_ops_lib xnnpack_backend
  extension_module_static extension_data_loader extension_tensor)
etnp_extras_whole_archive(lstm_runner)   # shipped helper wraps etnp_ops_lstm
```

- [ ] **Step 3: Write the round-trip test `extras/lstm/test/test_lstm_roundtrip.py`**

```python
"""Live round-trip: nn.LSTM -> export+lower through etnp::lstm -> run vs a C++
runner built against the installed tarball -> compare to torch eager @ 1e-4.
Requires: torch, a built+installed prefix (ETNP_PREFIX), cmake, a C++ compiler.
Replaces the MVP committed-golden workaround."""
import os, pathlib, struct, subprocess, sys, tempfile
import numpy as np
import torch

HERE = pathlib.Path(__file__).resolve().parent
PREFIX = pathlib.Path(os.environ["ETNP_PREFIX"]).resolve()

sys.path.insert(0, str(HERE.parents[2]))          # repo root, for extras.*
import extras.lstm.aot.etnp_lstm_op  # noqa: F401  registers the op

T, B, I, H = 5, 2, 4, 3


def _weights(lstm):
    # torch.nn.LSTM single-layer names: weight_ih_l0 [4H,I], weight_hh_l0 [4H,H],
    # bias_ih_l0/bias_hh_l0 [4H]. Gate order i,f,g,o matches the kernel.
    return (lstm.weight_ih_l0.detach(), lstm.weight_hh_l0.detach(),
            lstm.bias_ih_l0.detach(), lstm.bias_hh_l0.detach())


class Wrap(torch.nn.Module):
    def __init__(self, wih, whh, bih, bhh):
        super().__init__()
        self.wih, self.whh, self.bih, self.bhh = wih, whh, bih, bhh

    def forward(self, x, h0, c0):
        return torch.ops.etnp.lstm(x, h0, c0, self.wih, self.whh, self.bih, self.bhh)


def _build_runner(build_dir):
    subprocess.run(["cmake", "-B", str(build_dir), "-S", str(HERE), "-G", "Ninja",
                    f"-DCMAKE_PREFIX_PATH={PREFIX}", f"-DETNP_PREFIX={PREFIX}"], check=True)
    subprocess.run(["cmake", "--build", str(build_dir), "--target", "lstm_runner"], check=True)
    return build_dir / "lstm_runner"


def test_roundtrip_matches_eager():
    torch.manual_seed(0)
    lstm = torch.nn.LSTM(I, H, num_layers=1, batch_first=False)
    wih, whh, bih, bhh = _weights(lstm)
    x = torch.randn(T, B, I)
    h0 = torch.zeros(B, H); c0 = torch.zeros(B, H)

    # eager reference (nn.LSTM wants h/c as [num_layers, B, H])
    eager_out, _ = lstm(x, (h0.unsqueeze(0), c0.unsqueeze(0)))

    # export + lower (no partitioner -> op stays opaque -> ToOutVarPass -> lstm.out)
    from executorch.exir import to_edge_transform_and_lower
    ep = torch.export.export(Wrap(wih, whh, bih, bhh), (x, h0, c0))
    pte = to_edge_transform_and_lower(ep).to_executorch()
    tmp = pathlib.Path(tempfile.mkdtemp())
    model = tmp / "lstm.pte"
    model.write_bytes(pte.buffer)

    # sanity: the lowered program references exactly our out op
    assert b"etnp::lstm.out" in pte.buffer

    # flat inputs in schema order
    def flat(*ts):
        return b"".join(struct.pack(f"{t.numel()}f", *t.flatten().tolist()) for t in ts)
    (tmp / "in.bin").write_bytes(flat(x, h0, c0, wih, whh, bih, bhh))

    runner = _build_runner(tmp / "rbuild")
    env = {**os.environ, "LSTM_T": str(T), "LSTM_B": str(B),
           "LSTM_I": str(I), "LSTM_H": str(H)}
    subprocess.run([str(runner), str(model), str(tmp / "in.bin"), str(tmp / "out.bin")],
                   check=True, env=env)

    got = np.frombuffer((tmp / "out.bin").read_bytes(), dtype=np.float32).reshape(T, B, H)
    ref = eager_out.detach().numpy()
    assert np.allclose(got, ref, rtol=1e-4, atol=1e-4), np.abs(got - ref).max()
```

- [ ] **Step 4: Run the round-trip against a built prefix**

Run (in the build venv/container, after Task 5's `build-runtime.sh` produced `out-logging`):
```bash
ETNP_PREFIX="$PWD/out-logging" python -m pytest extras/lstm/test/test_lstm_roundtrip.py -v
```
Expected: PASS — the `.pte` contains `etnp::lstm.out`, the runner loads+runs it against the tarball, and output matches eager within 1e-4.

- [ ] **Step 5: Commit**

```bash
git add extras/lstm/test/lstm_runner.cpp extras/lstm/test/CMakeLists.txt \
        extras/lstm/test/test_lstm_roundtrip.py
git commit -m "feat(extras): live torch round-trip test + C++ runner (consumer contract)"
```

---

### Task 8: CI — gate the release on the round-trip (executable targets)

The static guard already runs inside every `build` matrix cell (Task 4/5). Add the live round-trip as a gating step in `release.yml`'s `build` job, only on targets that can execute a built binary.

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add a round-trip gate step to the `build` job**

In `.github/workflows/release.yml`, after the `Build runtime` step and before `Package`, insert (both current linux combos use native runners — x86_64 and `ubuntu-24.04-arm` — so both execute; if a future build-only/cross target is added, gate this step on it):

```yaml
      - name: LSTM round-trip gate (export -> run vs eager)
        run: |
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          pip install numpy pytest
          ETNP_PREFIX="$PWD/out" python -m pytest \
            extras/lstm/test/test_lstm_roundtrip.py -v
```

Notes for the implementer:
- `build-runtime.sh` already `pip install`s `torch==2.12.0+cpu` + `pyyaml`; the step adds only `numpy`/`pytest`.
- `--prefix "$PWD/out"` is what the `Build runtime` step used, so `ETNP_PREFIX=$PWD/out`.
- The op is variant-identical, but running per matrix cell is cheap and also covers the aarch64 SIMD path — keep it unguarded across variants/platforms unless a non-executing target is later added.

- [ ] **Step 2: Validate the workflow YAML**

Run:
```bash
python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('yaml ok')"
```
Expected: `yaml ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: gate release build on the LSTM live round-trip (executable targets)"
```

---

### Task 9: Docs + third-party notice + tarball re-roll

Ship the consumer contract as a self-contained doc, surface the new Highway dependency in top-level docs, and note the re-roll mechanics. (Highway's LICENSE passthrough was wired in Task 5.)

**Files:**
- Create: `docs/lstm-op-consumer-guide.md`
- Modify: `README.md`
- Test: `test/extras_members.test.sh` already asserts `THIRD-PARTY-NOTICES/highway_LICENSE` (Task 5) — no new test.

- [ ] **Step 1: Write `docs/lstm-op-consumer-guide.md`**

Content (self-contained; do NOT diff against `handover-to-engine.md`):
```markdown
# Consumer Guide: `etnp::lstm.out`

This runtime ships a first-party custom LSTM operator, `etnp::lstm.out`, inside
**every variant** of the tarball (bare/logging/devtools) on every platform. Any
consumer that links the runtime and whole-archives the op gets it registered at
load time — no build flag.

## The op
- **Name (frozen, baked into `.pte`s):** `etnp::lstm.out` (functional `etnp::lstm`).
- **Schema:** single-layer, unidirectional, `batch_first=False`, float32, contiguous.
  `input [T,B,I]`, `h0/c0 [B,H]`, `w_ih [4H,I]`, `w_hh [4H,H]`, optional biases `[4H]`;
  `output [T,B,H]`, `hn/cn [B,H]`. Gate order i,f,g,o.
- Produce a `.pte` with the AOT definition in `extras/lstm/aot/etnp_lstm_op.py`
  (`to_edge_transform_and_lower` with **no** partitioner keeps the op opaque;
  `ToOutVarPass` yields `etnp::lstm.out`).

## Linking (the whole-archive requirement)
`libetnp_ops_lstm.a` is a pure static-initializer registration archive: unless it
is whole-archived at your final link it is GC'd away and you get
"operator etnp::lstm.out not found" at model-load time. The tarball ships a helper
so you don't hand-roll the per-OS flags:

    find_package(executorch CONFIG REQUIRED PATHS "<prefix>/lib/cmake/ExecuTorch")
    include("<prefix>/lib/cmake/ETNPExtras/ETNPExtras.cmake")
    add_library(my_consumer SHARED ...)
    target_link_libraries(my_consumer PRIVATE executorch ...)
    etnp_extras_whole_archive(my_consumer)   # applies --whole-archive / -force_load / /WHOLEARCHIVE:

**ET's own archives still need whole-archiving too.** `ETNPExtras` covers only the
first-party extras (`etnp_ops_lstm`). ExecuTorch's `xnnpack_backend`,
`portable_ops_lib`/`optimized_native_cpu_ops_lib`, etc. must likewise be
whole-archived per ExecuTorch's guidance — `ETNPExtras` deliberately does not
enumerate them (they drift across ET versions).

## Performance envelope (why it exists)
Versus the naive decomposition ExecuTorch emits: the custom `.pte` is **constant in
T** (naive grows with T; 2.8×–27× smaller over T=16→256 at H=32), **faster at every
benchmarked (T,H)** (1.66×–9.78× across H∈{32,64,128}, T∈{16,64,256}), and exports
shapes the naive path cannot complete (T=256,H=128 never finishes a 120s budget).
The custom op is the default choice for the supported LSTM shape.

## Cross-platform note
The live round-trip test gates every *executable* CI target (today linux-x86_64 and
linux-aarch64, both native runners). When macOS/Windows/arm64 targets gain runners,
run the round-trip there too — the per-OS whole-archive path in the helper above is
exactly what it validates.
```

- [ ] **Step 2: Surface Highway in `README.md`**

Add a short dependency note to `README.md` (place near the existing build/dependency description):
```markdown
## Bundled first-party op & dependencies

This runtime ships the custom `etnp::lstm.out` operator in every variant (see
`docs/lstm-op-consumer-guide.md`). Building it pulls one additional pinned
dependency beyond ExecuTorch's own third-party set:

- **Google Highway 1.4.0** (SIMD; SHA256 `e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c`)
  — fetched by the `extras/` build and linked into `libetnp_ops_lstm.a`. Its license
  is passed through into the tarball's `THIRD-PARTY-NOTICES/`.

XNNPACK (already part of ExecuTorch) is reused from the built prefix; no new XNNPACK
dependency is introduced.
```

- [ ] **Step 3: Verify docs reference real, shipped paths**

Run:
```bash
grep -q 'etnp_extras_whole_archive' docs/lstm-op-consumer-guide.md && \
grep -q 'Highway 1.4.0' README.md && echo "docs ok"
```
Expected: `docs ok`.

- [ ] **Step 4: Commit**

```bash
git add docs/lstm-op-consumer-guide.md README.md
git commit -m "docs: LSTM op consumer guide + surface Highway 1.4.0 dependency"
```

- [ ] **Step 5: Re-roll note (no code) — cutting the tarball that ships the op**

The op ships on the next release tag. To cut it: push a new `v<etver>-<pkgrev>` tag
(bump `pkgrev` for a re-roll of the same ET version). `release.yml` builds all three
variants × both platforms (each now carrying `etnp_ops_lstm`, gated by the round-trip),
`package.sh` tars them, `gen-pin.sh` emits `EtRuntimePin.cmake`. The numpy-runtime
follow-up (pin bump + torch-free consumer smoke test, Strategy Decision 2) happens in
*that* repo — out of scope here. This step is documentation; nothing to commit.

---

## Immediate follow-up (out of scope for this plan, do next)

**Stand up a dedicated QA gate (push/PR CI).** Today the only workflow is
`release.yml` (on tag) — appropriate while this repo merely *rebuilt an upstream
ExecuTorch release*, where correctness was ExecuTorch's to own. That calculus
changes the moment this repo ships **its own custom code** (`etnp::lstm.out`): we
now own QA of it, and validating custom code only at release-tag time is too late.

This plan gates the release build (Task 8) and runs the static guard on every build
(Task 4/5), which is the minimum to ship safely. The follow-up is a separate
`ci.yml` triggered on push/PR that, inside the local `manylinux_2_28` container,
builds one variant (`logging`/`linux-x86_64`) and runs the extras test suite — the
analytic kernel test, the nm-guard, and the live round-trip — so regressions are
caught on the branch, not at tag time. Scope it as its own brainstorm/plan cycle:
decide caching/build-time budget (a full ET-from-source build per PR is expensive —
consider `SKIP_ET_BUILD=1` reuse or a prebuilt-prefix cache), and which subset gates
vs. runs nightly. Track as the next work item after this plan lands.

## Environment note

The `manylinux_2_28` container is present locally and confirmed working, so the
container-bound steps (Tasks 3, 5, 7, 8) can be executed directly — no container
setup is a blocker for this plan.

---

## Self-Review

**Spec coverage:**
- Objective 1 (kernel compiled/whole-archived/guarded) → Tasks 3, 4, 5. ✓
- Objective 2 (always-on every variant, name frozen) → Task 5 (extras built inside each `build-runtime.sh` variant call), Global Constraints, Task 3 Step 2. ✓
- Objective 3 (live round-trip @1e-4) → Task 7. ✓
- Objective 4 (extras bundle, convention not framework) → Tasks 2–5 (glob, no codegen framework). ✓
- Face 1 → Task 3; Face 2 → Task 2 + Task 3 Step 2 + Task 6 Step 2; Face 3 → Task 6; Face 4 → Task 7. ✓
- XNNPACK-from-prefix → Task 3 CMake; Highway fetch → Task 3; Highway license → Task 5; Highway docs → Task 9. ✓
- Shipped whole-archive declaration (extras-only, per-OS helper) → Task 5. ✓
- Manifest guard (one TU/op, no dup names, static/every build) → Task 4 + Task 3 Step 4 (dup check). ✓
- Static-guard-everywhere vs execute-per-target split → Task 4 (probe, all builds) vs Task 7/8 (round-trip, executable targets). ✓
- Consumer doc (clean, not editing handover) → Task 9; `handover-to-engine.md` untouched. ✓
- `package.sh` unchanged for members (ride lib/include) → confirmed in Task 5 (install into prefix; existing `package.sh` copies `lib/`+`include/`). ✓
- De-risk unknowns (make_boxed cap, xnnpack, aarch64 executes) → Task 1. ✓

**Placeholder scan:** No TBD/TODO; every code step has full content; verbatim ports use exact `git show` commands with verification. ✓

**Type consistency:** `etnp_ops_lstm` target, `ETNP_EXTRAS_WHOLE_ARCHIVE_LIBS`, `etnp_extras_whole_archive()`, `ETNP_EXTRAS_EXPECT_TUS`/`ETNP_EXTRAS_ALL_EXPECT_TUS`, `_GLOBAL__sub_I_etnp_lstm.cpp`, `load_schema()`, `kLstmOutName`, `ETNP_PREFIX`, `LSTM_{T,B,I,H}` env — used consistently across tasks. ✓

**One residual risk to watch during execution:** the exact target names `XNNPACK` / `pthreadpool` exported by the ET prefix's `executorch-config.cmake` (Task 3 Step 3 links them by name). If `find_package(ExecuTorch)` does not export those as targets, link via the installed `lib/libXNNPACK.a` / `lib/libpthreadpool.a` paths instead — confirm at Task 3 Step 7 (the first extras build) and adjust the two `target_link_libraries(... PRIVATE XNNPACK pthreadpool)` names if needed.
