#!/usr/bin/env bash
# Compile requirements/*.in -> requirements/*.txt (fully pinned, hash-verified locks).
#   scripts/compile-requirements.sh            # rewrite the locks
#   scripts/compile-requirements.sh --check    # exit 1 if a lock is stale (NEEDS NETWORK)
#
# Requires uv. The locks MUST be universal: fast-gate runs the same requirements on both
# linux-x86_64 and linux-aarch64, so a lock resolved for one arch would be wrong on the other.
# `uv pip compile --universal` resolves across platforms and writes environment markers instead,
# which plain `pip-compile` cannot do - that, not speed, is why this step needs uv.
#
# CI installs the .txt (the lock), never the .in. Regenerate after editing any .in, and note that
# requirements/openvino-*.in are themselves generated - run scripts/gen-requirements.sh first.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT/requirements"

command -v uv >/dev/null 2>&1 || { echo "compile-requirements.sh: uv not found (https://docs.astral.sh/uv/)" >&2; exit 2; }

check=0
[ "${1:-}" = "--check" ] && check=1

# cp312 is the interpreter in both manylinux containers (PATH=/opt/python/cp312-cp312/bin).
# Pinning it here keeps the lock's markers matched to what CI actually runs.
#
# Deliberately NOT --generate-hashes. Hashes defend against a wheel being re-uploaded under an
# unchanged version, which is a supply-chain threat this repo has not otherwise signed up for, and
# they turn a ~20-line readable tree into 20KB of noise. The `# via` annotations uv emits are the
# point: they say which direct requirement pulled each transitive pin, so a surprising package in
# the lock is traceable to its cause. The header records the exact command to regenerate.
common=( --universal --python-version 3.12 --quiet )

fail=0
for in_file in *.in; do
  out="${in_file%.in}.txt"
  if [ "$check" -eq 1 ]; then
    tmp="$(mktemp)"
    uv pip compile "${common[@]}" "$in_file" -o "$tmp"
    if ! diff -q "$out" "$tmp" >/dev/null 2>&1; then
      echo "STALE: $out is not a current compile of $in_file" >&2
      diff -u "$out" "$tmp" | head -20 >&2 || true
      fail=1
    fi
    rm -f "$tmp"
  else
    uv pip compile "${common[@]}" "$in_file" -o "$out"
    echo "compiled $in_file -> $out"
  fi
done
exit "$fail"
