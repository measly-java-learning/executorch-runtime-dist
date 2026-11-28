#!/usr/bin/env bash
# Platform -> ExecuTorch cmake CONFIGURE BASE (SSOT). Shared by build-runtime.sh (the build) and
# package.sh (recorded provenance) so the two can never disagree on how the artifact was configured.
# Linux uses the ET `linux` preset. Windows uses a flat flag list because the ET `windows` preset
# pins toolset ClangCL + the VS generator, incompatible with our Ninja/MSVC single-config build
# (spike finding 1). The Windows list is the windows-preset feature set MINUS
# KERNELS_OPTIMIZED/QUANTIZED, which do not compile under MSVC at our pin (spike finding 3). OPTIMIZED
# pulls in real torch c10 headers that use C++20-only syntax: MSVC rejects it at C++17, while GCC
# accepts it as an extension with a warning. Upstream closed pytorch/pytorch#193590 by declaring
# C++20 required (pytorch/pytorch#197417 only adds a clearer #error, in headers our build never
# includes). No C++17 fallback is coming: re-enabling OPTIMIZED on Windows means building those
# targets at /std:c++20 (no known public PyTorch/ET timeline for the C++20 move). ET's own llm
# preset already disables QUANTIZED under MSVC. Linux ships BOTH: the `linux` preset includes ET's
# llm preset, which turns them on. So this is a real Linux/Windows feature gap, not parity.
# `common_cmake_flags` + `variant_flags` still layer on top of this base.
#
# The Windows base pins CMAKE_C/CXX_COMPILER=cl because cmake's own MSVC discovery defaults to the
# Hostx86/x86 (32-bit) toolchain when `cmake` is the VS-bundled copy — a silent 32-bit build that no
# existing gate catches (issue #10).
#
# Windows ships TWO platforms differing only in the C runtime, because MSVC bakes the CRT into every
# object and all statically-linked objects in a downstream DLL must agree. A mismatch is NOT
# reliably caught at link time (measured: a /MD consumer linked a /MT artifact clean, no LNK2005,
# not even an LNK4098 warning) — the real hazard is at runtime: two CRTs, two heaps, corruption when
# an allocation crosses the boundary. See scripts/check-windows-crt.sh, the gate that actually
# catches a mismatch.
#   windows-x86_64         /MD  dynamic CRT — required for CPython extensions (CPython is /MD)
#   windows-x86_64-static  /MT  static CRT  — self-contained JNI DLLs, no VC++ redist needed
# Do NOT set CMAKE_POLICY_DEFAULT_CMP0091: it is NEW by default at our cmake floor and only produces
# an "unused variable" warning.
#
# macOS (macos-arm64) is a flat list too, but for a different reason: both candidate presets turn on
# features Linux does not ship. `--preset macos` brings the ios-cmake toolchain, CoreML, MLX, the
# Objective-C Apple extensions and torchao, and forces EXECUTORCH_ENABLE_EVENT_TRACER ON (so bare and
# logging would quietly ship the tracer). `--preset llm`, which `--preset linux` includes, turns on
# CoreML and torchao when CMAKE_SYSTEM_NAME is Darwin. A flat list fails closed: a feature upstream
# later adds for Darwin stays off until someone decides to ship it. The list is _ET_LINUX_PARITY_FEATURES
# (what the Linux preset enables) plus the Apple target settings, plus explicit OFFs for the Darwin-only
# features ET would otherwise pick up. Spike-verified on Apple clang 21: the OPTIMIZED/QUANTIZED/LLM
# kernels compile at C++17 unchanged, so unlike MSVC there is no Linux/macOS feature gap. See
# docs/superpowers/specs/2026-11-27-macos-arm64-artifacts-design.md §2 and
# spike/2026-11-27-macos-arm64-spike.md.
# Source me.

# Platform -> MSVC runtime library. THE single mapping: et_configure_base builds its flag from it,
# test/relocatability-windows.sh picks the consumer CRT from it, and release.yml passes it to the CRT
# scan. Never re-derive this mapping at a call site — an unknown platform must FAIL here rather than
# silently default to one CRT and have the gate validate the wrong thing.
crt_for_platform() { # <platform>
  case "$1" in
    windows-x86_64-static) printf 'MultiThreaded' ;;
    windows-x86_64)        printf 'MultiThreadedDLL' ;;
    *) echo "crt_for_platform: no CRT defined for platform '$1'" >&2; return 2 ;;
  esac
}

# Variant-independent Windows flags shared by BOTH windows platforms, so they can only ever differ
# in the CRT appended by et_configure_base.
_ET_WINDOWS_COMMON='-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON'

# The EXECUTORCH_BUILD_* features the Linux build turns ON at the current ET pin: tools/cmake/preset/
# linux.cmake plus the Linux branch of llm.cmake, which it includes. Linux itself still configures
# with `--preset linux`; this list exists so macOS can match it. It is NOT read from ET's preset files
# because the unit suite is hermetic (no ET checkout). REFRESH IT WHEN THE ET PIN MOVES: diff the two
# preset files at the new tag and add or remove names here; macOS follows automatically.
_ET_LINUX_PARITY_FEATURES='EXECUTOR_RUNNER EXTENSION_ASR_RUNNER EXTENSION_DATA_LOADER EXTENSION_EVALUE_UTIL EXTENSION_FLAT_TENSOR EXTENSION_LLM EXTENSION_LLM_RUNNER EXTENSION_MODULE EXTENSION_NAMED_DATA_MAP EXTENSION_RUNNER_UTIL EXTENSION_TENSOR KERNELS_LLM KERNELS_OPTIMIZED KERNELS_QUANTIZED XNNPACK'

