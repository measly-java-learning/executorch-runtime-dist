# Post-link guard: prove each manifested op's registrar static-init TU survived
# --gc-sections/whole-archive at the final link. A dropped registrar is invisible
# until "operator not found" at model-load time. Generalized from the shim's
# assert_kernels_registered.cmake: one registrar TU per manifested op, no dups.
# Invoke: cmake -DSO=<bin> -DNM=<nm> -DEXPECT_TUS="<;-list>" -P this
if(NOT SO OR NOT EXISTS "${SO}")
  message(FATAL_ERROR "assert_extras_registered: SO not found: '${SO}'")
endif()
if(NOT NM)
  set(NM "nm")
endif()
execute_process(COMMAND "${NM}" "${SO}" OUTPUT_VARIABLE _syms
                RESULT_VARIABLE _rc ERROR_VARIABLE _err)
if(NOT _rc EQUAL 0)
  message(FATAL_ERROR "assert_extras_registered: '${NM} ${SO}' failed (rc=${_rc}): ${_err}")
endif()
foreach(_tu IN LISTS EXPECT_TUS)
  # Strip first: a whitespace-only entry (e.g. a mis-scoped/blank op variable that
  # expands to spaces) would otherwise become a regex that trivially matches the
  # spacing in nm output -> a silent false PASS that defeats the guard's purpose.
  string(STRIP "${_tu}" _tu)
  if(_tu STREQUAL "")
    continue()
  endif()
  string(REGEX REPLACE "\\." "\\\\." _tu_re "${_tu}")
  string(REGEX MATCHALL "${_tu_re}" _m "${_syms}")
  list(LENGTH _m _cnt)
  if(_cnt LESS 1)
    message(FATAL_ERROR
      "extras registrar '${_tu}' was dropped from ${SO}: static-init TU absent. "
      "whole-archive regressed -> custom op not found at model-load time.")
  endif()
endforeach()
message(STATUS "assert_extras_registered: all extras registrar TUs present in ${SO}: [${EXPECT_TUS}]")
