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
exit "$ASSERT_FAILS"
