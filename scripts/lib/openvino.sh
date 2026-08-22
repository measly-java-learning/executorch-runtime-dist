#!/usr/bin/env bash
# OpenVINO runtime bundle: pinned version + members + asset naming (contract C10).
# SINGLE SOURCE OF TRUTH — sourced by scripts/vendor-openvino.sh (assembly), scripts/gen-pin.sh
# (pin rows), the bundle/smoke tests, and CI. Never re-derive any of these at a call site.
#
# We vendor from the PyPI wheel, not Intel's toolkit archive, for two reasons:
#   1. LICENSING. The archive's runtime/lib/* is under the Intel OpenVINO Distribution License
#      (its docs/licensing/readme.txt says only headers/samples/python are Apache 2.0), and its
#      redist.txt does not list Linux TBB. The wheel is Apache 2.0 end to end.
#   2. RELOCATABILITY. The wheel's libs already carry RPATH=$ORIGIN, so a flat directory
#      self-resolves with no LD_LIBRARY_PATH and no patchelf (i.e. no binary modification).
# Source me.

OV_VERSION="2025.4.1"
# soname suffix: libopenvino.so.<OV_ABI>. Derived from OV_VERSION by upstream (2025.4.1 -> 2541)
# but NOT computable from it in general, so it is pinned explicitly and asserted in tests.
OV_ABI="2541"
OV_WHEEL_PYTAG="cp312"
OV_WHEEL_SHA256="88f074286d420c1a1a95e7f2ba11109a899f2f3b3fd818cfe1e47ead22cc7e45"
# The win_amd64 wheel of the SAME OV_VERSION and OV_WHEEL_PYTAG, so the two platforms can never
# skew. 41,791,284 bytes; verified against PyPI.
OV_WHEEL_SHA256_WIN="c50293d1463698012eaa526dcc83f841b85a3f4952eea4c9445c83e0346f8e80"

# AOT-only, and deliberately here rather than in a requirements file: NNCF is part of the OpenVINO
# family and its wheel must be resolvable alongside the OV_VERSION above. requirements/openvino-*.txt
# are GENERATED from these two by scripts/gen-requirements.sh, so the wheel a fixture is exported
# with can never drift from the bundle the gate runs it against.
OV_NNCF_VERSION="3.1.0"

# hwloc is BSD-3-Clause and is NOT attributed anywhere in the wheel's license material (verified:
# zero matches for "hwloc"/"Portable Hardware Locality" across LICENSE and all three
# *-third-party-programs.txt). Shipping libhwloc.so.15 therefore requires fetching its notice
# ourselves — same hard-gate treatment as Google Highway in build_extras. The release string is
# stripped from the binary; 2.8.0 was determined by calling hwloc_get_api_version() (0x020800).
OV_HWLOC_VERSION="2.8.0"
OV_HWLOC_LICENSE_URL="https://raw.githubusercontent.com/open-mpi/hwloc/hwloc-${OV_HWLOC_VERSION}/COPYING"

# CPU-only runtime set. Excludes the GPU/NPU plugins and the ONNX/TF/PyTorch/Paddle/JAX frontends:
# those parse third-party MODEL FORMATS, which we never do.
#
# libopenvino_ir_frontend IS REQUIRED and must not be pruned with the other frontends. The blob the
# AOT side produces (compiled.export_model()) embeds the model in OpenVINO's own IR form, so
# ov_core_import_model needs the IR frontend to deserialize it. Without it EVERY delegated .pte
# fails at model load with `failed to import model for device 'CPU' (status=-1)` — while device
# enumeration still succeeds, which is why this is invisible to a plugin-loading check and must be
# caught by the blob-import stage of test/openvino_smoke.sh.
#
# libtbbbind/libhwloc are included because libtbb dlopens tbbbind BY NAME (it is not a NEEDED
# entry), which pulls hwloc via its own NEEDED + $ORIGIN — verified under LD_DEBUG=libs. Omitting
# them is safe (TBB degrades gracefully) but loses NUMA-aware binding.
# Windows ships the same CPU runtime set MINUS hwloc: there is no separate hwloc DLL because it is
# folded into tbbbind_2_5.dll. The DLLs are unversioned, so OV_ABI does not appear here.
# tbbbind_2_5.dll IS kept: the prediction was that TBB's bare-name load would miss it in a flat
# bundle and silently lose NUMA binding, but it resolves -- verified by module enumeration in
# issue #37, comment 5372679998.
ov_lib_members() { # <platform>
  case "${1:-}" in
    linux-x86_64)
      cat <<EOF
