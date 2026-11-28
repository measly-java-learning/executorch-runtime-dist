#!/usr/bin/env bash
# Structural guard on the SHIPPED consumer helper (extras/cmake/ETNPExtras.cmake.in). The failure it
# prevents: a whole-archive branch that links an archive by PATH (-force_load,<IMPORTED_LOCATION>)
# instead of linking the TARGET. That silently drops the target's INTERFACE_LINK_LIBRARIES
# (etnp_hwy), and every consumer link then fails on undefined hwy::* symbols.
# Hermetic on purpose (text checks, no cmake run): the behavioral proof is the LSTM round-trip,
# which links lstm_runner through this helper on each platform's release leg.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
H="$here/../extras/cmake/ETNPExtras.cmake.in"

# The function body, with comments stripped (the explanatory comment names the bad form on purpose).
body="$(sed -n '/^function(etnp_extras_whole_archive/,/^endfunction/p' "$H" | sed 's/#.*$//')"
[ -n "$body" ]; assert_eq "$?" "0" "helper defines etnp_extras_whole_archive"

case "$body" in *force_load*) assert_eq "raw -force_load present" "absent" "no raw -force_load in the helper (CMake lowers WHOLE_ARCHIVE to it)" ;;
  *) printf 'ok: no raw -force_load in the helper\n' ;; esac
case "$body" in *--whole-archive*) assert_eq "raw --whole-archive present" "absent" "no raw --whole-archive in the helper" ;;
  *) printf 'ok: no raw --whole-archive in the helper\n' ;; esac
case "$body" in *"if(APPLE)"*|*"elseif(APPLE)"*) assert_eq "APPLE branch present" "absent" "no separate APPLE branch (Apple shares the WHOLE_ARCHIVE branch)" ;;
  *) printf 'ok: no separate APPLE branch\n' ;; esac

# Every target_link_libraries call links the target itself: either as a bare ${_lib} item or
# through $<LINK_LIBRARY:WHOLE_ARCHIVE,${_lib}>. An IMPORTED_LOCATION alone is the bug.
calls="$(printf '%s\n' "$body" | awk '/target_link_libraries\(/{c=$0; while (c !~ /\)[[:space:]]*$/ && (getline l) > 0) c=c" "l; print c}')"
n=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  n=$((n+1))
  case "$c" in
    *'$<LINK_LIBRARY:WHOLE_ARCHIVE,${_lib}>'*) printf 'ok: call %d links the target via WHOLE_ARCHIVE\n' "$n" ;;
    *' ${_lib}'[[:space:]]*|*' ${_lib})'*) printf 'ok: call %d links the target as an item\n' "$n" ;;
    *) printf 'FAIL: call %d links an archive path without the target: %s\n' "$n" "$c" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  esac
done <<EOF
$calls
EOF
assert_eq "$n" "2" "helper has exactly the MSVC and GNU/Apple link calls"

# WHOLE_ARCHIVE needs CMake >= 3.24; every in-repo consumer of the helper must declare at least that.
for f in "$here/../extras/lstm/test/CMakeLists.txt" "$here/../extras/CMakeLists.txt"; do
  v="$(grep -oE 'cmake_minimum_required\(VERSION [0-9.]+' "$f" | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
  major="${v%%.*}"; minor="${v#*.}"
  [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 24 ]; }
  assert_eq "$?" "0" "$(basename "$(dirname "$f")")/CMakeLists.txt requires CMake >= 3.24 (has $v)"
done
exit "$ASSERT_FAILS"
