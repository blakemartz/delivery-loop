#!/usr/bin/env bash
# Unit tests for lib/ready.jq, lib/graph.jq and lib/transitions.jq: the ready
# predicate and order, the shared graph helpers, and the transition table of
# docs/delivery_graph_spec.md §5. Owns golden cases GC1, GC3, GC5, GC8, GC47 and
# the "not ready" assertions of GC2, GC4, GC6, GC7 (§12, §17 row A4).
#
# Offline: the fixtures under fixtures/ready/ are the only input. Each ready-set
# case asserts the exact ready id list, and every fixture carries a ready
# control node, so a case cannot pass vacuously on an empty set.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib"
fx="$here/fixtures/ready"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ready-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done; fails=1; }

# eq <name> <want> <got>
eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want: $2" "got:  $3"; fi
}

# ready_ids <fixture>: the ready set's ids, in order, as one compact JSON array.
ready_ids() {
  jq -c -L "$lib" 'include "ready"; [ready_set[].id]' "$fx/$1"
}

# --- ready predicate -----------------------------------------------------------
# GC1: deps all done, no claim, size S -> ready. The epic, the agent- and
# human-claimed tasks and the task whose dep is only claimed are not.
eq "GC1 task with every dep done, unclaimed, size S is ready" \
  '["gc1-ready"]' "$(ready_ids gc1.json)"

eq "GC2 dep cancelled -> not ready" '["gc2-control"]' "$(ready_ids gc2.json)"

eq "GC3 size L -> never ready (deps or no deps)" '["gc3-control"]' "$(ready_ids gc3.json)"

eq "GC4 needs_human, deps done, status blocked -> not ready" \
  '["gc4-unflagged"]' "$(ready_ids gc4.json)"

eq "GC6 deps A->B->A -> neither ready" '["gc6-control"]' "$(ready_ids gc6.json)"

eq "GC7 dep on a nonexistent id -> not ready" '["gc7-control"]' "$(ready_ids gc7.json)"

# --- GC5: v0.1.4-parity order ----------------------------------------------------
# gc5-v014.jsonl is the stdout of the released v0.1.4 task-queue.sh, captured by
# running it against the same board as raw `gh issue list` JSON through a gh shim;
# gc5-nodes.json is that board normalized to §4.1. The five ready tasks exercise
# each sort key: started epic beats unblocks (15 over 12), unblocks beats size
# (12 over 16), S beats age (16 and 11 over the older 17), age orders equals
# (16 before 11). Projected here onto the v0.1.4 line shape (the task-queue.sh
# wrapper's job, §5) so every field is compared, not just the order.
got=$(jq -c -L "$lib" 'include "ready"; ready
  | {number: (.id | tonumber), title, unblocks,
     size: (if .size == "S" then "S" else "M" end), started,
     epic: (.epic | if . == null then null else tonumber end),
     module: (if .module == null then "none" else "module:\(.module)" end)}' \
  "$fx/gc5-nodes.json")
eq "GC5 ready order and fields equal the captured v0.1.4 output" \
  "$(cat "$fx/gc5-v014.jsonl")" "$got"

eq "GC5 ready lines carry the §5 field set" \
  '["epic","id","module","size","started","target_branch","title","unblocks"]' \
  "$(jq -c -L "$lib" 'include "ready"; [ready_set[] | keys] | unique | .[]' "$fx/gc5-nodes.json")"

# created_at is compared as an instant, not as a string: an offset timestamp
# that is lexically later but earlier in time sorts first.
eq "ready order compares created_at instants across offsets" '["early-offset","late-utc"]' \
  "$(jq -c -L "$lib" 'include "ready";
      map(.deps = []
          | if .id == "gc7-control"
            then .id = "early-offset" | .created_at = "2026-01-01T03:00:00+06:00"
            else .id = "late-utc" | .created_at = "2025-12-31T22:00:00Z" end)
      | [ready_set[].id]' "$fx/gc7.json")"

# Input is validated: a malformed node fails fast instead of skewing the set.
if jq -c -L "$lib" 'include "ready"; .[0].status = "open" | ready_set' "$fx/gc1.json" >/dev/null 2>&1; then
  fail "malformed node rejected by ready_set" "accepted"
else
  pass "malformed node rejected by ready_set"
fi

# --- graph.jq helpers -----------------------------------------------------------
eq "cycles names the GC6 cycle" '[["gc6-a","gc6-b","gc6-a"]]' \
  "$(jq -c -L "$lib" 'include "graph"; cycles' "$fx/gc6.json")"

eq "cycles: self-loop and two cycles sharing a node, each once" \
  '[["a","a"],["a","b","a"],["a","b","c","a"]]' \
  "$(jq -c -n -L "$lib" 'include "graph";
      [{id:"a",deps:[{id:"a"},{id:"b"}]},{id:"b",deps:[{id:"a"},{id:"c"}]},
       {id:"c",deps:[{id:"a"},{id:"zz"}]}] | cycles')"

eq "cycles: acyclic graph (unknown dep included) -> []" '[]' \
  "$(jq -c -L "$lib" 'include "graph"; cycles' "$fx/gc7.json")"

eq "unblocks counts open dependents only (cancelled 19 excluded)" '[2,0,2]' \
  "$(jq -c -L "$lib" 'include "graph"; [unblocks("12"), unblocks("15"), unblocks("12")]' "$fx/gc5-nodes.json")"

eq "children = epic backlinks plus existing checklist ids" '["10","13","15"]' \
  "$(jq -c -L "$lib" 'include "graph"; [children("1")[].id] | sort' "$fx/gc5-nodes.json")"

eq "children includes a checklist-only child (its epic stays null)" '["gc1-ready"]' \
  "$(jq -c -L "$lib" 'include "graph"; [children("gc1-epic")[].id]' "$fx/gc1.json")"

eq "index_by_id looks nodes up by id" '"done"' \
  "$(jq -c -L "$lib" 'include "graph"; index_by_id["10"].status' "$fx/gc5-nodes.json")"

eq "iso_epoch handles Z, fractions and offsets" '[0,0.25,0,0]' \
  "$(jq -c -n -L "$lib" 'include "graph"; ["1970-01-01T00:00:00Z","1970-01-01T00:00:00.25Z",
      "1970-01-01T01:30:00+01:30","1969-12-31T23:00:00-01:00"] | map(iso_epoch)')"