libopenvino_c.so.${OV_ABI}
libopenvino.so.${OV_ABI}
libopenvino_intel_cpu_plugin.so
libopenvino_ir_frontend.so.${OV_ABI}
libtbb.so.12
libtbbbind_2_5.so.3
libhwloc.so.15
EOF
      ;;
    windows-x86_64|windows-x86_64-static)
      cat <<'EOF'
openvino_c.dll
openvino.dll
openvino_intel_cpu_plugin.dll
openvino_ir_frontend.dll
tbb12.dll
tbbbind_2_5.dll
EOF
      ;;
    *) echo "ov_lib_members: no member list for platform '${1:-}'" >&2; return 2 ;;
  esac
}

ov_license_members() { # <platform>
  case "${1:-}" in
    linux-x86_64)
      cat <<'EOF'
LICENSE
runtime-third-party-programs.txt
onetbb_third-party-programs.txt
onednn_third-party-programs.txt
hwloc-COPYING
EOF
      ;;
    windows-x86_64|windows-x86_64-static)
      cat <<'EOF'
LICENSE
runtime-third-party-programs.txt
onetbb_third-party-programs.txt
onednn_third-party-programs.txt
EOF
      ;;
    *) echo "ov_license_members: no licence list for platform '${1:-}'" >&2; return 2 ;;
  esac
}

# The wheel pin and its pip platform tag, per platform. Kept beside the member lists: the three
# are read together, and a platform added to one but not the others fails at vendoring rather
# than shipping a mismatched bundle.
ov_wheel_sha256() { # <platform>
  case "${1:-}" in
    linux-x86_64) printf '%s' "$OV_WHEEL_SHA256" ;;
    windows-x86_64|windows-x86_64-static) printf '%s' "$OV_WHEEL_SHA256_WIN" ;;
    *) echo "ov_wheel_sha256: no wheel pinned for platform '${1:-}'" >&2; return 2 ;;
  esac
}

ov_wheel_platform_tag() { # <platform>
  case "${1:-}" in
    linux-x86_64) printf 'manylinux2014_x86_64' ;;
    windows-x86_64|windows-x86_64-static) printf 'win_amd64' ;;
    *) echo "ov_wheel_platform_tag: no wheel tag for platform '${1:-}'" >&2; return 2 ;;
  esac
}

# THE predicate for "does this platform's bundle carry hwloc, and therefore need its notice
# fetched out of band?" One mapping, so vendor-openvino.sh's licence gate cannot disagree with
# ov_license_members about whether hwloc-COPYING is expected.
ov_uses_hwloc() { # <platform> -> 0 (yes) / 1 (no)
  case "${1:-}" in
    linux-x86_64) return 0 ;;
    *) return 1 ;;
  esac
}

# Does this platform's bundle need the unversioned compatibility symlink?
ov_needs_soname_symlink() { # <platform> -> 0 (yes) / 1 (no)
  case "${1:-}" in
    linux-x86_64) return 0 ;;
    *) return 1 ;;
  esac
}

