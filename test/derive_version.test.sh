#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

out="$(GITHUB_REF_NAME=v1.3.1-1 bash "$here/../scripts/derive-version.sh")"
assert_contains "$out" "pkgver=1.3.1-1" "pkgver"
assert_contains "$out" "etver=1.3.1"    "etver"
assert_contains "$out" "ettag=v1.3.1"   "ettag"

out2="$(GITHUB_REF_NAME=v2.0.0-3 bash "$here/../scripts/derive-version.sh")"
assert_contains "$out2" "pkgver=2.0.0-3" "pkgver (second pkgrev)"
assert_contains "$out2" "etver=2.0.0"    "etver (second pkgrev)"
assert_contains "$out2" "ettag=v2.0.0"   "ettag (second pkgrev)"

env -u GITHUB_REF_NAME bash "$here/../scripts/derive-version.sh" >/dev/null 2>&1
assert_eq "$?" "1" "missing GITHUB_REF_NAME is a hard error"

exit "$ASSERT_FAILS"
