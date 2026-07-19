# ExecuTorch's exported CMake targets do not propagate their C++17 requirement

**Status:** held, not filed. An ET release is ~1 week out (as of 2026-07-18); if this reappears or
changes shape there, update this note before opening anything upstream.

**Severity:** latent. Nothing is currently broken in our consumers — see "Why this is not biting us"
— but the requirement is unenforced and MSVC-only, which is a bad combination for a future break.

## TL;DR

ExecuTorch's headers hard-`#error` below C++17. ExecuTorch's build sets `CMAKE_CXX_STANDARD 17` for
**itself**, but that is a build-time variable and is **not** a usage requirement, so it is not
exported. A consumer doing `find_package(ExecuTorch)` and including ET headers therefore inherits
nothing about the language standard and must know to request C++17 on its own.

This is invisible on Linux (GCC defaults to `gnu++17`) and fails hard on MSVC (defaults to C++14):

```
compiler.h(36): fatal error C1189: #error: "You need C++17 to compile ExecuTorch"
```

Found when `test/consumer/probe.cpp` in this repo started including ET headers for the first time.
Fixed on our side with `target_compile_features(pic_probe PRIVATE cxx_std_17)`.

## Evidence

The guard (`runtime/platform/compiler.h:36`, ET v1.3.1) keys on `_MSVC_LANG` for MSVC and
`__cplusplus` elsewhere — so `/std:c++17` alone satisfies it and `/Zc:__cplusplus` is **not** needed:

```cpp
#if (defined(_MSC_VER) && (!defined(_MSVC_LANG) || _MSVC_LANG < 201703L)) || \
    (!defined(_MSC_VER) && __cplusplus < 201703L)
#error "You need C++17 to compile ExecuTorch"
#endif
```

What the installed package actually exports (checked on **both** a Linux and a Windows build of
v1.3.1 — `lib/cmake/ExecuTorch/ExecuTorchTargets.cmake`):

| Property | Exported? |
|---|---|
| `INTERFACE_COMPILE_DEFINITIONS` | ✅ |
| `INTERFACE_COMPILE_OPTIONS` | ✅ (and correctly platform-aware) |
| `INTERFACE_INCLUDE_DIRECTORIES` | ✅ |
| `INTERFACE_LINK_LIBRARIES` / `INTERFACE_LINK_OPTIONS` | ✅ (`/WHOLEARCHIVE:` on MSVC, `--whole-archive` on GNU) |
| **`INTERFACE_COMPILE_FEATURES`** | ❌ **absent** |

`executorch-config.cmake` sets no global `CMAKE_*` variables either, so there is no side-channel that
happens to fix it up. ET is demonstrably careful about platform differences in its exported *link*
options; the language standard is simply never expressed as a usage requirement.

## Why this is not biting us

**The guard is `#error`, not undefined behaviour.** A build either fails loudly at compile time or
C++17 was set. So the fact that both our Windows consumers build at all is *proof* they are already
getting C++17 from somewhere. There is no silent-corruption variant of this bug.

Our `test/consumer` caught it only because it is deliberately minimal — four lines, no standard set
at all. That is the naive-consumer case, which is exactly why it makes a good detector and why real
projects mask it.

---

# Part 1 — What to check in the downstream consumers

