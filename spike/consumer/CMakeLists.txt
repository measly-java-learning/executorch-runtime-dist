cmake_minimum_required(VERSION 3.24)
project(et_pic_probe LANGUAGES CXX)
find_package(executorch CONFIG REQUIRED)
# SHARED is the whole point: linking a .so fails loudly if any linked static
# object (ET core or in-tree XNNPACK/flatcc) is non-PIC.
add_library(pic_probe SHARED probe.cpp)
# `executorch` is the umbrella target from executorch-config.cmake. If that name
# is not exported, the gate script inspects the configs and we switch targets.
target_link_libraries(pic_probe PRIVATE executorch)
