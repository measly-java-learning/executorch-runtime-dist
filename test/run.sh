#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fails=0
# The structural workflow checks (test/lib/*.py) need PyYAML. Without it, five test files die with
# identical ModuleNotFoundError tracebacks that hide the one-line cause. Check once, up front.
py="$(command -v python3 || command -v python || true)"
if [ -z "$py" ] || ! "$py" -c 'import yaml' 2>/dev/null; then
  echo "test/run.sh: PyYAML not importable by ${py:-python3}." >&2
  echo "  Install it: pip install -r requirements/unit.txt (on macOS, inside a venv)" >&2
  exit 2
fi
for t in "$here"/*.test.sh; do
  echo "== $t =="
  bash "$t" || fails=$((fails+1))
done
if [ "$fails" -eq 0 ]; then echo "ALL UNIT TESTS PASS"; else echo "$fails test file(s) FAILED" >&2; exit 1; fi
