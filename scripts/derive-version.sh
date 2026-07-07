#!/usr/bin/env bash
# Derive pkgver/etver/ettag from a release tag (v<etver>-<pkgrev>, e.g. v1.3.1-1).
# Reads GITHUB_REF_NAME; prints key=value lines (both $GITHUB_OUTPUT-appendable and eval-able).
set -euo pipefail
tag="${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
pkgver="${tag#v}"
etver="${pkgver%-*}"
printf 'pkgver=%s\netver=%s\nettag=v%s\n' "$pkgver" "$etver" "$etver"
