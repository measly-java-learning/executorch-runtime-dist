# Drives a generated EtRuntimePin.cmake's OpenVINO selector through real cmake, so the function is
# proven to RUN. Sibling of selector_probe.cmake; the difference is that absence is legal here --
# a platform with no bundle must yield empty strings rather than a fatal error.
#   cmake -DPIN=<pin> -DP=<platform> -P openvino_selector_probe.cmake
cmake_minimum_required(VERSION 3.19)

include("${PIN}")
et_runtime_openvino_url("${P}" url sha)

# When a row exists the selector must agree with the flat vars it reads from; a divergence would
# hand consumers a URL and a hash describing different tarballs, which FetchContent reports as a
# hash mismatch far from the cause.
if(DEFINED ET_RUNTIME_OPENVINO_URL_${P})
  if(NOT url STREQUAL "${ET_RUNTIME_OPENVINO_URL_${P}}")
    message(FATAL_ERROR "openvino selector url disagrees with flat var for ${P}")
  endif()
  if(NOT sha STREQUAL "${ET_RUNTIME_OPENVINO_SHA256_${P}}")
    message(FATAL_ERROR "openvino selector sha disagrees with flat var for ${P}")
  endif()
elseif(NOT url STREQUAL "")
  message(FATAL_ERROR "openvino selector invented a url for ${P}, which has no row")
endif()

message("URL=${url}")
message("SHA=${sha}")
