# ready.jq — the ready set, best first (docs/delivery_graph_spec.md §5).
#
# Input: every node (§4.1 shape) as one array. Each node is checked with
# validate_node first, so backend drift fails fast (jq exit 5) instead of
# silently changing what is claimable. Pure: no I/O, no clock.
#
#   is_ready($idx)  — the input node is ready; $idx is `index_by_id` of all nodes.
#   started_epic($epic; $idx) — epic id $epic (input: all nodes) has >= 1 child
#                     that is done or cancelled (external children included, §5).
#   ready_set       — [{id, title, unblocks, size, started, epic, module,
#                     target_branch}], best first.
#   ready           — ready_set as a stream (one JSON line each with `jq -c`).
#
# Ready iff: a task (never an epic, promote or external node); not
# done/cancelled; deps_done (graph.jq: every dep exists and is done; a
# cancelled or unknown dep never satisfies readiness, GC2/GC7; an external dep
# counts only when done, GC68); unclaimed (a
# human assignee is a `by: "human"` claim, §4.1); size is not L; not needs_human.
# The status label is a cache (design spec §5.1), so it is deliberately not
# consulted: a `blocked` task whose deps are now done is ready, as in v0.1.4.
#
# Order (parity with v0.1.4 task-queue.sh, GC5):
#   1. started epic first;  2. unblocks descending;  3. S before M (a node with
#   no size ranks as M, as v0.1.4 did);  4. created_at ascending. Ties keep
#   input order (jq's sort_by is stable), as v0.1.4's did.
#
# Usage: jq -c -L scripts/lib 'include "ready"; ready' nodes.json
include "node";
include "graph";

def is_ready($idx):
  .kind == "task"
  and is_open
  and deps_done($idx)
  and .claim == null
  and .size != "L"
  and (.needs_human | not);

# Input: all nodes; $epic an epic id (or null). Parity: v0.1.4 only counted
# issues labeled `epic`, so an `epic` reference to a non-epic node is not started.
def started_epic($epic; $idx):
  $epic != null
  and $idx[$epic].kind == "epic"
  and any(children($epic)[]; .status == "done" or .status == "cancelled");

def ready_set:
  map(validate_node)
  | . as $all
  | index_by_id as $idx
  | [ .[] | select(.kind == "epic") | .id
      | select(. as $e | $all | started_epic($e; $idx)) ] as $started
  | [ .[]
      | select(is_ready($idx))
      | .id as $id
      | { id, title,
          unblocks: ($all | unblocks($id)),
          size,
          started: (.epic as $e | $e != null and any($started[]; . == $e)),
          epic, module, target_branch,
          _created: (.created_at | iso_epoch) } ]
  | sort_by([(if .started then 0 else 1 end), -.unblocks,
             (if .size == "S" then 0 else 1 end), ._created])
  | map(del(._created));

def ready: ready_set[];
