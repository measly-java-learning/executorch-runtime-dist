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
target_link_libraries(pic_probe PRIVATE executorch)
