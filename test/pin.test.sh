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
ovsha="$(printf 'b%.0s' $(seq 64))"
pin_ov="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 \
  --base-url https://example.test/dl --row logging linux-x86_64 "$(printf 'a%.0s' $(seq 64))" \
  --openvino-sha "$ovsha")"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_VERSION \"$OV_VERSION\")" "pin records openvino version"
assert_contains "$pin_ov" "https://example.test/dl/$(ov_tarball_name linux-x86_64)" "pin records openvino url"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256 \"$ovsha\")" "pin records openvino sha"
# The bundle exists for one platform only, but the pin is a single file every platform's build
# includes. Without this var a consumer cannot tell which row the bundle is for except by parsing
# the URL, so an aarch64 or Windows build has no honest way to skip it.
assert_contains "$pin_ov" 'set(ET_RUNTIME_OPENVINO_PLATFORM "linux-x86_64")' "pin records openvino platform"
pin_ov_arm="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 \
  --base-url https://example.test/dl --row logging linux-aarch64 "$(printf 'a%.0s' $(seq 64))" \
  --openvino-sha "$ovsha" --openvino-platform linux-aarch64)"
assert_contains "$pin_ov_arm" 'set(ET_RUNTIME_OPENVINO_PLATFORM "linux-aarch64")' "openvino platform follows the flag"

# Omitting the flag must leave the pin exactly as before (no empty/dangling vars). Match the
# declarations, not the bare word: the header comment documents these vars as optional, so a
# substring check would fire on the documentation rather than on a dangling var.
pin_no="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 \
  --base-url https://example.test/dl --row logging linux-x86_64 "$(printf 'a%.0s' $(seq 64))")"
if printf '%s\n' "$pin_no" | grep -q '^set(ET_RUNTIME_OPENVINO_'; then
  printf 'FAIL: pin must omit OpenVINO vars when no sha is given\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: pin omits OpenVINO vars when not requested\n'
fi

# A malformed sha must abort rather than publish a pin that downstream re-verification rejects.
row_ok="$(printf 'a%.0s' $(seq 64))"
for bad in "" "abc" "$(printf 'z%.0s' $(seq 64))" "$(printf 'a%.0s' $(seq 63))"; do
  bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 --base-url https://ex.test/dl \
    --row logging linux-x86_64 "$row_ok" --openvino-sha "$bad" >/dev/null 2>&1
  assert_eq "$?" "1" "gen-pin rejects malformed --openvino-sha ('${bad:0:8}')"
done
bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 --base-url https://ex.test/dl \
  --row logging linux-x86_64 "$row_ok" --openvino-sha "$(printf 'b%.0s' $(seq 64))" \
  --openvino-platform "" >/dev/null 2>&1
assert_eq "$?" "1" "gen-pin rejects an empty --openvino-platform"

exit "$ASSERT_FAILS"
