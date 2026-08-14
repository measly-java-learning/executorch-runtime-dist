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

. "$here/../scripts/lib/openvino.sh"
ovsha="$(printf 'b%.0s' $(seq 64))"
pin_ov="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 \
  --base-url https://example.test/dl --row logging linux-x86_64 "$(printf 'a%.0s' $(seq 64))" \
  --openvino-sha "$ovsha")"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_VERSION \"$OV_VERSION\")" "pin records openvino version"
assert_contains "$pin_ov" "https://example.test/dl/$(ov_tarball_name linux-x86_64)" "pin records openvino url"
assert_contains "$pin_ov" "set(ET_RUNTIME_OPENVINO_SHA256 \"$ovsha\")" "pin records openvino sha"

# Omitting the flag must leave the pin exactly as before (no empty/dangling vars).
pin_no="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 \
  --base-url https://example.test/dl --row logging linux-x86_64 "$(printf 'a%.0s' $(seq 64))")"
case "$pin_no" in
  *OPENVINO*) printf 'FAIL: pin must omit OpenVINO vars when no sha is given\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: pin omits OpenVINO vars when not requested\n' ;;
esac
exit "$ASSERT_FAILS"
