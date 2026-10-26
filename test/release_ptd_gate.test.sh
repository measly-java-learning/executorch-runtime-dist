#!/usr/bin/env bash
# Thin invoker: the real checks parse release.yml and live in test/lib/release_ptd_gate.py
# (CLAUDE.md: structural workflow checks stay out of shell scripts).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/lib/release_ptd_gate.py"
