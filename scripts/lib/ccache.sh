#!/usr/bin/env bash
# ccache: pinned build-tool binary (version + hash). SINGLE SOURCE OF TRUTH.
# Sourced by scripts/install-ccache.sh and the hermetic tests. Source me.
#
# Fetched from the upstream GitHub release rather than `dnf install ccache`, which provides 3.7.7 -
# six majors behind. 4.x is required here for `--print-stats`, a tab-separated machine-readable
# counter dump; 3.x offers only prose output that changes between releases.
#
# Verified to run on manylinux_2_28 (AlmaLinux 8.10, glibc 2.28). The `-glibc` build suffices; a
# `musl-static` asset exists as a fallback if a future base image drifts below that floor.
#
# .tar.gz, not .tar.xz: gzip is universally present, which drops a dependency on `xz` surviving a
# base-image change. The .xz asset is ~450KB smaller and not worth the coupling.
#
# LICENSING: ccache is GPL-3.0. It is a BUILD TOOL - it never links into, and is never shipped
# inside, any published artifact - so it carries NO notice obligation and must NOT be added to
# THIRD-PARTY-NOTICES/. This differs from Google Highway, which ships as libhwy.a and therefore
# does. Recorded here so the distinction is not re-litigated.
#
# NOTE: this file is inside the ccache key's hashFiles() set, so bumping the version correctly
# invalidates every cache (cache formats can change between versions). That costs one full-price
# run per job - expected, not a bug.
CCACHE_VERSION="4.13.6"
CCACHE_ARCHIVE="ccache-${CCACHE_VERSION}-linux-x86_64-glibc.tar.gz"
CCACHE_URL="https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/${CCACHE_ARCHIVE}"
CCACHE_MEMBER="ccache-${CCACHE_VERSION}-linux-x86_64-glibc/ccache"
# sha256 of CCACHE_ARCHIVE (1754958 bytes), verified against the size GitHub's release API reports.
# Upstream signs releases with minisign (.minisig), NOT GitHub build attestations, so
# `gh attestation verify` does not apply - and `gh` is absent from the manylinux containers anyway.
# Pinning the hash ourselves asserts the exact bytes we tested and needs no extra tooling.
CCACHE_SHA256="567b1b648411819590f918f045218c92da14418bdec3b30db94a3b4f5d77cf13"
