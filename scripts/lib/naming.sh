#!/usr/bin/env bash
# Asset naming (contract C1). Single source of truth. Source me.
asset_stem()   { printf 'executorch-runtime-%s-%s-%s' "$1" "$2" "$3"; }      # <etver> <variant> <platform>
tarball_name() { printf '%s.tar.gz' "$(asset_stem "$@")"; }
sha_name()     { printf '%s.sha256' "$(tarball_name "$@")"; }
