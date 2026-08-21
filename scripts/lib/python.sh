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
