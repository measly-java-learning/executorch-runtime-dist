#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "${tmpv:-}"' EXIT

# sha256sum-format file: "<hex>  <filename>"; only field 1 (hex) is read.
mk() { printf '%s  %s\n' "$1" "${2%.sha256}" > "$tmp/$2"; }

# Asymmetric coverage: Linux x3 variants + Windows logging-only.
mk aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaacafef00d executorch-runtime-1.3.1-bare-linux-x86_64.tar.gz.sha256
mk bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbdeadbeef executorch-runtime-1.3.1-devtools-linux-x86_64.tar.gz.sha256
mk ccccccccccccccccccccccccccccccccccccccccccccccccccccccccfeedface executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
mk dddddddddddddddddddddddddddddddddddddddddddddddddddddddd12345678 executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz.sha256
mk 1111111111111111111111111111111111111111111111111111111122223333 executorch-runtime-1.3.1-logging-windows-x86_64-static.tar.gz.sha256
# Foreign etver — must be ignored.
mk eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee99999999 executorch-runtime-9.9.9-logging-linux-x86_64.tar.gz.sha256

out="$(bash "$here/../scripts/discover-pin-rows.sh" --dir "$tmp" --etver 1.3.1)"

expected="$(printf 'bare\tlinux-x86_64\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaacafef00d\ndevtools\tlinux-x86_64\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbdeadbeef\nlogging\tlinux-x86_64\tccccccccccccccccccccccccccccccccccccccccccccccccccccccccfeedface\nlogging\twindows-x86_64\tdddddddddddddddddddddddddddddddddddddddddddddddddddddddd12345678\nlogging\twindows-x86_64-static\t1111111111111111111111111111111111111111111111111111111122223333')"
assert_eq "$out" "$expected" "asymmetric discovery, sorted platform then variant, foreign etver excluded"

# Platform string containing a dash is split correctly (variant vs platform).
assert_contains "$out" "$(printf 'logging\twindows-x86_64\tdddddddddddddddddddddddddddddddddddddddddddddddddddddddd12345678')" "dash-containing platform split correctly"

# A platform with TWO dashes must still split correctly (variant is everything before the FIRST dash).
assert_contains "$out" "$(printf 'logging\twindows-x86_64-static\t1111111111111111111111111111111111111111111111111111111122223333')" "two-dash platform split correctly"

# Exactly 5 rows (foreign etver dropped).
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "5" "foreign-etver file excluded from row count"

# Test case: all-variants single-platform (order-independent)
# Regression test for the "today's Linux-only, all-variants" case (bare + logging + devtools).
# Pin output equivalence is defined on the row SET (order-independent), not byte order.
tmpv="$(mktemp -d)"

mkv() { printf '%s  %s\n' "$1" "${2%.sha256}" > "$tmpv/$2"; }

mkv aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbcc executorch-runtime-1.3.1-bare-linux-x86_64.tar.gz.sha256
mkv eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
mkv ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff executorch-runtime-1.3.1-devtools-linux-x86_64.tar.gz.sha256

outv="$(bash "$here/../scripts/discover-pin-rows.sh" --dir "$tmpv" --etver 1.3.1)"

# Assert all three rows are present (order-independent)
assert_contains "$outv" "$(printf 'bare\tlinux-x86_64\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbcc')" "all-variants single-platform: bare row present"
assert_contains "$outv" "$(printf 'logging\tlinux-x86_64\teeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee')" "all-variants single-platform: logging row present"
assert_contains "$outv" "$(printf 'devtools\tlinux-x86_64\tffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')" "all-variants single-platform: devtools row present"

# Assert exactly 3 rows (no extra rows)
assert_eq "$(printf '%s\n' "$outv" | grep -c .)" "3" "all-variants single-platform: exactly 3 rows"

# Test case: empty dir fails loudly
# Regression test for FIX 1: a broken artifact download (empty dir) must not silently
# produce an empty pin file. The script must exit non-zero.
mkdir -p "$tmp/empty"
bash "$here/../scripts/discover-pin-rows.sh" --dir "$tmp/empty" --etver 1.3.1 >/dev/null 2>&1 \
  || empty_exit=$? || true
assert_eq "${empty_exit:-0}" "1" "empty dist fails loudly"

# Test case: fixtures sibling excluded, real artifact still found
# Verify that an unrelated .tar.gz.sha256 file (e.g. fixtures tarball) is correctly
# excluded from discovery by our naming scheme; only the matching executorch-runtime-*
# prefix is processed.
mkdir -p "$tmp/fix"
printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz\n' \
  > "$tmp/fix/executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256"
printf 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210  etnp-lstm-fixtures-1.3.1.tar.gz\n' \
  > "$tmp/fix/etnp-lstm-fixtures-1.3.1.tar.gz.sha256"
out_fix="$(bash "$here/../scripts/discover-pin-rows.sh" --dir "$tmp/fix" --etver 1.3.1)"
assert_contains "$out_fix" "logging" "fixtures sibling excluded: logging row present"
assert_eq "$(printf '%s\n' "$out_fix" | grep -c .)" "1" "fixtures sibling excluded: exactly 1 row (fixtures not included)"

exit "$ASSERT_FAILS"
