#!/usr/bin/env bash
# Thin invoker: the real checks parse workflow YAML and live in test/lib/extras_gate_windows.py.
# test/run.sh globs *.test.sh, so this file is how that suite reaches them.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/lib/extras_gate_windows.py"
exit $?
