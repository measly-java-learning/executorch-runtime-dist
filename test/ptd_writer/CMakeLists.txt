# Standalone consumer of an INSTALLED ExecuTorch prefix. Two executables, no source tree, no
# build tree: this is exactly what a downstream JNI/engine consumer sees, so it fails to configure
# or link if the .ptd writer target or any of the four installed headers is missing.
cmake_minimum_required(VERSION 3.24)
project(ptd_writer_gate CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(ExecuTorch REQUIRED CONFIG)

# `executorch` is the runtime only; the exported model calls aten::addmm/permute_copy, whose
# registration lives in portable_ops_lib. Link it NORMALLY. Do not whole-archive it on top of
# executorch -- the spike aborted at startup with duplicate kernel registration when it did. A
# plain link (as here) pulls only the registration objects the program needs.
set(PTD_WRITER_LIBS
    extension_flat_tensor_serialize
    extension_module_static
    extension_data_loader
    extension_tensor
    extension_flat_tensor
    extension_named_data_map
    executorch
    portable_ops_lib
    portable_kernels)

add_executable(ptd_roundtrip ptd_roundtrip.cpp)
target_link_libraries(ptd_roundtrip PRIVATE ${PTD_WRITER_LIBS})

add_executable(ptd_dtype_sweep ptd_dtype_sweep.cpp)
target_link_libraries(ptd_dtype_sweep PRIVATE ${PTD_WRITER_LIBS})
