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
  `platform: [linux-x86_64]` inline in the matrix. The container image
  (`quay.io/pypa/manylinux_2_28_x86_64`) is separately hardcoded at the job
  level — `manylinux` bakes the architecture into the image name/tag, so
  this must vary with platform too. `runs-on` (`ubuntu-latest`) is also
  hardcoded; a future aarch64 runner may need a different value (e.g. an
  arm64 runner label), so it's included in the same per-platform record now
  even though every platform uses `ubuntu-latest` today.
- `release` job hardcodes `linux-x86_64` twice: once in the sha256 filename
  it reads (`executorch-runtime-${etver}-${variant}-linux-x86_64.tar.gz.sha256`)
  and once in the `gen-pin.sh --row` argument. It also does the pin-file
  generation and the `gh release create` in the same job.

## Design

### Single source of truth for platforms

Add a top-level `env.PLATFORMS` JSON array of objects, one per platform,
carrying everything that varies by platform today or is expected to vary
once aarch64 is added:

```yaml
env:
  PLATFORMS: >-
    [{"platform":"linux-x86_64","container":"quay.io/pypa/manylinux_2_28_x86_64","runs_on":"ubuntu-latest"}]
```

Consumed two ways:

- `build` job: cross `variant` with a `combo` matrix axis built from
  `PLATFORMS`, then reference the fields off `matrix.combo`:

  ```yaml
  strategy:
    matrix:
      variant: [bare, logging, devtools]
      combo: ${{ fromJSON(env.PLATFORMS) }}
  runs-on: ${{ matrix.combo.runs_on }}
  container:
    image: ${{ matrix.combo.container }}
  ```

  (`matrix.combo.platform` replaces today's `matrix.platform` references in
  the build/package steps and artifact name.)

- `pin` job's shell loop extracts just the platform names:
  `for platform in $(echo '${{ env.PLATFORMS }}' | jq -r '.[].platform'); do ...`

Adding `linux-aarch64` later means appending one object to this array; no
job-level YAML structure changes are needed at that time.

### Job split: build → pin → release

The current `release` job mixes two concerns (generating the version pin
file, and publishing the GitHub release) and hardcodes the platform in the
process. Splitting it avoids a matrixed `release` job racing on
`gh release create` while still removing the hardcoded platform:

1. **`build`** (behavior unchanged; matrix wiring updated per above)
   - matrix: `variant: [bare, logging, devtools]`, `combo: ${{ fromJSON(env.PLATFORMS) }}`
   - `runs-on`/`container.image` sourced from `matrix.combo`
   - builds + packages + attests + uploads `dist-${variant}-${matrix.combo.platform}` artifact

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
  needed to build it. This is a pure prep/refactor step — `PLATFORMS` keeps
  today's single `linux-x86_64` entry with its existing container image and
  `runs-on` value; only how those values are wired into the jobs changes.
- Changing the toolchain or build steps themselves.
