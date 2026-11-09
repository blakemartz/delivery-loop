#!/usr/bin/env bash
# task-queue.sh [--fix] — print the READY set as JSON lines, best task first.
#
# A compatibility wrapper (docs/delivery_graph_spec.md §3 rule 4): the ready set
# is `graph.sh ready` (lib/ready.jq) and `--fix` is `graph.sh reconcile --fix`
# (lib/reconcile.jq, applied by the configured graph backend). Its arguments
# and stdout are v0.1.4's, byte for byte (GC61): one line per ready task,
#   {number, title, unblocks, size: "S"|"M", started, epic: <number>|null,
#    module: "module:<m>"|"none"}
# with `number`/`epic` the numeric ids (a local backend's slug ids stay strings)
# and `module` the full label name. Readiness and order are §5's: an open task,
# every dep done (a cancelled or unknown dep never satisfies, §2 exception 1),
# no claim and no assignee, not size:L, not needs-human; started epics first,
# then unblocks, then S before M, then oldest.
#
# --fix first reconciles derived state (labels are a cache, ground truth is
# issue/PR state, docs/agentic_delivery_spec.md §5.1; the rules are §5 of the
# graph spec): merged PR -> done (closing the issue, with an `AUTO-CLOSE: PR #<n>`
# marker, once per (issue, PR), whatever the target branch: GitHub's closing
# keywords only fire on the default branch), open PR -> in-review, blocked <->
# ready, stale agent claims (4h, no open PR) released with RECLAIMED, stale human
# claims (72h) pinged once, fully delivered epics closed. Its `fix:` and `warn:`
# lines go to stderr, as v0.1.4's did, so stdout stays the ready set. A pass that
# stops because the board changed under it (exit 4) or the backend was busy
# (exit 75; after a $FIX_BACKOFF-second pause) is re-run, up to
# $FIX_PASSES times; if it still stops, the ready set is printed anyway (it is
# read fresh) with a warning. Any other reconcile failure exits with its status,
# printing nothing on stdout.
#
# Exit codes: graph.sh's (0 ok · 1 failed / invalid config · 3 LIST_LIMIT
# reached · 5 a backend node failed validation).
set -euo pipefail

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/graph.sh"
FIX_PASSES=5
FIX_BACKOFF=1   # seconds to wait before re-running a pass the backend lock refused (75)

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-task-queue.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if [ "$FIX" = 1 ]; then
  pass=1
  while :; do
    rc=0
    bash "$GRAPH" reconcile --fix >&2 || rc=$?
    case "$rc" in
      0) break ;;
      4|75)
        if [ "$pass" -ge "$FIX_PASSES" ]; then
          echo "warn: reconcile did not settle after $FIX_PASSES passes (exit $rc); the ready set below is read fresh" >&2
          break
        fi
        # A busy lock (75) is held by another writer: give it a moment. A
        # changed board (4) re-plans at once; there is nothing to wait for.
        [ "$rc" != 75 ] || sleep "$FIX_BACKOFF"
        pass=$((pass + 1)) ;;
      *) exit "$rc" ;;
    esac
  done
fi

rc=0
bash "$GRAPH" ready > "$tmp/ready.jsonl" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
jq -c 'def num: if type == "string" and test("^[0-9]+$") then tonumber else . end;
  {number: (.id | num), title, unblocks,
   size: (if .size == "S" then "S" else "M" end), started,
   epic: (.epic | if . == null then null else num end),
   module: (if .module == null then "none" else "module:\(.module)" end)}' "$tmp/ready.jsonl"
