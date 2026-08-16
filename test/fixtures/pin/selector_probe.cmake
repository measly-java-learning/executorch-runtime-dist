# Drives a generated EtRuntimePin.cmake through real cmake, so the pin's selector is proven to
# *run*, not merely to appear in the generated text. Invoked as:
#   cmake -DPIN=<pin> -DV=<variant> -DP=<platform> -P selector_probe.cmake
# Prints the resolved pair on stdout; a combination with no row aborts inside the pin itself.
cmake_minimum_required(VERSION 3.19)

include("${PIN}")
et_runtime_dist_url("${V}" "${P}" url sha)

# The selector must agree with the flat vars it reads from -- a divergence would hand consumers a
# URL and a hash that describe different tarballs, which FetchContent reports as a hash mismatch
# far away from the cause.
if(NOT url STREQUAL "${ET_RUNTIME_URL_${V}_${P}}")
  message(FATAL_ERROR "selector url disagrees with flat var for ${V}/${P}")
endif()
if(NOT sha STREQUAL "${ET_RUNTIME_SHA256_${V}_${P}}")
  message(FATAL_ERROR "selector sha disagrees with flat var for ${V}/${P}")
endif()

message("URL=${url}")
message("SHA=${sha}")
