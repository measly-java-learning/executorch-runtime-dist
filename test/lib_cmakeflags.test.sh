#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/configure-base.sh"
. "$here/../scripts/lib/variants.sh"
. "$here/../scripts/lib/openvino.sh"   # ov_enabled_for_platform
. "$here/../scripts/lib/cmakeflags.sh"

# OpenVINO is linux-x86_64 ONLY: the backend uses dlopen/CMAKE_DL_LIBS and -frtti/-fexceptions
# (GCC spelling), and the Intel CPU plugin is x86-64.
assert_contains "$(common_cmake_flags linux-x86_64)" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
  "openvino enabled on linux-x86_64"
case "$(common_cmake_flags linux-aarch64)" in
  *OPENVINO*) printf 'FAIL: openvino must not be enabled on linux-aarch64\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: openvino absent on linux-aarch64\n' ;;
esac
case "$(common_cmake_flags windows-x86_64)" in
  *OPENVINO*) printf 'FAIL: openvino must not be enabled on windows\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: openvino absent on windows-x86_64\n' ;;
esac

# Variant-independent: present for all three Linux variants.
for v in bare logging devtools; do
  assert_contains "$(effective_cmake_flags linux-x86_64 "$v")" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
    "effective flags carry openvino for variant $v"
done
# Windows composition is untouched.
case "$(effective_cmake_flags windows-x86_64-static logging)" in
  *OPENVINO*) printf 'FAIL: windows effective flags must not carry openvino\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: windows effective flags clean\n' ;;
esac
# Pre-existing invariants must survive the signature change.
assert_contains "$(common_cmake_flags linux-x86_64)" "-DEXECUTORCH_BUILD_XNNPACK=ON" "xnnpack still present"
assert_contains "$(common_cmake_flags linux-x86_64)" "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" "PIC still present"
assert_eq "$(printf '%s\n' $(effective_cmake_flags windows-x86_64 logging) | grep -c -- '-DCMAKE_BUILD_TYPE=Release')" \
  "1" "dedup still collapses repeats"
exit "$ASSERT_FAILS"
