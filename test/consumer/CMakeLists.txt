cmake_minimum_required(VERSION 3.24)
project(et_pic_probe LANGUAGES CXX)
find_package(executorch CONFIG REQUIRED)
# SHARED is the whole point: linking a .so fails loudly if any linked static object (ET core or
# in-tree XNNPACK/flatcc) is non-PIC. An executable would link non-PIC static libs happily.
add_library(pic_probe SHARED probe.cpp)
# ExecuTorch headers hard-#error below C++17. GCC defaults to gnu++17 so Linux never noticed, but
# MSVC defaults to C++14 and fails to compile the probe. The installed ExecuTorch package does not
# propagate a C++17 requirement via INTERFACE_COMPILE_FEATURES, so the consumer must request it.
target_compile_features(pic_probe PRIVATE cxx_std_17)
# executorch_backends is the upstream aggregate; on linux-x86_64 it includes openvino_backend,
# whose imported target carries --whole-archive. Linking it here is what makes the relocatability
# /PIC gate actually cover the delegate — with only `executorch`, no backend object is ever
# extracted and an OpenVINO regression would be invisible until model-load time.
#
# UNIX-only on purpose. This same project is also built by test/relocatability-windows.sh under
# MSVC, where the aggregate resolves to xnnpack_backend and would get /WHOLEARCHIVE'd into the probe
# DLL — pulling XNNPACK/pthreadpool/cpuinfo objects onto a link line that has never carried them.
# That may well work, but it is untested and only runs on a release-tag push, so a regression would
# surface mid-release. The delegate this change exists for is Linux-only, so scope the change to
# where it buys coverage. Revisit once it has been exercised on a Windows runner.
if(UNIX)
  target_link_libraries(pic_probe PRIVATE executorch executorch_backends)
else()
  target_link_libraries(pic_probe PRIVATE executorch)
endif()
