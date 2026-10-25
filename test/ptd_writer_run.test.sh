#!/usr/bin/env bash
# Hermetic coverage for the .ptd writer gate: input validation (a missing fixture must fail loudly,
# naming the file) plus the source contracts a build-requiring test cannot check here.
#
# The gate itself compiles against an installed prefix, so it stays out of test/run.sh's glob --
# this file is the part that can run from a clean checkout.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
gate="$here/ptd_writer_run.sh"
windows_gate="$here/ptd_writer_run-windows.sh"
src="$(cat "$here/ptd_writer/ptd_roundtrip.cpp")"
sweep="$(cat "$here/ptd_writer/ptd_dtype_sweep.cpp")"
cmake_src="$(cat "$here/ptd_writer/CMakeLists.txt")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash "$gate" >/dev/null 2>&1
assert_eq "$?" "1" "gate: no arguments is a usage error"

mkdir -p "$tmp/prefix" "$tmp/fx"
for f in linear.pte linear.ptd linear_x2.ptd in.bin out_base.bin out_x2.bin; do
  : > "$tmp/fx/$f"
done

for missing in linear.pte linear.ptd linear_x2.ptd in.bin out_base.bin out_x2.bin; do
  mv "$tmp/fx/$missing" "$tmp/$missing.stash"
  out="$(bash "$gate" "$tmp/prefix" "$tmp/fx" 2>&1)"
  rc=$?
  mv "$tmp/$missing.stash" "$tmp/fx/$missing"
  assert_eq "$rc" "1" "gate: missing $missing fails"
  assert_contains "$out" "$missing missing" "gate: names the missing member ($missing)"
done

# The consumer must include the four installed header paths by their installed spelling. Renaming
# one in the prefix would leave this file compiling against a source tree, which is not the
# contract the gate exists to prove.
for header in \
  '<executorch/extension/flat_tensor/serialize/serialize.h>' \
  '<executorch/extension/flat_tensor/serialize/flat_tensor_header.h>' \
  '<executorch/extension/flat_tensor/flat_tensor_data_map.h>' \
  '<executorch/extension/named_data_map/merged_data_map.h>'; do
  assert_contains "$src" "#include $header" "roundtrip includes $header"
done

# Alignment is a single decision: 128 everywhere, matching export's segment_alignment default.
# Every non-comment save_ptd call must pass it, and no other alignment literal may appear.
code="$(printf '%s\n' "$src" | grep -v '^[[:space:]]*//')"
calls="$(printf '%s\n' "$code" | grep -c 'save_ptd(')"
aligned="$(printf '%s\n' "$code" | grep -c 'save_ptd([^;]*, 128)')"
assert_eq "$calls" "$aligned" "every save_ptd call passes alignment 128"
if printf '%s\n' "$code" | grep -qE 'save_ptd\([^;]*, (8|16|32|64|256)\)'; then
  printf 'FAIL: roundtrip passes an alignment other than 128\n' >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: roundtrip uses no alignment other than 128\n'
fi

# The stream overload must be opened binary: on Windows text mode doubles every 0x0A and the
# runtime rejects the file. This is the assertion that keeps a "simplification" from undoing it.
assert_contains "$code" "std::ios::binary" "roundtrip opens the stream in binary mode"

# The review-focus checks must exist by name, so a rewrite cannot quietly drop one.
for name in cross_writer_content overwrite_truncates missing_key_fails alignment_128 reload_merged; do
  assert_contains "$src" "\"$name\"" "roundtrip check $name present"
done
assert_contains "$src" "dir with space" "roundtrip writes into a directory with a space"

# The sweep must name every dtype it claims to cover; a dropped case is invisible otherwise.
for key in float double half bfloat16 char byte int long bool scalar_0d empty; do
  assert_contains "$sweep" "\"$key\"" "dtype sweep covers $key"
done
assert_contains "$sweep" "save_ptd(path, tensors, 128)" "dtype sweep saves at alignment 128"

# The consumer links the exported target by name and must include an installed prefix.
assert_contains "$cmake_src" "extension_flat_tensor_serialize" "consumer links the exported writer target"
assert_contains "$cmake_src" "find_package(ExecuTorch REQUIRED CONFIG)" "consumer uses an installed prefix"
# The consumer must link the portable-op REGISTRATION archive normally (without it the fixture's
# aten::addmm.out is "not found" at load), but must not whole-archive it -- the spike aborted with
# duplicate kernel registration when portable_ops_lib was whole-archived on top of executorch.
assert_contains "$cmake_src" "portable_ops_lib" "consumer links the portable ops registration archive"
if printf '%s\n' "$cmake_src" | grep -v '^[[:space:]]*#' \
    | grep -qE 'whole-archive|WHOLEARCHIVE|-force_load|WHOLE_ARCHIVE'; then
  printf 'FAIL: consumer must not whole-archive portable_ops_lib (duplicate registration)\n' >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: consumer does not whole-archive the ops registration archive\n'
fi

# The Windows sibling must read the CRT from BUILDINFO rather than hardcoding /MD or /MT.
assert_contains "$(cat "$windows_gate")" "crt_for_platform" "windows gate reads the CRT from BUILDINFO"
assert_contains "$(cat "$windows_gate")" "CMAKE_MSVC_RUNTIME_LIBRARY" "windows gate passes the CRT to CMake"

exit "$ASSERT_FAILS"
