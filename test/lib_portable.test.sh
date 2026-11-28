#!/usr/bin/env bash
# Hermetic tests for scripts/lib/portable.sh. Must pass on both GNU (Linux CI) and BSD (macOS CI)
# userland; that is the whole point of the helpers.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/portable.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# require_bash4: this suite runs under bash >= 4 on both CI legs.
require_bash4; assert_eq "$?" "0" "require_bash4 passes under the running bash"
# BASH_VERSINFO is readonly, so the failure path can only be tested under a real bash 3. macOS
# ships one at /bin/bash, which makes the macOS CI leg the place this assertion has teeth.
if /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' 2>/dev/null; then
  msg="$(/bin/bash -c ". '$here/../scripts/lib/portable.sh'; require_bash4" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ]; assert_eq "$?" "0" "require_bash4 fails under /bin/bash 3"
  assert_contains "$msg" "bash >= 4 required" "bash 3 message names the requirement"
  assert_contains "$msg" "brew install bash" "bash 3 message names the macOS fix"
else
  printf 'ok: (skipped) /bin/bash is >= 4 on this host; failure path covered on macOS\n'
fi

# sed_inplace: edits in place, leaves no backup, and handles -E plus a multi-line replacement.
printf 'alpha\nbeta\n' > "$tmp/f"
sed_inplace 's/alpha/ALPHA/' "$tmp/f"
assert_eq "$(cat "$tmp/f")" "$(printf 'ALPHA\nbeta')" "sed_inplace edits in place"
assert_eq "$(ls "$tmp")" "f" "sed_inplace leaves no backup file"
sed_inplace -E 's/(be)ta/\1TA/' "$tmp/f"
assert_eq "$(sed -n 2p "$tmp/f")" "beTA" "sed_inplace passes -E through"
sed_inplace 's#^\(ALPHA\)$#\1\
inserted#' "$tmp/f"
assert_eq "$(cat "$tmp/f")" "$(printf 'ALPHA\ninserted\nbeTA')" "sed_inplace: POSIX newline-in-replacement works"
sed_inplace 's/x/y/' "$tmp/missing" 2>/dev/null
[ $? -ne 0 ]; assert_eq "$?" "0" "sed_inplace fails on a missing file"
case "$tmp/f" in *' '*) ;; esac
mkdir -p "$tmp/sp ace"; printf 'a\n' > "$tmp/sp ace/g"
sed_inplace 's/a/b/' "$tmp/sp ace/g"
assert_eq "$(cat "$tmp/sp ace/g")" "b" "sed_inplace handles a path with spaces"
assert_eq "$(ls "$tmp/sp ace")" "g" "no backup left for a path with spaces"

# ncpu: a positive integer.
n="$(ncpu)"
case "$n" in ''|*[!0-9]*) assert_eq "$n" "<positive integer>" "ncpu is numeric" ;;
  *) [ "$n" -ge 1 ]; assert_eq "$?" "0" "ncpu is a positive integer ($n)" ;; esac
# Fallback: no nproc, no sysctl -> NUMBER_OF_PROCESSORS, then 4.
assert_eq "$(nproc() { return 127; }; sysctl() { return 1; }; NUMBER_OF_PROCESSORS=7 ncpu)" "7" "ncpu falls back to NUMBER_OF_PROCESSORS"
assert_eq "$(nproc() { return 127; }; sysctl() { return 1; }; unset NUMBER_OF_PROCESSORS; ncpu)" "4" "ncpu final fallback is 4"

# sha256_file: sha256sum-format output, same digest from either implementation.
printf 'abc' > "$tmp/h"
want="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
out="$(cd "$tmp" && sha256_file h)"
assert_eq "$out" "$want  h" "sha256_file output matches sha256sum format"
# The fallback exists for macOS. manylinux has sha256sum but no shasum, so there is nothing to test.
if command -v shasum >/dev/null 2>&1; then
  out="$(cd "$tmp" && command() { [ "$2" = sha256sum ] && return 1; builtin command "$@"; }; sha256_file h)"
  assert_eq "$out" "$want  h" "sha256_file shasum fallback gives the same line"
else
  printf 'ok: (skipped) no shasum on this host; fallback covered on macOS\n'
fi

# host_os: one of the three supported values on any CI or dev host, and the mapping is uname-driven.
h="$(host_os)"
case "$h" in linux|macos|windows) printf 'ok: host_os is a supported value (%s)\n' "$h" ;;
  *) assert_eq "$h" "linux|macos|windows" "host_os is a supported value" ;; esac
assert_eq "$(uname() { echo Darwin; }; host_os)"            "macos"   "host_os: Darwin -> macos"
assert_eq "$(uname() { echo Linux; }; host_os)"             "linux"   "host_os: Linux -> linux"
assert_eq "$(uname() { echo MINGW64_NT-10.0; }; host_os)"   "windows" "host_os: Git-Bash -> windows"
(uname() { echo SunOS; }; host_os) >/dev/null 2>&1
assert_eq "$?" "1" "host_os: unsupported host fails instead of guessing"

[ "$ASSERT_FAILS" -eq 0 ]
