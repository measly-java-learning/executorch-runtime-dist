#!/usr/bin/env bash
# GNU/BSD userland portability helpers. These are the single source of truth for every operation
# whose spelling differs between Linux (GNU coreutils/sed, manylinux), macOS (BSD userland), and
# Git-Bash on Windows. Call sites use these helpers and never spell the variants out themselves:
# BSD `sed -i` silently treats the next argument as a backup suffix, which turns a script into a
# corrupt edit or an "invalid command code" abort far from the cause.
# Source me.

# The recipe uses bash 4 syntax (${v,,}, etc). /bin/bash on macOS is 3.2, where that syntax is a
# parse error that points at the wrong line. Fail early and name the fix instead.
require_bash4() {
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "bash >= 4 required (running ${BASH_VERSION:-unknown}). On macOS: brew install bash," >&2
    echo "  then make sure Homebrew's bin dir comes before /bin on PATH (#!/usr/bin/env bash finds it)." >&2
    return 1
  fi
}

# In-place sed that works with both GNU and BSD sed. Both accept an attached backup suffix
# (-i.SUFFIX), so attach one and remove the backup afterwards. The file must be the LAST argument.
# Keep the sed script itself POSIX: in a replacement, use a backslash followed by a literal newline
# rather than GNU's `\n`, which BSD sed inserts as a plain 'n'.
sed_inplace() { # <sed args...> <file>
  local _f="${*: -1}"
  sed -i.etnp-bak "$@" && rm -f "$_f.etnp-bak"
}

# Number of online CPUs, for build parallelism. nproc is GNU coreutils (absent on stock macOS),
# hw.ncpu is the BSD/macOS sysctl, and NUMBER_OF_PROCESSORS is set by Windows.
ncpu() {
  local _n=""
  _n="$(nproc 2>/dev/null || true)"
  [ -n "$_n" ] || _n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  [ -n "$_n" ] || _n="${NUMBER_OF_PROCESSORS:-}"
  printf '%s' "${_n:-4}"
}

# Print "<hex>  <name>", the same output format as sha256sum (the format of every .sha256 sidecar
# this repo publishes). Run it from the file's directory so <name> is a bare basename. Falls back
# to shasum, which ships with macOS (via perl), when sha256sum is missing.
sha256_file() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

# The OS this script is running on: linux | macos | windows (Git-Bash/MSYS/Cygwin). Compared with
# the --platform's OS by platform_matches_host (lib/configure-base.sh), so a build never configures
# one OS's flags on another. Unknown hosts fail rather than guess.
host_os() {
  case "$(uname -s)" in
    Linux)  printf 'linux' ;;
    Darwin) printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) echo "host_os: unsupported host '$(uname -s)'" >&2; return 1 ;;
  esac
}
