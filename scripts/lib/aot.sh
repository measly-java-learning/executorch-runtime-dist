#!/usr/bin/env bash
# CMake args for the AOT-side ExecuTorch python package build (install_executorch.sh).
# SINGLE SOURCE OF TRUTH: sourced by every call site that runs install_executorch — the gate's
# full-aot step and the lstm-roundtrip composite action (which the release workflow also uses) —
# so the two can never drift. Source me.
#
# WHY PYBIND IS OFF. ExecuTorch v1.4.1 moved its pybind11 submodule 2.13.6 -> 3.0.4. pybind11 3.0
# removed the classic FindPythonLibsNew path, so CMake's FindPython is now mandatory; it is asked
# for Development.Module with Development.Embed only OPTIONAL, and therefore defines the
# Python::Python target only when Embed is found. The manylinux_2_28 image this repo pins has no
# shared libpython for cp312 (the interpreter is statically linked; `find / -name 'libpython3*.so*'`
# turns up only the system 3.6/3.11), so Embed is not found, Python::Python is undefined, and every
# `pybind11_add_module(... SHARED ...)` in ET fails at CONFIGURE time with
#   Python_ADD_LIBRARY: dependent target 'Python::Python' is not defined.
# Upstream does not hit this because their wheel CI uses pytorch/test-infra's build_wheels_linux,
# i.e. pytorch's manylinux builder, which does ship a shared libpython.
#
# Turning PYBIND off removes every such call: `if(EXECUTORCH_BUILD_PYBIND)` at ET's
# CMakeLists.txt:990 closes at 1208 and encloses both `add_subdirectory(codegen/tools)` (the
# selective_build module) and portable_lib, while the CoreML, extension/training and
# extension/llm/runner modules are each individually guarded by the same option.
#
# This costs us nothing: the AOT here only EXPORTS .pte files. Nothing in extras/, scripts/ or
# test/ imports executorch.extension.pybindings, and the live round-trip runs the exported model
# through a C++ runner built against the installed prefix, not through portable_lib. ET's own
# exir/ has no non-test reference to pybindings either.
#
# setup.py splices $CMAKE_ARGS straight into its `cmake ... --preset pybind` invocation, and ET's
# set_overridable_option only assigns when the name is NOT already defined — so a -D on that
# command line beats the preset. Extensions gated on the flag are then skipped, not failed.
et_aot_cmake_args() { printf -- '-DEXECUTORCH_BUILD_PYBIND=OFF'; }
