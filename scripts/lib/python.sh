#!/usr/bin/env bash
# Which interpreter to run. SINGLE SOURCE OF TRUTH — sourced by scripts/vendor-openvino.sh and by
# test/openvino_bundle.test.sh, the hermetic test that drives it, so the script and its test can
# never disagree about what "python" means on a given machine. Source me.
#
# The NAME is an environment detail, not a version choice: stock Debian/Ubuntu ship only `python3`,
# while the manylinux container (PATH=/opt/python/cp312-cp312/bin) and Git for Windows both put
# `python` on PATH. Every caller here uses module entry points (`-m pip`, `-m zipfile`) that work
# under either name, so this is a lookup, not a policy.
#
# Prefers `python` to stay consistent with build-runtime.sh, which installs the build's deps with
# `python -m pip` — resolving differently here could pick an interpreter those deps are not in.
#
# Returns the name on stdout and 1 if neither exists. Callers must NOT default to a literal
# `python`: a missing interpreter is a broken environment, and the failure should say so rather
# than surface later as `python: command not found` from inside an unrelated command.
et_python_bin() {
  if command -v python  >/dev/null 2>&1; then printf 'python';  return 0; fi
  if command -v python3 >/dev/null 2>&1; then printf 'python3'; return 0; fi
  echo "et_python_bin: neither 'python' nor 'python3' is on PATH" >&2
  return 1
}

# Can <python> pip-install into itself? Not if it is PEP 668 "externally managed" (Homebrew Python
# on macOS, Debian/Ubuntu system Python) and is not running in a venv: pip refuses with
# "externally-managed-environment" partway through the build. The manylinux CPythons and
# actions/setup-python interpreters are not externally managed, so they pass with or without a
# venv. That is the precise property, unlike "is this a venv", which would wrongly reject them.
# Returns 0 if installable, 1 if not.
# The interpreter reports two facts ("<managed> <venv>", each 0/1); the decision stays in shell, so
# the test can drive it with a stub interpreter.
et_python_pip_installable() { # <python>
  local _facts
  _facts="$("$1" -c 'import os, sys, sysconfig
m = os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED"))
print(int(m), int(sys.prefix != sys.base_prefix))')" || return 1
  case "$_facts" in
    "1 0") return 1 ;;
    *) return 0 ;;
  esac
}
