#!/usr/bin/env bash
# lock-race.sh <role> <sync-dir> — one process of the GC22(c) race in
# tests/graph-local-test.sh. Sources backends/graph-local.sh (which defines the
# gl_* functions without running a primitive) and drives the real lock code; the
# roles only add synchronization points, so the interleaving is forced instead of
# hoped for. STATE_DIR, LOCK_WAIT_SECONDS and STALE_LINE come from the caller.
#
#   b2  the breaker that judged the stale lock and is then paused: its
#       gl_break_lock touches b2-judged, waits for c-holds, runs the real break
#       with the line it judged (now outdated), touches b2-rechecked, then it
#       acquires normally.
#   b1  a breaker that runs unpaused.
#   c   the third process: waits until the stale lock is gone, acquires, touches
#       c-holds, waits for b2-rechecked, then records whether its own owner line
#       is still lock/owner (c-result: intact | clobbered).
#   n   a plain acquirer (the many-breakers stress).
set -euo pipefail

role="$1" sync="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../backends/graph-local.sh
. "$here/../../../backends/graph-local.sh"
gl_resolve_state

wait_for() { # <file>: up to 10s
  local i=0
  while [ ! -e "$1" ]; do
    i=$((i + 1)); [ "$i" -le 200 ] || { echo "lock-race $role: timed out waiting for $1" >&2; exit 3; }
    sleep 0.05
  done
}

case "$role" in
  b2)
    eval "_orig_$(declare -f gl_break_lock)"
    gl_break_lock() {
      touch "$sync/b2-judged"
      wait_for "$sync/c-holds"
      _orig_gl_break_lock "$@"
      touch "$sync/b2-rechecked"
    }
    gl_with_lock true ;;
  b1) gl_with_lock true ;;
  n)  gl_with_lock true ;;
  c)
    i=0
    while [ "$(gl_read_owner "$GL_LOCK")" = "$STALE_LINE" ]; do
      i=$((i + 1)); [ "$i" -le 200 ] || { echo "lock-race c: stale lock never broken" >&2; exit 3; }
      sleep 0.05
    done
    c_section() {
      touch "$sync/c-holds"
      wait_for "$sync/b2-rechecked"
      if [ "$(gl_read_owner "$GL_LOCK")" = "$GL_HELD" ]; then echo intact; else echo clobbered; fi > "$sync/c-result"
    }
    gl_with_lock c_section ;;
  *) echo "lock-race: unknown role $role" >&2; exit 2 ;;
esac