Run these against the JNI library and the Python wheel repos. The goal is not "is it broken today"
(it isn't) but **"where is C++17 coming from, and how fragile is that source?"**

### 1. Find the source of the standard

```bash
grep -rn "CXX_STANDARD\|cxx_std_\|std:c++\|std=c++" \
  --include=CMakeLists.txt --include="*.cmake" \
  --include=setup.py --include=pyproject.toml --include="*.toml" .
```

Expected: at least one hit. **A zero-hit result on a project that builds on MSVC is the interesting
case** — it means something implicit is supplying it (see #4) and you have no control over it.

### 2. If it's `CMAKE_CXX_STANDARD`, check it is actually *required*

```bash
grep -rn "CMAKE_CXX_STANDARD_REQUIRED" --include=CMakeLists.txt --include="*.cmake" .
```

`set(CMAKE_CXX_STANDARD 17)` **without** `set(CMAKE_CXX_STANDARD_REQUIRED ON)` is a *preference*:
CMake will silently decay to an older standard if it thinks the compiler cannot do 17, and you would
then hit the `#error` with no obvious cause. If `CXX_STANDARD` is set, `CXX_STANDARD_REQUIRED ON`
should be set beside it.

### 3. Check the scope — directory variable vs. target property

A directory-scope `set(CMAKE_CXX_STANDARD 17)` only applies to targets created **after** it, in that
directory and below. A target defined in a subdirectory added earlier, or in a sibling tree, will not
get it. Prefer per-target:

```cmake
target_compile_features(<your_target> PRIVATE cxx_std_17)
```

This is the change we made in `test/consumer/CMakeLists.txt`, and it is the form that cannot drift.

### 4. Check whether it is transitive from a third party (Python wheel especially)

If the wheel builds via setuptools + pybind11, `Pybind11Extension` sets the standard for you. That
works, but it means **your C++17 requirement is an undocumented side effect of a pybind11 version**.
A pybind11 upgrade, a switch to nanobind, or a move to scikit-build could remove it silently. If this
is the source, state the requirement explicitly in your own build too — belt and braces.

### 5. Verify on MSVC specifically

Linux will not tell you anything here — GCC's `gnu++17` default masks the whole issue. Any check must
be run on the Windows build. A quick way to see what the compiler is actually being told:

```bash
cmake --build <build-dir> -- -v 2>&1 | grep -o '/std:c++[0-9a-z]*' | sort -u
```

No `/std:` in the output means MSVC is on its C++14 default, and you are relying on nothing.

### 6. Confirm every TU that includes ET headers is covered

The standard must apply to the *target that compiles the ET-including translation unit*, not merely
to some target in the project. If a JNI shim and its ET-facing wrapper live in different targets,
check both.

### 7. Re-verify when adopting `windows-x86_64-static`

The new `/MT` artifact changes nothing about the C++ standard, but it is a natural moment for a
consumer's CMake to be edited. Re-run checks 1–5 after switching, on Windows.

### 8. Do not rely on `find_package` alone

The headline point: `find_package(ExecuTorch REQUIRED)` gives you includes, defines, compile options
and link options — but **not** the language standard. Any consumer must state C++17 itself until
upstream changes. Worth a line in each consumer's README.

---

# Part 2 — Upstream ExecuTorch: description and proposed fix

## Description

ExecuTorch's public headers require C++17 and enforce it with a hard `#error`
(`runtime/platform/compiler.h:36`). The build satisfies this for itself at
`CMakeLists.txt:111-114`:

```cmake
if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
announce_configured_options(CMAKE_CXX_STANDARD)
```

`CMAKE_CXX_STANDARD` is a build-time variable. It governs how ExecuTorch's own targets are compiled
and is **not** part of any target's interface, so it is absent from the generated
`ExecuTorchTargets.cmake`. A downstream project that does

```cmake
find_package(ExecuTorch REQUIRED)
target_link_libraries(my_lib PRIVATE executorch)
```

receives include directories, compile definitions, compile options, and link options — but nothing
about the language standard. On MSVC (default C++14) that is an immediate hard compile error; on GCC
(default `gnu++17`) it silently works, which is why the gap has gone unnoticed.

### Reproduction

```cmake
cmake_minimum_required(VERSION 3.24)
project(p LANGUAGES CXX)
find_package(executorch CONFIG REQUIRED)
add_library(probe SHARED probe.cpp)     # probe.cpp: #include <executorch/runtime/platform/runtime.h>
target_link_libraries(probe PRIVATE executorch)
```

Configure with MSVC + Ninja against an installed ET prefix:

```
compiler.h(36): fatal error C1189: #error: "You need C++17 to compile ExecuTorch"
```

The generated `cl.exe` command line carries no `/std:` flag. Adding
`target_compile_features(probe PRIVATE cxx_std_17)` on the consumer side fixes it, confirming the
diagnosis.

- **ExecuTorch version:** v1.3.1
- **Platform:** Windows 11, MSVC 19.51 (VS 18), Ninja, CMake 4.3
- **Not reproducible on Linux/GCC** — `gnu++17` default masks it

## Proposed fix

Express the requirement as a **usage requirement** on the exported targets, so `find_package`
consumers inherit it:

```cmake
target_compile_features(executorch PUBLIC cxx_std_17)
```

`PUBLIC` both compiles ET with it and propagates it; `INTERFACE` alone would also suffice given
`CMAKE_CXX_STANDARD` already covers ET's own build, but `PUBLIC` is more robust to that block being
changed later.

### One subtlety that makes the placement non-obvious

It is **not** sufficient to put this only on `executorch_core` and rely on propagation. The exported
`executorch` target links its core as:

```cmake
INTERFACE_LINK_LIBRARIES "$<LINK_ONLY:executorch_core>"
```

`$<LINK_ONLY:...>` deliberately suppresses propagation of that dependency's usage requirements — so
compile features on `executorch_core` would **not** reach a consumer of `executorch`. The feature has
to be declared on each publicly consumed target: at minimum `executorch` and `executorch_core`, and
ideally the `extension_*` targets, since consumers link those directly.

### Why not just document it

A `#error` at consumer-compile-time is a poor substitute for a declared requirement: it is
platform-dependent (invisible on GCC), surfaces deep in a build log, and names a cause
("You need C++17") without saying where to set it. CMake has a first-class way to express exactly
this, and ET already uses the analogous mechanism for its platform-specific link options.

### Scope check before filing

Confirm against the upcoming release, since target structure changed recently (v1.3.1 added the
`executorch::backends` / `executorch::extensions` / `executorch::kernels` alias targets at
`CMakeLists.txt:1242-1252`). Verify:

1. Whether the new release exports `INTERFACE_COMPILE_FEATURES` on any target (i.e. already fixed).
2. Which targets a downstream consumer is now expected to link — the alias targets may be the
   intended public surface, in which case they are where the feature belongs.
3. Whether the `$<LINK_ONLY:...>` pattern still applies to those aliases.

---

## Fingerprint to watch for after the upcoming release

If this resurfaces, it will look like one of these — all Windows/MSVC-only:

- `fatal error C1189: #error: "You need C++17 to compile ExecuTorch"`
- A consumer that builds on Linux CI and fails only on the Windows job.
- A build that breaks after an unrelated cleanup removed a `set(CMAKE_CXX_STANDARD 17)` line.
- A Python wheel that breaks after a pybind11 / build-backend upgrade (see Part 1 §4).

Grep a failing build log for `C1189` or `_MSVC_LANG` to confirm quickly.

## Our workaround (already applied)

`test/consumer/CMakeLists.txt` in this repo:

```cmake
target_compile_features(pic_probe PRIVATE cxx_std_17)
```

This is the correct consumer-side action regardless of what upstream does, and should stay even if
ET later propagates the requirement.
