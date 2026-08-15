# Builds workspace_probe the way a downstream consumer links the shipped tarball.
cmake_minimum_required(VERSION 3.24)
project(etnp_workspace_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(executorch CONFIG REQUIRED)

add_executable(workspace_probe workspace_probe.cpp)
# executorch_backends carries xnnpack_backend with --whole-archive, which is what registers the
# delegate. Without it the .pte loads no XnnpackBackend and the workspace never allocates.
target_link_libraries(workspace_probe PRIVATE
  executorch executorch_backends optimized_native_cpu_ops_lib
  extension_module_static extension_data_loader extension_tensor)
