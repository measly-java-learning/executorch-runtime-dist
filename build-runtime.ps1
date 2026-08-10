# build-runtime.ps1 — Windows environment shim for this repo's bash recipes.
#
# Peer to build-runtime.sh: on Windows every bash recipe (build-runtime.sh,
# test/relocatability-windows.sh, scripts/check-windows-crt.sh) must run under
# the Visual Studio dev shell via Git-Bash. This script is that setup, once:
# vswhere -> Launch-VsDevShell (cl/cmake/ninja/dumpbin/INCLUDE/LIB) -> explicit
# Git-Bash -> exec the target with args verbatim.
#
# Usage: pwsh -File build-runtime.ps1 <script> [args...]
#   <script> is passed to bash as-is (repo-relative like ./build-runtime.sh,
#   or Windows-form like C:\repo\build-runtime.sh). cwd is NOT changed: relative
#   scripts and the recipe's cwd expectations resolve against the caller's cwd.
#
#   bash -c recipes: pass -Command and the command string as the script, e.g.
#   pwsh -File build-runtime.ps1 -Command 'set -euo pipefail; ...'  (the ps1
#   runs `bash -c '<command>'` under the dev shell).
#
# Modeled on iree-runtime-dist/build-runtime.ps1. Unlike IREE's, there is no
# GITHUB_PATH append here: no later CI step needs VS tools (the dev-shell env
# is process-local and dies with this script).
param(
  [Parameter(Mandatory, Position = 0)]
  [string]$Script,
  [switch]$Command,
  [Parameter(ValueFromRemainingArguments)]
  [string[]]$ScriptArgs
)
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -property installationPath
if (-not $vsPath) { throw "vswhere found no Visual Studio installation" }

& "$vsPath\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation
if ($LASTEXITCODE -ne 0) { throw "Launch-VsDevShell failed (exit $LASTEXITCODE)" }

$bash = "${env:ProgramFiles}\Git\bin\bash.exe"
if (-not (Test-Path $bash)) { throw "Git Bash not found at $bash -- WSL bash is NOT acceptable" }

if ($Command) {
  & $bash -c $Script @ScriptArgs
} else {
  & $bash $Script @ScriptArgs
}
exit $LASTEXITCODE
