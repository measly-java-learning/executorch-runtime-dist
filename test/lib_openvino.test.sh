#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"

assert_eq "$OV_VERSION" "2025.4.1" "pinned OpenVINO version"
assert_eq "$OV_ABI"     "2541"     "pinned OpenVINO soname suffix"
assert_eq "${#OV_WHEEL_SHA256}" "64" "wheel sha256 is 64 hex chars"
assert_eq "$OV_HWLOC_VERSION" "2.8.0" "pinned hwloc version"
assert_contains "$OV_HWLOC_LICENSE_URL" "hwloc-2.8.0/COPYING" "hwloc license URL is version-pinned"

assert_eq "$(ov_asset_stem linux-x86_64)"  "openvino-runtime-2025.4.1-linux-x86_64"            "asset stem"
assert_eq "$(ov_tarball_name linux-x86_64)" "openvino-runtime-2025.4.1-linux-x86_64.tar.gz"     "tarball name"
assert_eq "$(ov_sha_name linux-x86_64)"     "openvino-runtime-2025.4.1-linux-x86_64.tar.gz.sha256" "sha name"

# The lib member list is the contract the bundle test and vendor script share.
libs="$(ov_lib_members)"
assert_eq "$(printf '%s\n' "$libs" | wc -l)" "7" "seven runtime libs"
for m in "libopenvino_c.so.2541" "libopenvino.so.2541" "libopenvino_intel_cpu_plugin.so" \
         "libopenvino_ir_frontend.so.2541" \
         "libtbb.so.12" "libtbbbind_2_5.so.3" "libhwloc.so.15"; do
  assert_contains "$libs" "$m" "lib member: $m"
done
# Regression guard: the IR frontend was once pruned along with the model-format frontends, which
# made every delegated .pte fail at ov_core_import_model while device enumeration still passed.
assert_contains "$libs" "libopenvino_ir_frontend" "IR frontend present (blob deserialization)"
# The unversioned symlink is CREATED by the vendor script, not copied from the wheel,
# so it must NOT appear in the member list. grep -x anchors the whole line, so the
# versioned libopenvino_c.so.2541 does not false-positive here.
if printf '%s\n' "$libs" | grep -qx 'libopenvino_c.so'; then
  printf 'FAIL: unversioned symlink must not be a wheel member\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: unversioned symlink is not a wheel member\n'
fi

lics="$(ov_license_members)"
assert_eq "$(printf '%s\n' "$lics" | wc -l)" "5" "five license files"
for m in "LICENSE" "runtime-third-party-programs.txt" "onetbb_third-party-programs.txt" \
         "onednn_third-party-programs.txt" "hwloc-COPYING"; do
  assert_contains "$lics" "$m" "license member: $m"
done

ov_asset_stem >/dev/null 2>&1; assert_eq "$?" "2" "missing platform returns 2"

# Fixtures are named by BOTH versions: the .pte embeds a precompiled OpenVINO blob, so it is
# coupled to the OpenVINO version as well as the ET version (unlike etnp-lstm-fixtures).
assert_eq "$(ov_fixtures_name 1.3.1)" "etnp-openvino-fixtures-1.3.1-${OV_VERSION}.tar.gz" \
  "fixtures name carries both etver and ovver"
ov_fixtures_name >/dev/null 2>&1; assert_eq "$?" "2" "fixtures name without etver returns 2"

# The one platform -> OpenVINO predicate, shared by cmakeflags.sh and package.sh so they cannot
# disagree about whether a tarball contains the delegate.
ov_enabled_for_platform linux-x86_64  && printf 'ok: enabled on linux-x86_64\n'   || { printf 'FAIL: linux-x86_64\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
ov_enabled_for_platform linux-aarch64 && { printf 'FAIL: aarch64 must be off\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: off on linux-aarch64\n'
ov_enabled_for_platform windows-x86_64 && { printf 'FAIL: windows must be off\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: off on windows-x86_64\n'
ov_enabled_for_platform "" && { printf 'FAIL: empty must be off\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: off on empty platform\n'

# The name wrappers must PROPAGATE ov_asset_stem's validation, not swallow it in a command
# substitution — otherwise an empty platform yields the plausible-looking name ".tar.gz", which
# gen-pin.sh would emit as a real pin URL.
ov_tarball_name "" >/dev/null 2>&1; assert_eq "$?" "2" "ov_tarball_name propagates empty-platform failure"
ov_sha_name     "" >/dev/null 2>&1; assert_eq "$?" "2" "ov_sha_name propagates empty-platform failure"
ov_tarball_name    >/dev/null 2>&1; assert_eq "$?" "2" "ov_tarball_name requires a platform"

exit "$ASSERT_FAILS"
