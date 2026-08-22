#!/usr/bin/env bash
# Hermetic: builds a SYNTHETIC wheel + license file, runs the vendor script against them, and
# asserts the bundle's shape. No network, no container, no real OpenVINO. The real wheel is
# exercised by test/openvino_smoke.sh, which needs a container.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"
. "$here/../scripts/lib/python.sh"

# The synthetic wheel is BUILT with the same interpreter vendor-openvino.sh EXTRACTS with, via the
# same et_python_bin resolution -- so this test cannot pass on a machine where the script it
# exercises would fail, which is exactly what the old `command -v zip || SKIP` allowed.
#
# Not `zip`: the script stopped needing unzip (Git for Windows ships none), and requiring the zip
# CLI here made the suite's dependency set larger than unit.yml claims. A missing interpreter is a
# HARD failure, never a skip -- a skip that exits 0 is indistinguishable from a pass, which is how
# a broken vendor script reaches a release with a green suite.
PY="$(et_python_bin)" || { echo "FAIL: no python interpreter; vendor-openvino.sh cannot run" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- synthesize a wheel with exactly the members the script expects ---
wheelsrc="$tmp/wheelsrc"
mkdir -p "$wheelsrc/openvino/libs" "$wheelsrc/openvino-${OV_VERSION}.dist-info/licenses/licensing"
while read -r m; do printf 'ELF-STUB %s\n' "$m" > "$wheelsrc/openvino/libs/$m"; done <<EOF
$(ov_lib_members linux-x86_64)
EOF
printf 'Apache License 2.0 stub\n' > "$wheelsrc/openvino-${OV_VERSION}.dist-info/licenses/LICENSE"
for f in runtime-third-party-programs.txt onetbb_third-party-programs.txt onednn_third-party-programs.txt; do
  printf 'notice stub %s\n' "$f" > "$wheelsrc/openvino-${OV_VERSION}.dist-info/licenses/licensing/$f"
done
wheel="$tmp/openvino-${OV_VERSION}-${OV_WHEEL_PYTAG}-${OV_WHEEL_PYTAG}-manylinux2014_x86_64.whl"
( cd "$wheelsrc" && "$PY" -m zipfile -c "$wheel" openvino "openvino-${OV_VERSION}.dist-info" )
printf 'hwloc BSD-3-Clause stub\n' > "$tmp/hwloc-COPYING"

out="$tmp/out"
bundle="$(bash "$here/../scripts/vendor-openvino.sh" --out "$out" \
  --wheel "$wheel" --hwloc-license "$tmp/hwloc-COPYING")" \
  || { echo "FAIL: vendor-openvino.sh exited non-zero"; exit 1; }

assert_eq "$(basename "$bundle")" "$(ov_asset_stem linux-x86_64)" "bundle dir is the asset stem"

while read -r m; do
  [ -f "$bundle/lib/$m" ] && printf 'ok: lib member %s\n' "$m" \
    || { printf 'FAIL: missing lib member %s\n' "$m" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done <<EOF
$(ov_lib_members linux-x86_64)
EOF

while read -r m; do
  [ -f "$bundle/licenses/$m" ] && printf 'ok: license %s\n' "$m" \
    || { printf 'FAIL: missing license %s\n' "$m" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done <<EOF
$(ov_license_members linux-x86_64)
EOF

# The unversioned symlink is what makes the backend's DEFAULT dlopen name resolvable; the wheel
# does not ship it, so the script must create it.
[ -L "$bundle/lib/libopenvino_c.so" ] && printf 'ok: unversioned symlink created\n' \
  || { printf 'FAIL: libopenvino_c.so symlink missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_eq "$(readlink "$bundle/lib/libopenvino_c.so")" "libopenvino_c.so.${OV_ABI}" "symlink is relative to sibling"

# Nothing from the excluded set may leak in (GPU/NPU plugins, frontends).
for bad in libopenvino_intel_gpu_plugin.so libopenvino_intel_npu_plugin.so libopenvino_onnx_frontend.so; do
  [ -e "$bundle/lib/$bad" ] && { printf 'FAIL: excluded member leaked: %s\n' "$bad" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } \
    || printf 'ok: excluded %s\n' "$bad"
done

binfo="$(cat "$bundle/BUILDINFO")"
assert_contains "$binfo" "ov_version=${OV_VERSION}"      "BUILDINFO records ov_version"
assert_contains "$binfo" "ov_abi=${OV_ABI}"              "BUILDINFO records ov_abi"
assert_contains "$binfo" "hwloc_version=${OV_HWLOC_VERSION}" "BUILDINFO records hwloc_version"
assert_contains "$binfo" "platform=linux-x86_64"         "BUILDINFO records platform"

# --- windows-x86_64: 6 DLLs, 4 licences, no symlink, no hwloc, no --hwloc-license -----------
winwheelsrc="$tmp/winwheelsrc"
mkdir -p "$winwheelsrc/openvino/libs" "$winwheelsrc/openvino-${OV_VERSION}.dist-info/licenses/licensing"
while read -r m; do printf 'PE-STUB %s\n' "$m" > "$winwheelsrc/openvino/libs/$m"; done <<EOF
$(ov_lib_members windows-x86_64)
EOF
printf 'Apache License 2.0 stub\n' > "$winwheelsrc/openvino-${OV_VERSION}.dist-info/licenses/LICENSE"
for f in runtime-third-party-programs.txt onetbb_third-party-programs.txt onednn_third-party-programs.txt; do
  printf 'notice stub %s\n' "$f" > "$winwheelsrc/openvino-${OV_VERSION}.dist-info/licenses/licensing/$f"
done
winwheel="$tmp/openvino-${OV_VERSION}-${OV_WHEEL_PYTAG}-${OV_WHEEL_PYTAG}-win_amd64.whl"
( cd "$winwheelsrc" && "$PY" -m zipfile -c "$winwheel" openvino "openvino-${OV_VERSION}.dist-info" )

winout="$tmp/winout"
winbundle="$(bash "$here/../scripts/vendor-openvino.sh" --platform windows-x86_64 --out "$winout" \
  --wheel "$winwheel")" \
  || { echo "FAIL: vendor-openvino.sh (windows) exited non-zero"; exit 1; }

assert_eq "$(basename "$winbundle")" "$(ov_asset_stem windows-x86_64)" "windows bundle dir is the asset stem"

while read -r m; do
  [ -f "$winbundle/lib/$m" ] && printf 'ok: windows lib member %s\n' "$m" \
    || { printf 'FAIL: missing windows lib member %s\n' "$m" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done <<EOF
$(ov_lib_members windows-x86_64)
EOF

while read -r m; do
  [ -f "$winbundle/licenses/$m" ] && printf 'ok: windows license %s\n' "$m" \
    || { printf 'FAIL: missing windows license %s\n' "$m" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done <<EOF
$(ov_license_members windows-x86_64)
EOF

# Windows DLLs are unversioned and hwloc is folded into tbbbind_2_5.dll, so neither the SONAME
# symlink nor hwloc-COPYING may appear -- and the script must reach this state WITHOUT a
# --hwloc-license argument (the fetch is skipped entirely on this platform).
if [ -e "$winbundle/lib/libopenvino_c.so" ] || [ -L "$winbundle/lib/libopenvino_c.so" ]; then
  printf 'FAIL: windows must not create the soname symlink\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: no soname symlink on windows\n'
fi
if [ -e "$winbundle/licenses/hwloc-COPYING" ] || [ -L "$winbundle/licenses/hwloc-COPYING" ]; then
  printf 'FAIL: windows must not ship hwloc-COPYING\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: no hwloc-COPYING on windows\n'
fi

winbinfo="$(cat "$winbundle/BUILDINFO")"
assert_contains "$winbinfo" "ov_version=${OV_VERSION}"    "windows BUILDINFO records ov_version"
assert_contains "$winbinfo" "platform=windows-x86_64"     "windows BUILDINFO records platform"
assert_contains "$winbinfo" "source_wheel=$(basename "$winwheel")" "windows BUILDINFO records source_wheel"
case "$winbinfo" in
  *ov_abi*) printf 'FAIL: windows BUILDINFO must not carry ov_abi\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: no ov_abi on windows\n' ;;
esac
case "$winbinfo" in
  *hwloc_version*) printf 'FAIL: windows BUILDINFO must not carry hwloc_version\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: no hwloc_version on windows\n' ;;
esac

# HARD GATE: a missing license must abort, never ship unattributed binaries.
out2="$tmp/out2"
bash "$here/../scripts/vendor-openvino.sh" --out "$out2" --wheel "$wheel" \
  --hwloc-license "$tmp/definitely-missing" >/dev/null 2>&1
assert_eq "$?" "1" "missing hwloc license aborts the bundle"

exit "$ASSERT_FAILS"
