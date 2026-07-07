# Prep release.yml for multi-platform releases

**Date**: 2026-07-07
**Status**: Approved

## Goal

Prepare `.github/workflows/release.yml` to add `linux-aarch64` as a second
release platform later, without another structural rewrite at that time.
This change adds no new platform — it only removes the places where
`linux-x86_64` is hardcoded or duplicated, so a future platform addition is
a one-line edit.

## Current state

- `build` job already matrixes on `variant × platform`, with
  `platform: [linux-x86_64]` inline in the matrix.
- `release` job hardcodes `linux-x86_64` twice: once in the sha256 filename
  it reads (`executorch-runtime-${etver}-${variant}-linux-x86_64.tar.gz.sha256`)
  and once in the `gen-pin.sh --row` argument. It also does the pin-file
  generation and the `gh release create` in the same job.

## Design

### Single source of truth for platforms

Add a top-level `env.PLATFORMS` JSON array:

```yaml
env:
  PLATFORMS: '["linux-x86_64"]'
```

Consumed two ways:
- `build` job matrix: `platform: ${{ fromJSON(env.PLATFORMS) }}`
- `pin` job's shell loop: `for platform in $(echo '${{ env.PLATFORMS }}' | jq -r '.[]'); do ...`

Adding `linux-aarch64` later means editing this one array; both jobs pick it
up without further changes.

### Job split: build → pin → release

The current `release` job mixes two concerns (generating the version pin
file, and publishing the GitHub release) and hardcodes the platform in the
process. Splitting it avoids a matrixed `release` job racing on
`gh release create` while still removing the hardcoded platform:

1. **`build`** (unchanged behavior, matrix already correct)
   - matrix: `variant: [bare, logging, devtools]`, `platform: ${{ fromJSON(env.PLATFORMS) }}`
   - builds + packages + attests + uploads `dist-${variant}-${platform}` artifact

2. **`pin`** (new, non-matrix, `needs: build`)
   - downloads all `dist-*` artifacts merged into `dist/`
   - re-derives `pkgver`/`etver` from the tag (same one-liner as `build`)
   - loops `platform` (from `env.PLATFORMS` via `jq`) × `variant` (literal list,
     unchanged), reads each `dist/executorch-runtime-${etver}-${variant}-${platform}.tar.gz.sha256`,
     and appends `--row "$variant" "$platform" "$sha"`
   - runs `gen-pin.sh`, writes `dist/EtRuntimePin.cmake`, appends it to
     `$GITHUB_STEP_SUMMARY` (unchanged)
   - uploads `dist/EtRuntimePin.cmake` as its own artifact (`name: pin`)

3. **`release`** (needs: `pin`, non-matrix)
   - downloads all artifacts (`dist-*` + `pin`) merged into `dist/`
   - single `gh release create ... || gh release upload ... --clobber` step,
     unchanged from today

### Out of scope

- Adding `linux-aarch64` itself, or any cross-compilation/runner changes
  needed to build it. This is a pure prep/refactor step.
- Changing the container image, toolchain, or build steps.
