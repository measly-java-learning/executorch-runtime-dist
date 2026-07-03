cmake_minimum_required(VERSION 3.24)
project(et_pic_probe LANGUAGES CXX)
find_package(executorch CONFIG REQUIRED)
# SHARED is the whole point: linking a .so fails loudly if any linked static object (ET core or
# in-tree XNNPACK/flatcc) is non-PIC. An executable would link non-PIC static libs happily.
add_library(pic_probe SHARED probe.cpp)
target_link_libraries(pic_probe PRIVATE executorch)
