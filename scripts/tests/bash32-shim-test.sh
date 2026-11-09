#!/usr/bin/env bash
# bash32-shim-test.sh — self-test for scripts/lib/bash32.sh, the DL_BASH32 shim
# behind the gate's bash 3.2 run. Proves that when the shim is accepted, a
# test-style `bash "$t"` really executes under the chosen binary, and that every
# way the link could silently fall through to the host bash (PR #69 review: a
# bare name or relative path made a dangling symlink) is resolved or FAILS.
#
# The "bash 3.2" here is a stub: it answers the shim's version probe as 3.2 and
# logs every other invocation before exec'ing the real bash. A non-empty log is
# the proof the tests ran through it; the host bash never writes that log.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/lib/bash32.sh

real_bash="$(command -v bash)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
ok()   { echo "ok - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

mkdir -p "$work/bin" "$work/other"
# stub VERSION LOG — print a stub bash that claims VERSION and logs to LOG.
stub() {
  printf '#!%s\n' "$real_bash"
  printf 'if [ "$#" -eq 2 ] && [ "$1" = -c ] && [ "$2" = %s ]; then echo %q; exit 0; fi\n' \
    "'echo \"\$BASH_VERSION\"'" "$1"
  printf 'echo "$*" >> %q\n' "$2"
  printf 'exec %q "$@"\n' "$real_bash"
}
stub '3.2.57(1)-stub' "$work/log" > "$work/bin/stubbash32"
stub '5.2.21(1)-stub' "$work/log5" > "$work/bin/stubbash5"
chmod +x "$work/bin/stubbash32" "$work/bin/stubbash5"
cp "$work/bin/stubbash32" "$work/bin/noexec"; chmod -x "$work/bin/noexec"
# A test file that, like the real suite, shells out to `bash` by name.
printf 'bash -c "exit 0"\n' > "$work/fake-test.sh"

# accept LABEL VALUE BASEDIR [PATHPREFIX] — the shim must be accepted, and a
# test run through it must land in the stub's log (two calls: the test itself
# and its nested `bash -c`).
accept() {
  local shim v n
  shim="$(mktemp -d "$work/shim.XXXXXX")"
  : > "$work/log"
  if ! v="$(PATH="${4:-}$PATH"; bash32_shim "$2" "$3" "$shim" 2>&1)"; then
    fail "$1: shim rejected ($v)"; return
  fi
  [ "$v" = '3.2.57(1)-stub' ] || { fail "$1: version '$v'"; return; }
  (PATH="$shim:$PATH"; export PATH; bash "$work/fake-test.sh")
  n="$(wc -l < "$work/log" | tr -d ' ')"
  [ "$n" -ge 2 ] || { fail "$1: accepted but test did NOT run under the stub ($n logged calls)"; return; }
  [ "$(readlink "$shim/bash")" = "$work/bin/stubbash32" ] \
    || { fail "$1: link is '$(readlink "$shim/bash")', not the absolute stub"; return; }
  ok "$1: accepted; test ran under the stub ($n logged calls)"
}

# reject LABEL VALUE BASEDIR [PATHPREFIX] — the shim must fail loudly.
reject() {
  local shim out
  shim="$(mktemp -d "$work/shim.XXXXXX")"
  if out="$(PATH="${4:-}$PATH"; bash32_shim "$2" "$3" "$shim" 2>&1)"; then
    fail "$1: shim accepted (would run under '$(readlink "$shim/bash")')"
  else
    case "$out" in *FAIL:*) ok "$1: rejected (${out#FAIL: })" ;;
                   *) fail "$1: rejected without a FAIL message ('$out')" ;; esac
  fi
}

accept "absolute path"                 "$work/bin/stubbash32" "$work/other"
accept "bare name on PATH"             stubbash32             "$work/other" "$work/bin:"
accept "relative path from invoker"    bin/stubbash32         "$work"
accept "./relative path from invoker"  ./bin/stubbash32       "$work"
reject "bare name not on PATH"         stubbash32             "$work/other"
reject "relative path, wrong invoker"  bin/stubbash32         "$work/other"
reject "nonexistent absolute path"     "$work/bin/nope"       "$work/other"
reject "non-executable file"           "$work/bin/noexec"     "$work/other"
reject "directory"                     "$work/bin"            "$work/other"
reject "builtin name"                  echo                   "$work/other"
reject "binary that is not 3.2"        "$work/bin/stubbash5"  "$work/other"

# The regression itself: a verbatim relative symlink dangles, so PATH lookup
# falls through to the host bash. The shim's through-PATH check must catch it
# even if a future edit reintroduces the verbatim link.
dangle="$(mktemp -d "$work/shim.XXXXXX")"
ln -s stubbash32 "$dangle/bash"
if [ "$(PATH="$dangle:$PATH"; command -v bash)" != "$dangle/bash" ]; then
  ok "dangling shim link is not what PATH resolves (the through-shim check sees it)"
else
  fail "dangling shim link resolved through PATH"
fi

[ "$fails" -eq 0 ] || { echo "bash32-shim-test: $fails failure(s)" >&2; exit 1; }
echo "bash32-shim-test: all passed"
