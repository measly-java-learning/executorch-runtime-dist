# Standalone extras build, configured by build-runtime.sh AFTER the ET install.
# Globs each op bundle under extras/*/runtime and aggregates their registrar TUs.
# One op today (lstm); a glob now, a manifest/codegen only once ops #2-3 exist.
cmake_minimum_required(VERSION 3.24)
project(etnp_extras LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ExecuTorch from the prefix we were just installed next to.
find_package(ExecuTorch CONFIG REQUIRED)

# ExecuTorch link set shared by every test/probe target below. Defined here in the
# driver core — NOT in a later appended block — so no target depends on the order in
# which the test/probe sections were appended to this file.
set(_ET_LINK
  executorch optimized_native_cpu_ops_lib xnnpack_backend
  extension_module_static extension_data_loader extension_tensor)

set(ETNP_EXTRAS_LIBS "")
set(ETNP_EXTRAS_ALL_EXPECT_TUS "")
file(GLOB _op_dirs RELATIVE "${CMAKE_CURRENT_LIST_DIR}" "${CMAKE_CURRENT_LIST_DIR}/*")
foreach(_d IN LISTS _op_dirs)
  set(_rt "${CMAKE_CURRENT_LIST_DIR}/${_d}/runtime/CMakeLists.txt")
  if(EXISTS "${_rt}")
    # Mechanism refuses to build an extra with no test (strategy Decision 3).
    if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/${_d}/test")
      message(FATAL_ERROR "extra '${_d}' has no test/ dir — every extra must ship a test")
    endif()
    add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/${_d}/runtime" "${CMAKE_BINARY_DIR}/${_d}")
    list(APPEND ETNP_EXTRAS_LIBS "etnp_ops_${_d}")
    list(APPEND ETNP_EXTRAS_ALL_EXPECT_TUS ${ETNP_EXTRAS_EXPECT_TUS})
  endif()
endforeach()

# no-duplicate-op-names guard: one etnp_ops_<op> per op dir, so a dup dir name is
# impossible; assert the TU list has no repeats (dup registrar => dup op name).
list(LENGTH ETNP_EXTRAS_ALL_EXPECT_TUS _n)
list(REMOVE_DUPLICATES ETNP_EXTRAS_ALL_EXPECT_TUS)
list(LENGTH ETNP_EXTRAS_ALL_EXPECT_TUS _nd)
if(NOT _n EQUAL _nd)
  message(FATAL_ERROR "duplicate registrar TU across extras: ${ETNP_EXTRAS_ALL_EXPECT_TUS}")
endif()
message(STATUS "etnp_extras: libs=[${ETNP_EXTRAS_LIBS}] expect_tus=[${ETNP_EXTRAS_ALL_EXPECT_TUS}]")

# --- per-op tests (built against the extras libs, whole-archived) ---
if(TARGET etnp_ops_lstm)
  add_executable(lstm_kernel_test lstm/test/lstm_kernel_test.cpp)
  target_link_libraries(lstm_kernel_test PRIVATE
    ${_ET_LINK} "$<LINK_LIBRARY:WHOLE_ARCHIVE,etnp_ops_lstm>")
endif()
