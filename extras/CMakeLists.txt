# Standalone extras build, configured by build-runtime.sh AFTER the ET install.
# Globs each op bundle under extras/*/runtime and aggregates their registrar TUs.
# One op today (lstm); a glob now, a manifest/codegen only once ops #2-3 exist.
cmake_minimum_required(VERSION 3.24)
project(etnp_extras LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- USDT tracepoints (Linux only; opt-out) ---------------------------------
# Probes are nop + non-alloc .note.stapsdt notes: no linked runtime dep, free
# when untraced. The header is __linux__-gated too; this option is the opt-out.
# Default ON on Linux, forced OFF elsewhere so future non-Linux targets build.
option(ETNP_ENABLE_USDT "Emit USDT tracepoints for the extras (Linux only)" ON)
if(ETNP_ENABLE_USDT AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(ETNP_USDT_EFFECTIVE ON)
  set(ETNP_USDT_EXPECT_WORD "on")
else()
  set(ETNP_USDT_EFFECTIVE OFF)
  set(ETNP_USDT_EXPECT_WORD "off")
endif()
if(ETNP_USDT_EFFECTIVE)
  include(CheckIncludeFileCXX)
  check_include_file_cxx("sys/sdt.h" ETNP_HAVE_SYS_SDT_H)
  if(NOT ETNP_HAVE_SYS_SDT_H)
    # Fail loudly rather than silently ship a probe-less artifact when USDT was
    # requested (same stance as the Highway-license "refuse to ship incomplete").
    message(FATAL_ERROR
      "ETNP_ENABLE_USDT=ON but <sys/sdt.h> not found. Install systemtap-sdt-devel "
      "or configure with -DETNP_ENABLE_USDT=OFF.")
  endif()
endif()

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
    # TODO(op#2): reset ETNP_EXTRAS_EXPECT_TUS to "" before this add_subdirectory so a
    # future op that forgets its PARENT_SCOPE set can't inherit the prior op's TUs; and
    # generalize the test wiring below (currently the lstm-specific `if(TARGET
    # etnp_ops_lstm)` block) + the "test/ dir exists" check into per-op handling.
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

# Turn the probe macros on in each op archive (header is also __linux__-gated).
if(ETNP_USDT_EFFECTIVE)
  foreach(_lib IN LISTS ETNP_EXTRAS_LIBS)
    target_compile_definitions(${_lib} PRIVATE ETNP_USDT_ENABLED=1)
  endforeach()
endif()

# --- per-op tests (built against the extras libs, whole-archived) ---
if(TARGET etnp_ops_lstm)
  add_executable(lstm_kernel_test lstm/test/lstm_kernel_test.cpp)
  target_link_libraries(lstm_kernel_test PRIVATE
    ${_ET_LINK} "$<LINK_LIBRARY:WHOLE_ARCHIVE,etnp_ops_lstm>")
endif()

# --- static registration guard (every build, incl. cross-compiled targets) ---
add_executable(etnp_extras_link_probe link_probe.cpp)
set(_probe_whole "")
foreach(_lib IN LISTS ETNP_EXTRAS_LIBS)
  list(APPEND _probe_whole "$<LINK_LIBRARY:WHOLE_ARCHIVE,${_lib}>")
endforeach()
target_link_libraries(etnp_extras_link_probe PRIVATE ${_ET_LINK} ${_probe_whole})
add_custom_command(TARGET etnp_extras_link_probe POST_BUILD
  COMMAND ${CMAKE_COMMAND} -DSO=$<TARGET_FILE:etnp_extras_link_probe> -DNM=nm
          "-DEXPECT_TUS=${ETNP_EXTRAS_ALL_EXPECT_TUS}"
          -P ${CMAKE_CURRENT_LIST_DIR}/../cmake/assert_extras_registered.cmake
  VERBATIM)

# USDT note guard: prove the probe notes survived the whole-archive link (or are
# absent when disabled) and that the committed provider/probe/arity contract holds.
# readelf is in binutils (as nm is for the registrar guard above).
add_custom_command(TARGET etnp_extras_link_probe POST_BUILD
  COMMAND bash "${CMAKE_CURRENT_LIST_DIR}/../scripts/check-usdt-notes.sh"
          --expect ${ETNP_USDT_EXPECT_WORD} $<TARGET_FILE:etnp_extras_link_probe>
  VERBATIM)

# --- negative-control probe (Task 4 Step 5 only) ---
# SAME ET deps as the real probe, but the extras archives are linked PLAIN (no
# whole-archive), so this is a VALID, fully-resolved binary in which the linker
# legitimately omits the unreferenced registrar TU. It exists to prove the guard
# fails for the RIGHT reason (dropped registrar in a valid binary) — NOT because of
# an unresolved-symbol link error like a bare `.a`-only link would give.
# EXCLUDE_FROM_ALL: normal builds never build it; no POST_BUILD guard attached.
add_executable(etnp_extras_neg_probe EXCLUDE_FROM_ALL link_probe.cpp)
target_link_libraries(etnp_extras_neg_probe PRIVATE ${_ET_LINK} ${ETNP_EXTRAS_LIBS})
target_link_options(etnp_extras_neg_probe PRIVATE -Wl,--gc-sections)

# Render ETNPExtras.cmake with the concrete whole-archive lib list and install it.
string(REPLACE ";" " " ETNP_EXTRAS_INSTALL_LIBS "${ETNP_EXTRAS_LIBS}")
configure_file("${CMAKE_CURRENT_LIST_DIR}/cmake/ETNPExtras.cmake.in"
               "${CMAKE_BINARY_DIR}/ETNPExtras.cmake" @ONLY)
install(FILES "${CMAKE_BINARY_DIR}/ETNPExtras.cmake"
        DESTINATION lib/cmake/ETNPExtras)
