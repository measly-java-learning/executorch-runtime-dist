#!/usr/bin/env bash
# --extras-only guards: requires --prefix + --variant and an existing ET config;
# fails fast (non-zero) when the prefix has no executorch-config.cmake.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# empty prefix (no executorch-config.cmake) must fail fast, not attempt a build
"$root/build-runtime.sh" --extras-only --variant logging --prefix "$tmp/empty" 2>"$tmp/err"
rc=$?
[ "$rc" -ne 0 ] || { echo "expected non-zero on missing ET config"; fail=1; }
grep -qi 'executorch-config.cmake' "$tmp/err" || { echo "expected a clear config-missing error"; fail=1; }

# missing --prefix must fail with usage/required error
"$root/build-runtime.sh" --extras-only --variant logging 2>"$tmp/err2"
[ "$?" -ne 0 ] || { echo "expected non-zero on missing --prefix"; fail=1; }

# --print-et-tag echoes the pinned default tag by letting the shell parse its own var
# (no brittle regex over the source; robust to any valid quoting) — used by classify-gate.sh
tag="$("$root/build-runtime.sh" --print-et-tag)"
[ "$tag" = "v1.3.1" ] || { echo "expected --print-et-tag=v1.3.1, got '$tag'"; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: --extras-only guards + --print-et-tag" || exit 1