# --- transitions.jq ---------------------------------------------------------------
# transition <store> <to> <actor>: the write path graph.sh transition follows —
# assert the move, and replace the store only on success. Prints jq's exit code.
transition() {
  local store="$1" to="$2" actor="$3" out rc=0
  out=$(jq --indent 2 -L "$lib" --arg to "$to" --arg actor "$actor" \
    'include "transitions"; map(assert_transition($to; $actor) | .status = $to)' \
    "$store" 2>"$tmp/stderr") || rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$out" >"$store"; fi
  echo "$rc"
}

cp "$fx/gc8-store.json" "$tmp/gc8.json"
eq "GC8 transition ready -> approved exits 2" 2 "$(transition "$tmp/gc8.json" approved agent)"
if cmp -s "$fx/gc8-store.json" "$tmp/gc8.json"; then pass "GC8 store unchanged"
else fail "GC8 store unchanged" "store was rewritten"; fi
case "$(cat "$tmp/stderr")" in
  *'illegal transition "gc8-task": ready -> approved by agent'*) pass "GC8 stderr names the illegal move" ;;
  *) fail "GC8 stderr names the illegal move" "got: $(cat "$tmp/stderr")" ;;
esac

cp "$fx/gc47-store.json" "$tmp/gc47.json"
eq "GC47 transition cancelled --actor agent exits 2" 2 "$(transition "$tmp/gc47.json" cancelled agent)"
if cmp -s "$fx/gc47-store.json" "$tmp/gc47.json"; then pass "GC47 store unchanged after agent cancel"
else fail "GC47 store unchanged after agent cancel" "store was rewritten"; fi
eq "GC47 transition cancelled --human ann exits 0" 0 "$(transition "$tmp/gc47.json" cancelled human)"
eq "GC47 node is cancelled after the human cancel" '"cancelled"' "$(jq -c '.[0].status' "$tmp/gc47.json")"

# The whole table, row by row, plus the edges around it. Each line:
# <kind> <from> <to> <actor> <legal: 0|1>.
while read -r kind from to actor want; do
  [ -n "$kind" ] || continue
  got=$(jq -n -L "$lib" --arg k "$kind" --arg f "$from" --arg t "$to" --arg a "$actor" \
    'include "transitions"; {id: "x", kind: $k, status: $f}
     | if transition_error($t; $a) == null then 1 else 0 end')
  eq "transition $kind $from -> $to by $actor is $( [ "$want" = 1 ] && echo legal || echo illegal)" "$want" "$got"
done <<'EOF'
task blocked ready reconcile 1
task blocked ready agent 0
task ready blocked reconcile 1
task ready claimed agent 1
task ready claimed human 1
task ready claimed promote 0
promote ready claimed promote 1
task claimed ready reconcile 1
task claimed ready agent 1
task claimed ready human 0
promote claimed ready promote 1
task claimed in-review agent 1
task claimed in-review reconcile 1
promote claimed in-review promote 1
task in-review changes-requested agent 1
task in-review changes-requested reconcile 0
task changes-requested in-review agent 1
task in-review approved agent 1
task ready approved agent 0
task claimed done reconcile 1
task approved done reconcile 1
task in-review done reconcile 1
task changes-requested done reconcile 1
task approved done agent 0
task ready done reconcile 0
promote claimed done promote 1
task claimed done promote 0
promote in-review done reconcile 1
task blocked cancelled human 1
task changes-requested cancelled human 1
task in-review cancelled agent 0
task in-review cancelled reconcile 0
task done cancelled human 0
task cancelled ready reconcile 0
task done ready reconcile 0
task ready ready reconcile 0
task ready claimed robot 0
task ready open reconcile 0
EOF

if [ "$fails" -ne 0 ]; then
  echo "ready tests FAILED" >&2
  exit 1
fi
echo "ready tests passed"
