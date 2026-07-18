#!/usr/bin/env bash
# Platform -> ExecuTorch cmake CONFIGURE BASE (SSOT). Shared by build-runtime.sh (the build) and
# package.sh (recorded provenance) so the two can never disagree on how the artifact was configured.
# Linux uses the ET `linux` preset. Windows uses a flat flag list because the ET `windows` preset
# pins toolset ClangCL + the VS generator, incompatible with our Ninja/MSVC single-config build
# (spike finding 1). The Windows list is the windows-preset feature set MINUS
# KERNELS_OPTIMIZED/QUANTIZED — those pull torch c10 headers that break MSVC, and Linux ships neither
# (spike finding 3). `common_cmake_flags` + `variant_flags` still layer on top of this base.
#
# The Windows base pins CMAKE_C/CXX_COMPILER=cl because cmake's own MSVC discovery defaults to the
# Hostx86/x86 (32-bit) toolchain when `cmake` is the VS-bundled copy — a silent 32-bit build that no
# existing gate catches (issue #10).
#
# Windows ships TWO platforms differing only in the C runtime, because MSVC bakes the CRT into every
# object and all statically-linked objects in a downstream DLL must agree (mismatch => LNK4098/2005):
#   windows-x86_64         /MD  dynamic CRT — required for CPython extensions (CPython is /MD)
#   windows-x86_64-static  /MT  static CRT  — self-contained JNI DLLs, no VC++ redist needed
# Do NOT set CMAKE_POLICY_DEFAULT_CMP0091: it is NEW by default at our cmake floor and only produces
# an "unused variable" warning.
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

et_configure_base() { # <platform>
  case "$1" in
    linux-*) printf -- '--preset linux' ;;
    windows-*)
      # crt_for_platform is the gatekeeper: an unrecognized windows-* platform returns 2 here rather
      # than building with an arbitrary CRT.
      _crt="$(crt_for_platform "$1")" || return 2
      printf -- '%s -DCMAKE_MSVC_RUNTIME_LIBRARY=%s' "$_ET_WINDOWS_COMMON" "$_crt" ;;
    *) echo "et_configure_base: unknown platform '$1'" >&2; return 2 ;;
  esac
}
