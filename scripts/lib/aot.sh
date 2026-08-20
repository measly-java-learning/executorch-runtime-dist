#!/usr/bin/env bash
# Build-environment prep for the AOT-side ExecuTorch python package build
# (install_executorch.sh). SINGLE SOURCE OF TRUTH: sourced by every call site that runs that
# install — the gate's full-aot step and the lstm-roundtrip composite action, which the release
# workflow also uses — so the two can never drift. Source me.
#
# WHY THIS EXISTS. ExecuTorch v1.4.1 moved its pybind11 submodule 2.13.6 -> 3.0.4. pybind11 3.0
# removed the classic FindPythonLibsNew path, so CMake's FindPython is now mandatory; it requests
# Development.Module with Development.Embed only OPTIONAL, and defines the Python::Python target
# only when Embed is found. The manylinux_2_28 base ships a STATICALLY linked cp312 with no
# libpython on disk at all — not even the .a its own sysconfig advertises (Py_ENABLE_SHARED=0,
# LDLIBRARY=libpython3.12.a, file absent) — so Embed is unsatisfiable out of the box and every
# `pybind11_add_module(... SHARED ...)` in ET dies at configure with
#   Python_ADD_LIBRARY: dependent target 'Python::Python' is not defined.
# Upstream does not hit this: their wheel CI uses pytorch/test-infra's build_wheels_linux, i.e.
# pytorch's manylinux builder, which does ship a shared libpython.
#
# WHY NOT JUST TURN THE PYBIND TARGETS OFF. Tried, and it does not hold together. -DEXECUTORCH_
# BUILD_PYBIND=OFF configures clean but breaks the BUILD, because setup.py picks its --target list
# on different conditions than CMake uses to create those targets: it asks for _llm_runner on
# EXECUTORCH_BUILD_EXTENSION_LLM_RUNNER, _training_lib on EXECUTORCH_BUILD_EXTENSION_TRAINING and
# executorchcoreml on EXECUTORCH_BUILD_COREML — all ON in the Linux preset — while CMake only
# creates them under if(EXECUTORCH_BUILD_PYBIND). The result is
#   gmake: *** No rule to make target '_llm_runner'.  Stop.
# Suppressing that needs five flags in total, three of which exist purely to paper over an upstream
# inconsistency any future ET bump is free to reshuffle. Installing the devel package instead needs
# none, and keeps us on the configuration upstream actually tests.
#
# TEMPORARY. This belongs in the build image, not in a CI step — tracked in
# https://github.com/measly-java-learning/executorch-runtime-dist/issues/41 (a separate
# executorch-dist-build image in measly-java-learning/base-docker-images). build-runtime.sh already
# installs systemtap-sdt-devel and pip-installs ninja at build time for the same reason, and that
# image would absorb all three. When it lands, this function becomes an assertion, matching the
# MEASLY_DJL_PINNED_IMAGE contract: inside a pinned image a missing tool is a broken image, not
# something to fix at run time.

# The devel package matching the interpreter that will build the wheel. Derived, never hardcoded:
# CPython's C ABI is stable within a MINOR version, so the libpython we link must be the running
# interpreter's minor. A hardcoded 3.12 would silently link the wrong runtime the day the image
# moves to cp313; deriving it means the install simply fails to find the package instead.
et_aot_python_devel_pkg() {
  python3 -c 'import sys; print("python%d.%d-devel" % sys.version_info[:2])'
}

# Install the AOT build dependencies into the current container. Idempotent (dnf install -y on an
# already-present package is a no-op), so it is safe at every call site.
et_aot_install_build_deps() {
  local pkg mm lib
  pkg="$(et_aot_python_devel_pkg)" || return 1
  mm="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" || return 1
  echo ">> installing AOT build deps: $pkg (shared libpython for FindPython Development.Embed)"
  dnf install -y "$pkg" >/dev/null || { echo "   FAIL: could not install $pkg" >&2; return 1; }
  lib="/usr/lib64/libpython${mm}.so"
  # Assert rather than trust: the whole point of the package is this one file, and a silent miss
  # here reappears much later as the confusing Python::Python configure error above.
  [ -e "$lib" ] || { echo "   FAIL: $pkg installed but $lib is missing" >&2; return 1; }
  echo "   ok: $lib"
}
