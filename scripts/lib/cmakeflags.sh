#!/usr/bin/env bash
# Common (variant-independent) cmake flags — SINGLE SOURCE OF TRUTH shared by the build
# (build-runtime.sh) and the recorded provenance (package.sh -> BUILDINFO cmake_flags, C5), so the
# two can never drift. Excludes only genuinely machine-specific flags (-DCMAKE_INSTALL_PREFIX), which
# the build sets separately and which are deliberately not recorded. Source me.
common_cmake_flags() {
  printf -- '-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON'
}

# Collapse repeated whitespace-separated tokens, keeping the FIRST occurrence and preserving order.
# Most flags are self-contained `-DKEY=VALUE` tokens, so dedup is safe for them. However,
# `--preset linux` (from et_configure_base) is TWO separate tokens; they survive dedup intact only
# because no current flag set includes a bare word matching `--preset` or `linux`. If a future flag
# value ever collides with either, dedup would drop a copy and split `--preset` from its argument,
# corrupting the configure base. Two flags sharing a KEY but differing in VALUE are distinct tokens
# and are both retained (cmake's last-wins behaviour is unchanged).
# `for f in $1` is an unquoted word-split on purpose (to iterate tokens) but that also activates
# pathname expansion: no current flag contains a glob metacharacter, but a future one (e.g. a path
# with `*`) would silently expand against the cwd and corrupt the flag set. Disable globbing for the
# loop and restore whatever state the caller had.
_dedupe_flags() { # <flag string>
  local out="" f
  local _had_noglob=0
  case "$-" in *f*) _had_noglob=1 ;; esac
  set -f
  for f in $1; do
    case " $out " in *" $f "*) ;; *) out="${out:+$out }$f" ;; esac
  done
  [ "$_had_noglob" -eq 1 ] || set +f
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
