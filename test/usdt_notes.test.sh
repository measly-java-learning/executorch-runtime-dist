#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
CHK="$here/../scripts/check-usdt-notes.sh"

# Canned readelf --notes output with all three probes at correct arity (4/4/7).
good="$(cat <<'EOF'
Displaying notes found in: .note.stapsdt
  Owner                Data size 	Description
  stapsdt              0x0000004c	NT_STAPSDT (SystemTap probe descriptors)
    Provider: etnp
    Name: lstm_xnn_cache__hit
    Location: 0x1234, Base: 0x2000, Semaphore: 0x0
    Arguments: -4@%edi -4@%esi -4@%edx -4@%ecx
  stapsdt              0x0000004e	NT_STAPSDT (SystemTap probe descriptors)
    Provider: etnp
    Name: lstm_xnn_cache__miss
    Location: 0x1240, Base: 0x2000, Semaphore: 0x0
    Arguments: -4@%edi -4@%esi -4@%edx -4@%ecx
  stapsdt              0x0000005a	NT_STAPSDT (SystemTap probe descriptors)
    Provider: etnp
    Name: lstm_xnn_cache__evict
    Location: 0x1250, Base: 0x2000, Semaphore: 0x0
    Arguments: -4@%edi -4@%esi -4@%edx -4@%ecx -4@%r8d -4@%r9d -8@%rax
EOF
)"

# happy path: expect on -> pass
out="$(USDT_READELF_TEXT="$good" bash "$CHK" --expect on /nonexistent 2>&1)"; rc=$?
assert_eq "$rc" "0" "expect on with all three probes -> pass"

# missing __evict -> fail
noevict="$(printf '%s\n' "$good" | grep -v 'lstm_xnn_cache__evict')"
USDT_READELF_TEXT="$noevict" bash "$CHK" --expect on /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect on but __evict absent -> fail"

# wrong arity on __hit (3 instead of 4) -> fail
badarity="${good/-4@%edi -4@%esi -4@%edx -4@%ecx$'\n'  stapsdt/-4@%edi -4@%esi -4@%edx$'\n'  stapsdt}"
USDT_READELF_TEXT="$badarity" bash "$CHK" --expect on /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect on but __hit arity wrong -> fail"

# expect off with no stapsdt -> pass
USDT_READELF_TEXT="no notes here" bash "$CHK" --expect off /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "expect off with no stapsdt -> pass"

# expect off but stapsdt present -> fail
USDT_READELF_TEXT="$good" bash "$CHK" --expect off /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect off but stapsdt present -> fail"

# expect on but no provider at all -> fail
USDT_READELF_TEXT="no notes here" bash "$CHK" --expect on /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect on but provider absent -> fail"

exit "$ASSERT_FAILS"
