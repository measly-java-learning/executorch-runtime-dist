# Builds ov_runner the way a downstream consumer links the shipped tarball: find_package on the
# installed prefix, then the backend aggregate.
cmake_minimum_required(VERSION 3.24)
project(etnp_ov_runner LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(executorch CONFIG REQUIRED)

add_executable(ov_runner ov_runner.cpp)
# executorch_backends is the upstream aggregate; on linux-x86_64 it carries openvino_backend with
# --whole-archive, which is what gets the delegate's static registrar linked in. Without it the
# .pte loads no OpenvinoBackend and the gate would fail for the wrong reason.
if(TARGET optimized_native_cpu_ops_lib)
  set(OV_RUNNER_KERNELS optimized_native_cpu_ops_lib)
else()
  set(OV_RUNNER_KERNELS portable_ops_lib)
endif()
target_link_libraries(ov_runner PRIVATE
  executorch executorch_backends ${OV_RUNNER_KERNELS}
  extension_module_static extension_data_loader extension_tensor)
