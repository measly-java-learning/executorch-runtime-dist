#!/usr/bin/env bash
# scripts/lib/python.sh: et_python_pip_installable decides from two facts the interpreter reports
# ("<externally-managed> <in-venv>"). Driven by stub interpreters so the test is hermetic: no real
# Homebrew/Debian Python needed to cover the refuse case.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/python.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

stub() { # <name> <facts>
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$tmp/$1"; chmod +x "$tmp/$1"
}
stub managed_novenv "1 0"; stub managed_venv "1 1"; stub plain_novenv "0 0"; stub plain_venv "0 1"
printf '#!/bin/sh\nexit 1\n' > "$tmp/broken"; chmod +x "$tmp/broken"

et_python_pip_installable "$tmp/managed_novenv"; assert_eq "$?" "1" "externally managed, no venv -> refuse (Homebrew/Debian system python)"
et_python_pip_installable "$tmp/managed_venv";   assert_eq "$?" "0" "externally managed base, inside a venv -> ok"
et_python_pip_installable "$tmp/plain_novenv";   assert_eq "$?" "0" "not managed, no venv -> ok (manylinux, setup-python)"
et_python_pip_installable "$tmp/plain_venv";     assert_eq "$?" "0" "not managed, venv -> ok"
et_python_pip_installable "$tmp/broken";         assert_eq "$?" "1" "interpreter that cannot answer -> refuse"
# The real interpreter answers in the expected shape (whatever its verdict on this host).
py="$(et_python_bin)" && { et_python_pip_installable "$py"; rc=$?; case "$rc" in 0|1) printf 'ok: real %s answers (rc=%s)\n' "$py" "$rc" ;; *) assert_eq "$rc" "0|1" "real interpreter answers" ;; esac; }
exit "$ASSERT_FAILS"
