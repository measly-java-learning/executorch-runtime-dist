#!/usr/bin/env bash
# Hermetic: builds a SYNTHETIC wheel + license file, runs the vendor script against them, and
# asserts the bundle's shape. No network, no container, no real OpenVINO. The real wheel is
# exercised by test/openvino_smoke.sh, which needs a container.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"

command -v zip >/dev/null 2>&1 || { echo "SKIP: zip not available"; exit 0; }

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
( cd "$wheelsrc" && zip -q -r "$wheel" . )
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

# HARD GATE: a missing license must abort, never ship unattributed binaries.
out2="$tmp/out2"
bash "$here/../scripts/vendor-openvino.sh" --out "$out2" --wheel "$wheel" \
  --hwloc-license "$tmp/definitely-missing" >/dev/null 2>&1
assert_eq "$?" "1" "missing hwloc license aborts the bundle"

exit "$ASSERT_FAILS"
