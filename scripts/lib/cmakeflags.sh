#!/usr/bin/env bash
# Common (variant-independent) cmake flags — SINGLE SOURCE OF TRUTH shared by the build
# (build-runtime.sh) and the recorded provenance (package.sh -> BUILDINFO cmake_flags, C5), so the
# two can never drift. Excludes only genuinely machine-specific flags (-DCMAKE_INSTALL_PREFIX), which
# the build sets separately and which are deliberately not recorded. Source me.
common_cmake_flags() {
  printf -- '-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON'
}

# Collapse repeated whitespace-separated tokens, keeping the FIRST occurrence and preserving order.
# Safe here because every flag is a self-contained `-DKEY=VALUE` token and the overlapping flags
# carry identical values. Two flags sharing a KEY but differing in VALUE are distinct tokens and are
# both retained (cmake's last-wins behaviour is unchanged).
_dedupe_flags() { # <flag string>
  local out="" f
  for f in $1; do
    case " $out " in *" $f "*) ;; *) out="${out:+$out }$f" ;; esac
  done
  printf '%s' "$out"
}

# The full, deduped flag set actually handed to cmake — and recorded as provenance, and printed by
# --print-flags. One composer, three consumers, so the build, the dry run, and BUILDINFO can never
# disagree (extends contract C5). Requires configure-base.sh + variants.sh to be sourced.
effective_cmake_flags() { # <platform> <variant>
  local base variant
  base="$(et_configure_base "$1")" || return 2
  variant="$(variant_flags "$2")" || return 2
  _dedupe_flags "$base $variant $(common_cmake_flags)"
}
