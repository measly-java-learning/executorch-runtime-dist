#!/usr/bin/env bash
# Thin invoker: the real checks parse workflow YAML and live in test/lib/extras_gate_ov_windows.py.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/lib/extras_gate_ov_windows.py"
exit $?