# Darwin-only features ET's presets or top-level defaults could turn on. Pinned OFF so the decision
# is explicit and is recorded in --print-flags and BUILDINFO.
_ET_MACOS_DISABLED_FEATURES='COREML MLX KERNELS_TORCHAO'

# Platform -> minimum macOS version / architecture. THE single mapping: the configure base, the
# extras phase (extras_cmake_flags) and the minos gate all read these, so the archives and the gate
# cannot disagree about the target. 14.0 is what upstream's own `macos` preset targets.
macos_deployment_target() { # <platform>
  case "$1" in
    macos-arm64) printf '14.0' ;;
    *) echo "macos_deployment_target: no deployment target for platform '$1'" >&2; return 2 ;;
  esac
}
macos_arch() { # <platform>
  case "$1" in
    macos-arm64) printf 'arm64' ;;
    *) echo "macos_arch: no architecture for platform '$1'" >&2; return 2 ;;
  esac
}

# The Apple target flags. Shared by the ET configure base and the extras phase: extras/ is its own
# CMake project, so it inherits nothing from ET's configure. Without these, AppleClang defaults
# minos to the HOST SDK (the spike's libetnp_ops_lstm.a and libhwy.a came out minos 26.0).
_macos_target_flags() { # <platform>
  local _min _arch
  _min="$(macos_deployment_target "$1")" || return 2
  _arch="$(macos_arch "$1")" || return 2
  printf -- '-DCMAKE_OSX_DEPLOYMENT_TARGET=%s -DCMAKE_OSX_ARCHITECTURES=%s' "$_min" "$_arch"
}

# Extra cmake flags for the extras phase (build_extras), per platform. Empty where the toolchain
# default already matches the ET build (Linux, Windows); the Apple target flags on macOS.
extras_cmake_flags() { # <platform>
  case "$1" in
    linux-*|windows-*) printf '' ;;
    macos-*) _macos_target_flags "$1" || return 2 ;;
    *) echo "extras_cmake_flags: unknown platform '$1'" >&2; return 2 ;;
  esac
}

_et_macos_base() { # <platform>
  local _target _f _out
  _target="$(_macos_target_flags "$1")" || return 2
  _out="-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON $_target"
  for _f in $_ET_LINUX_PARITY_FEATURES; do _out="$_out -DEXECUTORCH_BUILD_$_f=ON"; done
  for _f in $_ET_MACOS_DISABLED_FEATURES; do _out="$_out -DEXECUTORCH_BUILD_$_f=OFF"; done
  printf -- '%s' "$_out"
}

et_configure_base() { # <platform>
  local _crt
  case "$1" in
    linux-*) printf -- '--preset linux' ;;
    # _et_macos_base is the gatekeeper: an unrecognized macos-* platform returns 2 there.
    macos-*) _et_macos_base "$1" || return 2 ;;
    windows-*)
      # crt_for_platform is the gatekeeper: an unrecognized windows-* platform returns 2 here rather
      # than building with an arbitrary CRT.
      _crt="$(crt_for_platform "$1")" || return 2
      printf -- '%s -DCMAKE_MSVC_RUNTIME_LIBRARY=%s' "$_ET_WINDOWS_COMMON" "$_crt" ;;
    *) echo "et_configure_base: unknown platform '$1'" >&2; return 2 ;;
  esac
}

# The OS a --platform targets (linux | macos | windows). Every platform string is <os>-<arch>[-flavor].
platform_os() { # <platform>
  case "$1" in
    linux-*)   printf 'linux' ;;
    macos-*)   printf 'macos' ;;
    windows-*) printf 'windows' ;;
    *) echo "platform_os: unknown platform '$1'" >&2; return 2 ;;
  esac
}

# Refuse to build <platform> on a host of another OS. No cross-compilation is supported: Linux builds
# need the manylinux container, Windows needs MSVC, macOS needs Apple's toolchain. Without this,
# --platform defaulting to linux-x86_64 would send a Mac build into `--preset linux`, whose
# CMAKE_SYSTEM_NAME=Linux condition fails far from the cause. <host> is passed in (callers use
# host_os from lib/portable.sh) so the check is testable on any machine. --print-flags deliberately
# does not call this: inspecting another platform's flags from any host is the point of it.
platform_matches_host() { # <platform> <host-os>
  local _pos
  _pos="$(platform_os "$1")" || return 2
  if [ "$_pos" != "$2" ]; then
    echo "platform '$1' targets $_pos, but this host is $2. Pass --platform for this host" >&2
    echo "  (e.g. --platform macos-arm64 on a Mac; the default is linux-x86_64)." >&2
    return 2
  fi
}
