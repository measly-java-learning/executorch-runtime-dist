#!/usr/bin/env bash
# Variant -> cmake flag string (contract C3). Single source of truth. Source me.
variant_flags() { # <bare|logging|devtools>
  case "$1" in
    bare)     printf -- '-DEXECUTORCH_ENABLE_LOGGING=OFF' ;;
    logging)  printf -- '-DEXECUTORCH_ENABLE_LOGGING=ON' ;;
    devtools) printf -- '-DEXECUTORCH_ENABLE_LOGGING=OFF -DEXECUTORCH_BUILD_DEVTOOLS=ON -DEXECUTORCH_ENABLE_EVENT_TRACER=ON' ;;
    *) echo "unknown variant: $1" >&2; return 2 ;;
  esac
}
