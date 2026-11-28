#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/relocate.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
d="$tmp/lib/cmake/ExecuTorch"; mkdir -p "$d"

# A clean config, shaped like the real ones: prefix-relative paths and bare link names only.
cat > "$d/ExecuTorchTargets.cmake" <<'EOF'
set_target_properties(executorch PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/include"
  INTERFACE_LINK_LIBRARIES "executorch_core;m"
)
EOF
assert_eq "$(toolchain_path_leaks "$tmp/lib/cmake")" "" "clean configs report nothing"

# Each leak shape is reported with its file.
for leak in \
  "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/usr/lib/libc++.tbd" \
  "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Accelerate.framework" \
  "/Applications/Xcode-16.4.app/Contents/Developer/usr/bin/clang" \
  "/opt/sdks/MacOSX14.0.sdk"; do
  printf 'set(_x "%s")\n' "$leak" > "$d/leak.cmake"
  out="$(toolchain_path_leaks "$tmp/lib/cmake")"
  assert_contains "$out" "leak.cmake" "leak reported with its file: $leak"
done
rm -f "$d/leak.cmake"

# A semicolon-separated link list is split at the right place: only the SDK entry is reported.
printf 'INTERFACE_LINK_LIBRARIES "m;/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib/libz.tbd;pthreadpool"\n' > "$d/list.cmake"
out="$(toolchain_path_leaks "$tmp/lib/cmake")"
assert_contains "$out" "libz.tbd" "SDK entry inside a link list reported"
case "$out" in *pthreadpool*) assert_eq "$out" "<no pthreadpool>" "match stops at the list separator" ;; *) printf 'ok: match stops at the list separator\n' ;; esac
rm -f "$d/list.cmake"

toolchain_path_leaks "$tmp/nope" >/dev/null 2>&1; assert_eq "$?" "2" "missing dir is an error, not a clean pass"
exit "$ASSERT_FAILS"
