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
libs="$(ov_lib_members linux-x86_64)"
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

lics="$(ov_license_members linux-x86_64)"
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
ov_enabled_for_platform windows-x86_64 && printf 'ok: enabled on windows-x86_64\n' || { printf 'FAIL: windows-x86_64\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
ov_enabled_for_platform windows-x86_64-static && printf 'ok: enabled on windows-x86_64-static\n' || { printf 'FAIL: windows-x86_64-static\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# MSVC does not use the lib*.a convention. package.sh asserts the delegate archive EXISTS before
# recording openvino_version, so a single hardcoded spelling would fail every Windows release the
# moment the predicate above turned Windows on.
assert_eq "$(ov_backend_archive_name linux-x86_64)"          "libopenvino_backend.a" "POSIX archive name"
assert_eq "$(ov_backend_archive_name windows-x86_64)"        "openvino_backend.lib"  "MSVC archive name"
assert_eq "$(ov_backend_archive_name windows-x86_64-static)" "openvino_backend.lib"  "MSVC archive name (static CRT)"
ov_enabled_for_platform "" && { printf 'FAIL: empty must be off\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: off on empty platform\n'

# The name wrappers must PROPAGATE ov_asset_stem's validation, not swallow it in a command
# substitution — otherwise an empty platform yields the plausible-looking name ".tar.gz", which
# gen-pin.sh would emit as a real pin URL.
ov_tarball_name "" >/dev/null 2>&1; assert_eq "$?" "2" "ov_tarball_name propagates empty-platform failure"
ov_sha_name     "" >/dev/null 2>&1; assert_eq "$?" "2" "ov_sha_name propagates empty-platform failure"
ov_tarball_name    >/dev/null 2>&1; assert_eq "$?" "2" "ov_tarball_name requires a platform"

# --- platform-taking bundle surface -------------------------------------------------------
# The Windows wheel ships the same CPU runtime set MINUS hwloc, which is folded into
# tbbbind_2_5.dll. A member list that is right for one platform and silently reused for the other
# is how a bundle ends up missing the IR frontend -- the failure openvino_smoke.sh stage 2 exists
# to catch, and which enumerates CPU perfectly right up until it cannot import a model.
assert_eq "$(ov_lib_members linux-x86_64 | wc -l)"   "7" "linux bundle has 7 libs"
assert_eq "$(ov_lib_members windows-x86_64 | wc -l)" "6" "windows bundle has 6 libs (no hwloc)"
assert_contains "$(ov_lib_members windows-x86_64)" "openvino_ir_frontend.dll" \
  "windows keeps the IR frontend"
assert_contains "$(ov_lib_members windows-x86_64)" "tbbbind_2_5.dll" \
  "windows keeps tbbbind (verified loadable from a flat bundle)"
case "$(ov_lib_members windows-x86_64)" in
  *hwloc*) printf 'FAIL: windows must not list hwloc\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: no hwloc on windows\n' ;;
esac
case "$(ov_lib_members windows-x86_64)" in
  *.so*) printf 'FAIL: windows members must be DLLs\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: windows members are DLLs\n' ;;
esac

assert_eq "$(ov_license_members linux-x86_64 | wc -l)"   "5" "linux ships 5 licence files"
assert_eq "$(ov_license_members windows-x86_64 | wc -l)" "4" "windows ships 4 (no hwloc-COPYING)"

# Both CRT platforms share one bundle: the bundle is the OpenVINO runtime, not our artifact, and
# the wheel's DLLs are /MD regardless of how a consumer links. Verified safe -- every OpenVINO
# allocation is freed through an OpenVINO-side function, so no CRT object crosses the boundary.
assert_eq "$(ov_lib_members windows-x86_64-static)" "$(ov_lib_members windows-x86_64)" \
  "both windows CRTs share one bundle"

assert_eq "$(ov_wheel_platform_tag linux-x86_64)"   "manylinux2014_x86_64" "linux wheel tag"
assert_eq "$(ov_wheel_platform_tag windows-x86_64)" "win_amd64"            "windows wheel tag"
_ovsha="$(ov_wheel_sha256 windows-x86_64)"
assert_eq "${#_ovsha}" "64" "windows wheel sha is 64 hex"
ov_uses_hwloc linux-x86_64   && printf 'ok: hwloc applies on linux\n'   || { printf 'FAIL: linux uses hwloc\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
ov_uses_hwloc windows-x86_64 && { printf 'FAIL: windows must not use hwloc\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: no hwloc on windows\n'

# The SONAME symlink is a Linux-only convenience (Windows DLLs are unversioned). It is a SEPARATE
# fact from ov_uses_hwloc even though both are linux-only today: a future platform must not
# inherit either silently.
ov_needs_soname_symlink linux-x86_64   && printf 'ok: soname symlink on linux\n'   || { printf 'FAIL: linux needs soname symlink\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
ov_needs_soname_symlink windows-x86_64 && { printf 'FAIL: windows must not need soname symlink\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: no soname symlink on windows\n'
ov_needs_soname_symlink "" && { printf 'FAIL: empty platform must not need symlink\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: no symlink on empty platform\n'

# An unknown platform must FAIL rather than default to one platform's member list -- the same
# reasoning crt_for_platform documents in configure-base.sh.
ov_lib_members bogus-platform     >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform rejected (libs)"
ov_license_members bogus-platform >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform rejected (licences)"
ov_wheel_sha256 ""                >/dev/null 2>&1; assert_eq "$?" "2" "empty platform rejected (sha)"

# --- which bundle serves which platform ---------------------------------------------------
# Both Windows CRT platforms are served by ONE bundle: the wheel's DLLs are /MD regardless of how
# a consumer links, and no CRT object crosses the boundary (every OpenVINO allocation is released
# through an OpenVINO-side free function). Publishing two assets that differ only in a BUILDINFO
# line would be pure duplication.
assert_eq "$(ov_bundle_platform linux-x86_64)"          "linux-x86_64"   "linux serves itself"
assert_eq "$(ov_bundle_platform windows-x86_64)"        "windows-x86_64" "windows /MD serves itself"
assert_eq "$(ov_bundle_platform windows-x86_64-static)" "windows-x86_64" "windows /MT reuses the /MD bundle"

# A platform with no bundle must FAIL rather than silently resolve to some other platform's --
# that would publish a pin row claiming a bundle exists for linux-aarch64.
ov_bundle_platform linux-aarch64 >/dev/null 2>&1; assert_eq "$?" "2" "aarch64 has no bundle"
ov_bundle_platform ""            >/dev/null 2>&1; assert_eq "$?" "2" "empty platform rejected"

# The set a release actually builds. Distinct, so the release matrix cannot be handed the same
# bundle twice.
assert_eq "$(ov_bundle_platforms | sort | tr '\n' ' ')" "linux-x86_64 windows-x86_64 " \
  "exactly two bundles are built per release"
assert_eq "$(ov_bundle_platforms | sort -u | wc -l)" "$(ov_bundle_platforms | wc -l)" \
  "ov_bundle_platforms has no duplicates"

# The aliases are the platforms that do NOT get their own asset. Bundles + aliases must together
# cover every OpenVINO-enabled platform, or a release enables a delegate for a platform whose
# runtime is neither published nor aliased -- exactly the gap this plan closes.
assert_eq "$(ov_alias_platforms)" "windows-x86_64-static" "the static CRT platform is an alias"
for _p in linux-x86_64 windows-x86_64 windows-x86_64-static; do
  case "$(ov_bundle_platforms; ov_alias_platforms)" in
    *"$_p"*) printf 'ok: %s is published or aliased\n' "$_p" ;;
    *) printf 'FAIL: %s is enabled but neither built nor aliased\n' "$_p" >&2
       ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  esac
done
# An alias must never also be built, or the release would publish the duplicate this avoids.
while read -r _a; do
  case "$(ov_bundle_platforms)" in
    *"$_a"*) printf 'FAIL: %s is both aliased and built\n' "$_a" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
    *) printf 'ok: %s is aliased, not built\n' "$_a" ;;
  esac
done <<EOF
$(ov_alias_platforms)
EOF

# Every OpenVINO-enabled platform must map to a buildable bundle, or a release would enable the
# delegate for a platform whose runtime is never published -- the exact gap this plan closes.
for _p in linux-x86_64 windows-x86_64 windows-x86_64-static; do
  _b="$(ov_bundle_platform "$_p")" || { printf 'FAIL: no bundle for %s\n' "$_p" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); continue; }
  case "$(ov_bundle_platforms)" in
    *"$_b"*) printf 'ok: %s -> %s is built\n' "$_p" "$_b" ;;
    *) printf 'FAIL: %s maps to %s, which ov_bundle_platforms does not build\n' "$_p" "$_b" >&2
       ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  esac
done

exit "$ASSERT_FAILS"
