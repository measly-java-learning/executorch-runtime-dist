#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
base="https://github.com/measly-java-learning/executorch-runtime-dist/releases/download/v1.3.1-1"
out="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 --base-url "$base" \
  --row logging linux-x86_64 deadbeef --row bare linux-x86_64 cafef00d)"
assert_contains "$out" 'set(ET_RUNTIME_VERSION "1.3.1-1")'    "version var"
assert_contains "$out" 'set(ET_RUNTIME_ET_VERSION "1.3.1")'   "et version var"
assert_contains "$out" "set(ET_RUNTIME_URL_logging_linux-x86_64" "logging url var"
assert_contains "$out" "$base/executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz" "logging url value"
assert_contains "$out" 'set(ET_RUNTIME_SHA256_logging_linux-x86_64 "deadbeef")' "logging sha"
assert_contains "$out" 'set(ET_RUNTIME_SHA256_bare_linux-x86_64 "cafef00d")'    "bare sha"

# The selector is the consumer-facing entry point (contract C6): consumers call it instead of
# string-building a variable name, so an unknown variant/platform is a loud error at configure time
# rather than an empty string that surfaces later as a confusing FetchContent failure. Grepping the
# generated text would only prove the function was *emitted*, so drive it through real cmake.
command -v cmake >/dev/null 2>&1 \
  || { printf 'FAIL: cmake is required to exercise the pin selector\n' >&2; exit 1; }
pin_dir="$(mktemp -d)"
trap 'rm -rf "$pin_dir"' EXIT
printf '%s\n' "$out" > "$pin_dir/EtRuntimePin.cmake"
probe="$here/fixtures/pin/selector_probe.cmake"

assert_contains "$out" 'function(et_runtime_dist_url variant platform out_url out_sha)' "selector defined"

sel="$(cmake -DPIN="$pin_dir/EtRuntimePin.cmake" -DV=logging -DP=linux-x86_64 -P "$probe" 2>&1)"
assert_eq "$?" "0" "selector resolves a known row"
assert_contains "$sel" "URL=$base/executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz" "selector returns the row url"
assert_contains "$sel" "SHA=deadbeef" "selector returns the row sha"

# An unknown combination must abort naming both values, not silently yield "".
bad="$(cmake -DPIN="$pin_dir/EtRuntimePin.cmake" -DV=devtools -DP=linux-aarch64 -P "$probe" 2>&1)"
assert_eq "$?" "1" "selector aborts on a combination with no row"
assert_contains "$bad" "variant='devtools'" "selector error names the variant"
assert_contains "$bad" "platform='linux-aarch64'" "selector error names the platform"

. "$here/../scripts/lib/openvino.sh"
# Distinct 64-hex placeholders: a cross-wired variable then fails its assertion loudly.
row_sha="$(printf 'a%.0s' $(seq 64))"   # the tarball row (--row logging linux-x86_64)
ovsha="$(printf 'b%.0s' $(seq 64))"     # the linux bundle row
ovsha_win="$(printf 'c%.0s' $(seq 64))" # the windows bundle row

# Per-platform rows, mirroring the tarball rows' shape.
pin_ov="$("$here/../scripts/gen-pin.sh" --version 1.2.3-1 --etver 1.2.3 --base-url "$base" \
  --row logging linux-x86_64 "$row_sha" \
  --openvino-row linux-x86_64 "$ovsha" --openvino-row windows-x86_64 "$ovsha_win")"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_VERSION \"$OV_VERSION\")" "pin records openvino version"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256_linux-x86_64 \"$ovsha\")"   "linux row"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256_windows-x86_64 \"$ovsha_win\")" "windows row"
assert_contains "$pin_ov" 'set(ET_RUNTIME_OPENVINO_SHA256_windows-x86_64-static "${ET_RUNTIME_OPENVINO_SHA256_windows-x86_64}")' "static alias sha row"
assert_contains "$pin_ov" 'set(ET_RUNTIME_OPENVINO_URL_windows-x86_64-static "${ET_RUNTIME_OPENVINO_URL_windows-x86_64}")' "static alias url row"
assert_contains "$pin_ov" 'function(et_runtime_openvino_url platform out_url out_sha)' "selector defined"

# The legacy trio must survive: docs/openvino-jni-consumer.md instructs consumers to test
# `ET_RUNTIME_ROW STREQUAL ET_RUNTIME_OPENVINO_PLATFORM`, and dropping it would break every
# existing consumer at the next release with no CI signal anywhere.
assert_contains "$pin_ov" 'set(ET_RUNTIME_OPENVINO_PLATFORM "linux-x86_64")' "legacy platform var kept"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256 \"$ovsha\")" "legacy sha var kept"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_URL
  \"$base/$(ov_tarball_name linux-x86_64)\")" "legacy url names the linux bundle"
assert_contains "$pin_ov" "DEPRECATED" "legacy vars are marked deprecated"

# A release with no bundle at all still yields a valid pin.
pin_no="$("$here/../scripts/gen-pin.sh" --version 1.2.3-1 --etver 1.2.3 --base-url "$base" \
  --row logging linux-x86_64 "$row_sha")"
if printf '%s\n' "$pin_no" | grep -q '^set(ET_RUNTIME_OPENVINO_'; then
  printf 'FAIL: pin without an openvino row must emit no ET_RUNTIME_OPENVINO_* vars\n' >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: openvino-free pin is clean\n'
fi

# Run the selector through real cmake, the way selector_probe.cmake proves the tarball selector.
# A generated function that merely LOOKS right is not the property we need.
printf '%s\n' "$pin_ov" > "$pin_dir/pin_ov.cmake"
for p in linux-x86_64 windows-x86_64 windows-x86_64-static; do
  out="$(cmake -DPIN="$pin_dir/pin_ov.cmake" -DP="$p" -P "$here/fixtures/pin/openvino_selector_probe.cmake" 2>&1)" \
    || { printf 'FAIL: openvino selector aborted for %s\n%s\n' "$p" "$out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); continue; }
  # The alias row names the bundle platform's tarball (windows-x86_64), not a -static asset.
  assert_contains "$out" "$(ov_tarball_name "$(ov_bundle_platform "$p")")" "selector resolves the $p bundle"
done
# Absence must be reported as empty, NOT as a fatal error: linux-aarch64 legitimately has no
# bundle, and a consumer building that row must be able to ask and get "no".
out="$(cmake -DPIN="$pin_dir/pin_ov.cmake" -DP=linux-aarch64 -P "$here/fixtures/pin/openvino_selector_probe.cmake" 2>&1)" \
  || { printf 'FAIL: selector must not abort for a platform with no bundle\n%s\n' "$out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$out" "URL=" "selector returns an empty url for aarch64"

# A malformed sha must abort rather than publish a pin that downstream re-verification rejects.
row_ok="$(printf 'a%.0s' $(seq 64))"
for bad in "" "abc" "$(printf 'z%.0s' $(seq 64))" "$(printf 'a%.0s' $(seq 63))"; do
  bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 --base-url https://ex.test/dl \
    --row logging linux-x86_64 "$row_ok" --openvino-row linux-x86_64 "$bad" >/dev/null 2>&1
  assert_eq "$?" "1" "gen-pin rejects malformed --openvino-row sha ('${bad:0:8}')"
done

exit "$ASSERT_FAILS"
