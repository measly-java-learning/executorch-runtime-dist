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
ov_lib_members() {
  cat <<EOF
libopenvino_c.so.${OV_ABI}
libopenvino.so.${OV_ABI}
libopenvino_intel_cpu_plugin.so
libopenvino_ir_frontend.so.${OV_ABI}
libtbb.so.12
libtbbbind_2_5.so.3
libhwloc.so.15
EOF
}

# hwloc-COPYING is fetched separately (see above); the other four are declared License-Files in
# the wheel and are copied straight out of its dist-info.
ov_license_members() {
  cat <<'EOF'
LICENSE
runtime-third-party-programs.txt
onetbb_third-party-programs.txt
onednn_third-party-programs.txt
hwloc-COPYING
EOF
}

ov_asset_stem() { # <platform>
  [ $# -ge 1 ] && [ -n "${1:-}" ] || { echo "ov_asset_stem: platform required" >&2; return 2; }
  printf 'openvino-runtime-%s-%s' "$OV_VERSION" "$1"
}
ov_tarball_name() { printf '%s.tar.gz' "$(ov_asset_stem "$@")"; }
ov_sha_name()     { printf '%s.sha256' "$(ov_tarball_name "$@")"; }

# Fixture asset carries BOTH versions: the .pte embeds a precompiled OpenVINO blob (the AOT side
# calls compiled.export_model(); the runtime calls ov_core_import_model), so it is coupled to the
# OpenVINO version as well as the ET version. etnp-lstm-fixtures needs only <etver>.
ov_fixtures_name() { # <etver>
  [ $# -ge 1 ] && [ -n "${1:-}" ] || { echo "ov_fixtures_name: etver required" >&2; return 2; }
  printf 'etnp-openvino-fixtures-%s-%s.tar.gz' "$1" "$OV_VERSION"
}