# THE platform -> "is the OpenVINO delegate compiled in?" predicate. One mapping, consumed by
# cmakeflags.sh (which sets EXECUTORCH_BUILD_OPENVINO) and package.sh (which records
# openvino_version in BUILDINFO and asserts the archive is actually present). Encoding this in two
# places is exactly the drift CLAUDE.md warns about: an enablement that updated only one would ship
# a tarball whose BUILDINFO lies about its contents. Windows is enabled here as of the OpenVINO
# Windows port (issue #37): the delegate compiles and ships, but the win_amd64 RUNTIME BUNDLE does
# not exist yet, so a Windows consumer must point OPENVINO_LIB_PATH at their own openvino_c.dll.
ov_enabled_for_platform() { # <platform> -> 0 (enabled) / 1 (not)
  case "${1:-}" in
    linux-x86_64|windows-x86_64|windows-x86_64-static) return 0 ;;
    *) return 1 ;;
  esac
}

# Platform -> the platform whose BUNDLE serves it. Usually identity, but both Windows CRT
# platforms share one bundle: the wheel's DLLs are /MD regardless of how a consumer links, and no
# CRT object crosses the boundary, so a second asset differing only in BUILDINFO would be waste.
# Exit 2 rather than defaulting: an OpenVINO-enabled platform with no bundle must fail here, not
# publish a pin row pointing at another platform's runtime.
ov_bundle_platform() { # <platform>
  case "${1:-}" in
    linux-x86_64)                          printf 'linux-x86_64' ;;
    windows-x86_64|windows-x86_64-static)  printf 'windows-x86_64' ;;
    *) echo "ov_bundle_platform: no OpenVINO bundle serves platform '${1:-}'" >&2; return 2 ;;
  esac
}

# The distinct bundles a release builds. Derived from nothing -- it is the authoritative list, and
# ov_bundle_platform's targets must all appear here (asserted in test/lib_openvino.test.sh).
ov_bundle_platforms() {
  cat <<'EOF'
linux-x86_64
windows-x86_64
EOF
}

# Platforms served by ANOTHER platform's bundle. gen-pin.sh emits an alias row for each so a
# consumer building that row resolves a runtime without knowing about the sharing. Kept distinct
# from ov_bundle_platforms: their union must cover every OpenVINO-enabled platform, and the two
# lists must not overlap (both asserted in test/lib_openvino.test.sh).
ov_alias_platforms() {
  cat <<'EOF'
windows-x86_64-static
EOF
}

# Platform -> the delegate archive the build produces. MSVC does not use the lib*.a convention, so
# package.sh's existence assertion cannot hardcode one spelling. Kept beside the predicate above
# deliberately: the two are read together, and a platform added to one without the other produces a
# release that fails at packaging rather than at configure.
ov_backend_archive_name() { # <platform>
  case "${1:-}" in
    windows-*) printf 'openvino_backend.lib' ;;
    *)         printf 'libopenvino_backend.a' ;;
  esac
}

ov_asset_stem() { # <platform>
  [ $# -ge 1 ] && [ -n "${1:-}" ] || { echo "ov_asset_stem: platform required" >&2; return 2; }
  printf 'openvino-runtime-%s-%s' "$OV_VERSION" "$1"
}
# Capture into a local and propagate the failure: `printf "%s.tar.gz" "$(ov_asset_stem "$@")"`
# DISCARDS the command-substitution status, so a missing/empty platform would return 0 with the
# nonsense name ".tar.gz" — which gen-pin.sh would then emit as a real-looking pin URL.
ov_tarball_name() { # <platform>
  local _stem; _stem="$(ov_asset_stem "$@")" || return 2
  printf '%s.tar.gz' "$_stem"
}
ov_sha_name() { # <platform>
  local _tb; _tb="$(ov_tarball_name "$@")" || return 2
  printf '%s.sha256' "$_tb"
}

# Fixture asset carries BOTH versions: the .pte embeds a precompiled OpenVINO blob (the AOT side
# calls compiled.export_model(); the runtime calls ov_core_import_model), so it is coupled to the
# OpenVINO version as well as the ET version. etnp-lstm-fixtures needs only <etver>.
ov_fixtures_name() { # <etver>
  [ $# -ge 1 ] && [ -n "${1:-}" ] || { echo "ov_fixtures_name: etver required" >&2; return 2; }
  printf 'etnp-openvino-fixtures-%s-%s.tar.gz' "$1" "$OV_VERSION"
}
