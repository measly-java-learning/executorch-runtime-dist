#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/configure-base.sh"
. "$here/../scripts/lib/variants.sh"
. "$here/../scripts/lib/openvino.sh"   # ov_enabled_for_platform
. "$here/../scripts/lib/cmakeflags.sh"

# OpenVINO is enabled on linux-x86_64 and both Windows platforms (windows-x86_64,
# windows-x86_64-static). Linux resolves the C API via dlopen; Windows uses the LoadLibraryExW
# loader and the MSVC /EHsc /GR compile spelling from the vendored OpenVINO Windows patch.
assert_contains "$(common_cmake_flags linux-x86_64)" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
  "openvino enabled on linux-x86_64"
case "$(common_cmake_flags linux-aarch64)" in
  *OPENVINO*) printf 'FAIL: openvino must not be enabled on linux-aarch64\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: openvino absent on linux-aarch64\n' ;;
esac
assert_contains "$(common_cmake_flags windows-x86_64)" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
  "openvino enabled on windows-x86_64"

# Variant-independent: present for all three Linux variants.
for v in bare logging devtools; do
  assert_contains "$(effective_cmake_flags linux-x86_64 "$v")" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
    "effective flags carry openvino for variant $v"
done
# Windows effective flags carry the OpenVINO flag as well (composition otherwise unchanged).
assert_contains "$(effective_cmake_flags windows-x86_64-static logging)" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
  "windows effective flags carry openvino"
# Pre-existing invariants must survive the signature change.
assert_contains "$(common_cmake_flags linux-x86_64)" "-DEXECUTORCH_BUILD_XNNPACK=ON" "xnnpack still present"
assert_contains "$(common_cmake_flags linux-x86_64)" "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" "PIC still present"
assert_eq "$(printf '%s\n' $(effective_cmake_flags windows-x86_64 logging) | grep -c -- '-DCMAKE_BUILD_TYPE=Release')" \
  "1" "dedup still collapses repeats"
# The workspace-size accessor reports ONE process-wide arena, which is only true under Global
# sharing. Upstream defaults this ON (tools/cmake/preset/default.cmake), but the comment directly
# above that default says "Keeping this OFF by default" — prose and value disagree, so the default
# is one upstream edit away from flipping. Pin it rather than inherit it. Platform-independent:
# unlike OpenVINO this is not an x86-64-only concern.
for p in linux-x86_64 linux-aarch64 windows-x86_64 windows-x86_64-static; do
  assert_contains "$(common_cmake_flags "$p")" "-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON" \
    "shared workspace pinned on $p"
done
assert_contains "$(effective_cmake_flags linux-x86_64 logging)" \
  "-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON" "effective flags carry the workspace pin"
exit "$ASSERT_FAILS"
