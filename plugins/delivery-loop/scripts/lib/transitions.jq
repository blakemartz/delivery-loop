# transitions.jq — the complete node status transition table
# (docs/delivery_graph_spec.md §5; supersedes the design spec's §5 table).
#
# Validates (from, to, actor) for one node. `graph.sh transition` and reconcile's
# own fix records both go through it, so there is exactly one definition of a
# legal move. The table's "When" column (deps done, PR merged, …) is the
# caller's guard; this module checks only that the move itself is allowed.
# needs_human is a flag, not a status, so it never appears here. Pure: no I/O.
#
#   transition_actors — the actor kinds: agent | human | promote | reconcile.
#   transitions       — the table: [{from: [status], to, actors: [actor], when}],
#                       plus `kinds: [kind]` on a row that applies only to those
#                       node kinds (absent = every kind).
#   transition_error($to; $actor)  — input node: null when legal, else the reason.
#   assert_transition($to; $actor) — input node unchanged when legal; else the
#                       reason on stderr and jq exits 2 (GC8, GC47), so a
#                       caller that writes only on success leaves the store
#                       unchanged.
#
# Usage: jq -L scripts/lib --arg to approved --arg actor agent \
#          'include "transitions"; assert_transition($to; $actor)' node.json
include "node";

def transition_actors: ["agent", "human", "promote", "reconcile"];

def open_statuses: node_statuses - ["done", "cancelled"];

def transitions: [
  {from: ["blocked"], to: "ready", actors: ["reconcile"],
   when: "every dep done, not needs_human"},
  {from: ["ready"], to: "blocked", actors: ["reconcile"],
   when: "a dep is not done"},
  {from: ["ready"], to: "claimed", actors: ["agent", "human", "promote"],
   when: "claim (promote only on kind==promote nodes)"},
  {from: ["claimed"], to: "ready", actors: ["reconcile", "agent", "promote"],
   when: "stale reclaim; claimant releases (promote: red gate, GC50)"},
  {from: ["claimed"], to: "in-review", actors: ["agent", "reconcile", "promote"],
   when: "PR opened (reconcile: open PR exists, GC43; promote: promotion PR opened, GC51)"},
  {from: ["ready", "blocked"], to: "in-review", actors: ["reconcile"], kinds: ["task", "promote"],
   when: "kind task|promote only: status drift: an open agent PR with this task_id while the claim was cleared or the status relabelled (reconcile rule 4, GC69)"},
  {from: ["in-review"], to: "changes-requested", actors: ["agent"],
   when: "reviewer verdict REQUEST_CHANGES"},
  {from: ["changes-requested"], to: "in-review", actors: ["agent"],
   when: "patcher pushed fixes"},
  {from: ["in-review"], to: "approved", actors: ["agent"],
   when: "reviewer verdict APPROVE"},
  {from: open_statuses, to: "done", actors: ["reconcile"],
   when: "PR with this task_id merged into the node's target_branch (GC42); claimed covers a merge that lands before the label edit, blocked/ready cover label drift and human-driven PRs (reconcile rule 3: any open status)"},
  {from: ["ready"], to: "done", actors: ["reconcile"], kinds: ["epic"],
   when: "kind==epic only: an open epic with >= 1 child, every child done or cancelled (reconcile rule 7, GC45)"},
  {from: ["claimed"], to: "done", actors: ["promote"],
   when: "promote node with identical trees (§9)"},
  {from: ["in-review"], to: "done", actors: ["reconcile"],
   when: "promotion PR merged (§9)"},
  {from: open_statuses, to: "cancelled", actors: ["human"],
   when: "graph.sh transition <id> cancelled --human <name> (GC47)"}
];

# _row_allows($from; $to; $actor; $kind) — input: one table row. The row's
# `kinds` guard is checked explicitly, like the promote-actor guard below.
def _row_allows($from; $to; $actor; $kind):
  .to == $to
  and any(.from[]; . == $from)
  and any(.actors[]; . == $actor)
  and (.kinds == null or any(.kinds[]; . == $kind));

def transition_error($to; $actor):
  .status as $from
  | .kind as $kind
  | (.kind == "promote") as $promote_node
  | "\(.id | tojson): \($from) -> \($to) by \($actor)" as $move
  | if any(transition_actors[]; . == $actor) | not then
      "unknown actor \($actor | tojson) (expected \(transition_actors | join("|")))"
    elif any(node_statuses[]; . == $to) | not then
      "unknown status \($to | tojson) (expected \(node_statuses | join("|")))"
    elif $actor == "promote" and ($promote_node | not) then
      "illegal transition \($move): the promote actor acts only on promote nodes"
    elif any(transitions[]; _row_allows($from; $to; $actor; $kind)) then null
    else "illegal transition \($move)" end;

def assert_transition($to; $actor):
  transition_error($to; $actor) as $err
  | if $err == null then . else "\($err)\n" | halt_error(2) end;
