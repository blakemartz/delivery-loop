# bash32.sh — build and verify the PATH shim the gate uses to run the unit tests
# under a real bash 3.2 (DL_BASH32). Sourced by scripts/check.sh and by its
# self-test scripts/tests/bash32-shim-test.sh; not shipped (repo-root dogfood).
#
# The tests invoke `bash …` by name, so the 3.2 run works by putting a dir whose
# `bash` IS the chosen binary first on PATH. That only holds if the link is
# real: a bare name or relative path copied verbatim into `ln -s` dangles, PATH
# lookup silently skips it, and every test runs under the host bash while the
# gate claims 3.2 (PR #69 review). So: resolve to an absolute executable first,
# then verify through the shim itself — the exact lookup the tests will get.

# bash32_resolve VALUE BASEDIR — print VALUE as an absolute path to an existing
# executable file. A bare name resolves through PATH; a relative path resolves
# against BASEDIR (the caller's original cwd). Non-zero (prints nothing) if it
# can't, including names that resolve to a builtin/function/alias.
bash32_resolve() {
  (
    cd "$2" 2>/dev/null || exit 1
    b="$(command -v -- "$1" 2>/dev/null)" || exit 1
    case "$b" in /*) ;; */*) b="$PWD/$b" ;; *) exit 1 ;; esac
    [ -f "$b" ] && [ -x "$b" ] || exit 1
    d="$(cd "$(dirname "$b")" && pwd -P)" || exit 1
    printf '%s\n' "$d/$(basename "$b")"
  )
}

# bash32_shim VALUE BASEDIR SHIMDIR — link SHIMDIR/bash to the resolved VALUE and
# verify, through SHIMDIR on PATH, that `bash` is that link and reports 3.2.
# Prints the 3.2 version on success; prints FAIL to stderr and returns 1 otherwise.
bash32_shim() {
  _b32_abs="$(bash32_resolve "$1" "$2")" || {
    echo "FAIL: DL_BASH32=$1 does not resolve to an executable file (bare names via PATH, relative paths from $2)" >&2
    return 1
  }
  ln -s "$_b32_abs" "$3/bash" || { echo "FAIL: could not create bash shim in $3" >&2; return 1; }
  # Subshells with a real PATH assignment (which also flushes bash's command
  # hash), exactly like check.sh's test run — not a one-command prefix.
  _b32_got="$(PATH="$3:$PATH"; command -v bash)"
  if [ "$_b32_got" != "$3/bash" ]; then
    echo "FAIL: bash shim did not take effect (PATH resolves bash to '$_b32_got', not $3/bash)" >&2
    return 1
  fi
  _b32_v="$(PATH="$3:$PATH"; export PATH; bash -c 'echo "$BASH_VERSION"' 2>/dev/null)" || _b32_v=""
  case "$_b32_v" in
    3.2*) printf '%s\n' "$_b32_v" ;;
    *) echo "FAIL: DL_BASH32=$1 ($_b32_abs) is not a bash 3.2 binary through the shim (version: '${_b32_v:-none}')" >&2
       return 1 ;;
  esac
}
