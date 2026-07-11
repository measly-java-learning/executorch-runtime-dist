# Builds the LSTM op into libetnp_ops_lstm.a: a pure static-initializer
# registration archive, like libxnnpack_backend.a. Consumers MUST whole-archive
# it (see the installed ETNPExtras.cmake helper). Include AFTER find_package(ExecuTorch).
#
# XNNPACK (headers + libs) comes from the installed ExecuTorch prefix. Highway is
# hash-pinned/fetched (ET does not vendor it). Sets ETNP_EXTRAS_EXPECT_TUS in the
# parent scope for the nm-guard.

# --- generate the op-name header from extra.yaml (single source of truth) ---
# BUILD-time generation (not execute_process at configure time): DEPENDS on BOTH
# the YAML and the generator script, so editing either regenerates the header on the
# next `cmake --build`. execute_process would only re-run on reconfigure, letting a
# local iterative build compile against a header out of sync with extra.yaml.
set(_extra_yaml "${CMAKE_CURRENT_LIST_DIR}/../extra.yaml")
set(_gen_script "${CMAKE_CURRENT_LIST_DIR}/../../generate_schema_header.py")
set(_gen_header "${CMAKE_CURRENT_BINARY_DIR}/gen/etnp_lstm_schema.h")
find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_custom_command(
  OUTPUT "${_gen_header}"
  COMMAND "${Python3_EXECUTABLE}" "${_gen_script}" "${_extra_yaml}" "${_gen_header}"
  DEPENDS "${_extra_yaml}" "${_gen_script}"
  COMMENT "Generating etnp_lstm_schema.h from extra.yaml (single source of truth)"
  VERBATIM)

# Listing the generated header as a target source wires the custom command's OUTPUT
# into the target's dependency graph, so it regenerates before etnp_lstm.cpp (which
# #includes it) compiles — correct under Ninja parallel builds too.
add_library(etnp_ops_lstm STATIC
  "${CMAKE_CURRENT_LIST_DIR}/etnp_lstm.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/lstm_cell.cc"
  "${_gen_header}")
set_property(TARGET etnp_ops_lstm PROPERTY POSITION_INDEPENDENT_CODE ON)
target_compile_features(etnp_ops_lstm PRIVATE cxx_std_17)

# Own dir (sibling headers by bare name + Highway foreach_target re-include of
# lstm_cell.cc) and the generated-header dir.
target_include_directories(etnp_ops_lstm PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/gen")

# executorch: kernel-registration + core headers. extension_threadpool: the
# batched input projection uses the shared runtime pool. XNNPACK + pthreadpool:
# imported from the ExecuTorch prefix (find_package brought them in).
target_link_libraries(etnp_ops_lstm PUBLIC executorch extension_threadpool)
target_link_libraries(etnp_ops_lstm PRIVATE XNNPACK pthreadpool)

# --- Highway 1.4.0, hash-pinned (SHA change = supply-chain review gate) ---
set(HWY_ENABLE_CONTRIB OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
include(FetchContent)
FetchContent_Declare(highway
  URL "https://github.com/google/highway/archive/refs/tags/1.4.0.tar.gz"
  URL_HASH "SHA256=e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c")
FetchContent_MakeAvailable(highway)
target_link_libraries(etnp_ops_lstm PRIVATE hwy)

# Registrar TU the nm-guard must find post whole-archive link. etnp_lstm.cpp
# registers (register_kernel); lstm_cell.cc is an aux SIMD source (no registrar).
set(ETNP_EXTRAS_EXPECT_TUS "_GLOBAL__sub_I_etnp_lstm.cpp" PARENT_SCOPE)
