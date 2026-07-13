# The runner links the INSTALLED extras exactly as a downstream consumer would:
# find_package(executorch) + include the shipped ETNPExtras.cmake + call the helper.
cmake_minimum_required(VERSION 3.24)
project(etnp_lstm_runner LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(executorch CONFIG REQUIRED)
include("${ETNP_PREFIX}/lib/cmake/ETNPExtras/ETNPExtras.cmake")

add_executable(lstm_runner lstm_runner.cpp)
target_link_libraries(lstm_runner PRIVATE
  executorch optimized_native_cpu_ops_lib xnnpack_backend
  extension_module_static extension_data_loader extension_tensor)
etnp_extras_whole_archive(lstm_runner)   # shipped helper wraps etnp_ops_lstm
