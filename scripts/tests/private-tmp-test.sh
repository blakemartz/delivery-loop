#!/usr/bin/env bash
# private-tmp-test.sh — self-test for scripts/lib/private-tmp.sh, the gate's
# temp-leak check (#70). Proves a clean run passes, and that a run which leaks
# (a file, a dir, a dotfile), fails, or deletes its TMPDIR is rejected with the
# leaked path listed — so the check can't silently go blind.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/lib/private-tmp.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
ok()   { echo "ok - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

clean()       { d="$(mktemp -d)"; touch "$d/x"; rm -rf "$d"; }
leak_dir()    { mktemp -d "${TMPDIR:-/tmp}/leaky-dir.XXXXXX" > /dev/null; }
leak_file()   { : > "$TMPDIR/leaky-file"; }
leak_dot()    { : > "$TMPDIR/.leaky-dot"; }
failing()     { mktemp -d > /dev/null; return 3; }
nuke_tmpdir() { rm -rf "$TMPDIR"; }
sees_tmpdir() { case "$TMPDIR" in "$work"/dl-private-tmp.*) ;; *) return 1 ;; esac; }

# pass LABEL CMD — the run must be accepted, and its private dir removed.
pass() {
  local label="$1" out; shift
  if out="$(private_tmp_run "$work" "$label" "$@" 2>&1)"; then ok "$label: accepted"
  else fail "$label: rejected ($out)"; fi
}
# reject LABEL PATTERN CMD — the run must be rejected with a FAIL line whose
# output matches PATTERN (the leaked path), and its private dir removed.
reject() {
  local label="$1" pat="$2" out; shift 2
  if out="$(private_tmp_run "$work" "$label" "$@" 2>&1)"; then
    fail "$label: accepted"
  elif ! grep -q "$pat" <<<"$out"; then
    fail "$label: rejected but output lacks '$pat' ($out)"
  else ok "$label: rejected"; fi
}

pass   "clean run"                                  clean
pass   "TMPDIR is the private dir"                  sees_tmpdir
reject "leaked mktemp -d dir"       '^    .*/dl-private-tmp\.[^/]*/leaky-dir\.' leak_dir
reject "leaked file"                '/leaky-file$'  leak_file
reject "leaked dotfile"             '/\.leaky-dot$' leak_dot
reject "failing command"            .               failing
reject "TMPDIR itself removed"      'is gone'       nuke_tmpdir

left="$(find "$work" -mindepth 1 -maxdepth 1)"
if [ -z "$left" ]; then ok "every private dir removed afterwards"
else fail "private dirs left behind: $left"; fi

[ "$fails" -eq 0 ] || { echo "private-tmp-test: $fails failure(s)" >&2; exit 1; }
echo "private-tmp-test: all passed"
