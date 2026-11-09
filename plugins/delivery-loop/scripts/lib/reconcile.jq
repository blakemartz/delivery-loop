# reconcile.jq — repair the status cache from ground truth
# (docs/delivery_graph_spec.md §5 `reconcile.jq`; shapes §4.1, §4.2).
#
# Input: {nodes, prs, now}
#   nodes — every node (§4.1), validated with validate_node.
#   prs   — the open PRs plus the PRs merged since the oldest open node was
#           created (§6.2, §6.3), validated with validate_pr.
#   now   — epoch seconds (the caller passes the wall clock, so fixtures are
#           deterministic).
# Output of reconcile_plan: {records, warnings}
#   records  — [{op, id, from, to, reason}], in application order. op is
#              "transition" (a status move), "reclaim" (release a stale agent
#              claim; to = "ready") or "ping" (comment on a stale human claim;
#              from = to, no status change). `reason` is the text the backend
#              posts or prints: a RECLAIMED / STALE-CLAIM-PING reason keeps the
#              v0.1.4 comment text verbatim.
#   warnings — [string]: rule 8 diagnostics, plus one line per record that the
#              transition table rejected (GC65). Never mutations.
# `reconcile` prints the warnings on stderr ("warn: …" lines) and outputs the
# records array, so a backend applies stdout and an operator reads stderr.
#
# Rules (§5), evaluated in this order against a working copy of the board that
# each accepted record updates, so one pass settles a cascade (a merged PR's
# task goes done, its epic completes, a dependent unblocks: GC25):
#   3. an agent PR, state merged, task_id X (X open), base == X's target branch
#      (a promote node's promotion PR targets promote_to, §9), its number not in
#      X.applied_prs -> X done (GC42). A PR already applied is skipped, so a
#      human reopen is never overridden (GC72).
#   7. an open epic with >= 1 child (graph.jq children: backlinks + checklist),
#      every child done or cancelled -> done (GC45). Repeated until no epic
#      changes, so an epic of epics closes in the same pass.
#   4. claimed, or ready/blocked on a task/promote node, + an open agent PR with
#      its task_id -> in-review (GC43; ready/blocked are status drift, GC69;
#      an epic is left to rules 1/2/7). Runs before rules 1 and 2, so a
#      drifted node is never shuffled between ready and blocked first: an open
#      PR outranks the deps.
#   1. blocked -> ready when deps_done and not needs_human (GC4).
#   2. ready -> blocked when not deps_done.
#   5. agent claim, no open PR for the node, now - updated_at > 4h, not
#      needs_human -> reclaim to ready (GC24), from claimed or any later open
#      status, or from ready itself (claim drift), so a claim whose PR closed
#      unmerged is released, not warned about forever (GC73). The node's status
#      is not pre-filtered: the transition table is the judge (GC65).
#   6. human claim on an open node, now - updated_at > 72h, pinged_at null ->
#      one ping; human claims are never released (GC44).
#   8. warnings: `blocked on cancelled dep`, `unknown dep` (open nodes), and
#      `cycle: a → … → a` (graph.jq cycles).
# Rules 1-7 act on task, epic and promote nodes only (_subjects): an `external`
# node (§4.1) gets no record of any rule, filtered here rather than left for the
# transition table to reject, so a board with externals prints no "skipped"
# warnings. Externals still count as deps (satisfied only when done) and as epic
# children (rule 7), since both read the whole board.
# A node gets at most one record per pass: the first rule that fires wins.
# Every transition/reclaim record is validated with transitions.jq (actor
# reconcile) before it is accepted; a rejected one becomes a warning and is
# skipped, and the other records stand (GC65). Timestamps go through graph.jq
# iso_epoch, which normalizes fractions and ±hh:mm offsets. Pure: no I/O.
#
# Usage: jq -L scripts/lib 'include "reconcile"; reconcile' input.json
include "node";
include "pr";
include "graph";
include "transitions";

def stale_agent_seconds: 4 * 3600;
def stale_human_seconds: 72 * 3600;

def reclaim_reason: "RECLAIMED: agent claim was idle >4h with no open PR; task is ready again.";
def ping_reason: "STALE-CLAIM-PING: this claim has been inactive for 72h — still on it? (Human claims are never auto-reclaimed.)";

# _merge_base — input: a node. The branch its merged PR must target.
def _merge_base: if .kind == "promote" then .promote_to else .target_branch end;

# _offer($rec) — input: the pass state {nodes, idx, touched, records,
# warnings}. Accept $rec when its node has no record yet this pass and the
# table allows the move (ping records move nothing, so they skip the table);
# an accepted move updates the working copy.
def _offer($rec):
  if .touched[$rec.id] then .
  else
    .idx[$rec.id] as $node
    | (if $rec.op == "ping" then null
       else $node | transition_error($rec.to; "reconcile") end) as $err
    | if $err != null then
        .warnings += ["skipped \($rec.op) \($rec.id): \($err) (\($rec.reason))"]
      else
        .records += [$rec]
        | .touched[$rec.id] = true
        | .idx[$rec.id].status = $rec.to
        | if $rec.op == "reclaim" then .idx[$rec.id].claim = null else . end
      end
  end;

# _offer_all(f) — offer every record f yields; f sees the state as it stood
# before this batch (one rule's matches are independent of each other).
def _offer_all(f): reduce f as $rec (.; _offer($rec));

# _nodes — the working copy as a node array, in input order.
def _nodes: .idx as $idx | .order | map($idx[.]);

# _is_subject — input: a node. Rules 1-7 act on it (§5: task, epic, promote).
def _is_subject: .kind == "task" or .kind == "epic" or .kind == "promote";

# _subjects — the working copy's rule 1-7 subjects, as a stream, in input order.
def _subjects: _nodes[] | select(_is_subject);

def _rec($op; $to; $reason): {op: $op, id, from: .status, to: $to, reason: $reason};

# _rule3 — §5 rule 3 is existential: *an* agent PR merged into the node's merge
# base closes it. The base and `applied_prs` are checked per PR before grouping,
# so a newer merge elsewhere (a cherry-pick into main) cannot hide the qualifying
# one, and an applied PR never re-closes a reopened node (GC72); among the
# qualifying PRs the newest names the record.
def _rule3($prs):
  _offer_all(
    .idx as $idx
    | $prs
    | map(select(.agent and .state == "merged" and .task_id != null
                 and $idx[.task_id] != null
                 and .base == ($idx[.task_id] | _merge_base)
                 and (.number as $n | any($idx[.task_id].applied_prs[]; . == $n) | not)))
    | group_by(.task_id)[]
    | max_by(.number) as $pr
    | $idx[$pr.task_id]
    | select(_is_subject and is_open)
    | _rec("transition"; "done"; "PR #\($pr.number) merged into \($pr.base)"));

def _rule7:
  until(
    ._epics_done;
    (.records | length) as $before
    | _offer_all(
        _nodes as $all
        | $all[]
        | select(.kind == "epic" and is_open)
        | .id as $e
        | ($all | children($e)) as $kids
        | select(($kids | length) > 0
                 and all($kids[]; .status == "done" or .status == "cancelled"))
        | _rec("transition"; "done";
               "epic fully delivered: all \($kids | length) children are done or cancelled"))
    | ._epics_done = ((.records | length) == $before))
  | del(._epics_done);

def _rules12:
  _offer_all(
    .idx as $idx
    | _subjects
    | if .status == "blocked" and deps_done($idx) and (.needs_human | not) then
        _rec("transition"; "ready"; "every dep is done")
      elif .status == "ready" and (deps_done($idx) | not) then
        _rec("transition"; "blocked"; "a dep is not done")
      else empty end);

def _rule4($open):
  _offer_all(
    _subjects
    # ready/blocked drift is a task/promote repair only: an epic sent to
    # in-review could never be closed by rule 7 (epic rows allow ready -> done).
    | select(.status == "claimed"
             or ((.status == "ready" or .status == "blocked")
                 and (.kind == "task" or .kind == "promote")))
    | .id as $id
    | first($open[] | select(.agent and .task_id == $id)) as $pr
    | _rec("transition"; "in-review"; "open PR #\($pr.number)"));

def _rule5($open; $now):
  _offer_all(
    _subjects
    | select(.claim != null and .claim.by == "agent" and (.needs_human | not)
             and ($now - (.updated_at | iso_epoch)) > stale_agent_seconds)
    | .id as $id
    | select(any($open[]; .task_id == $id) | not)
    | _rec("reclaim"; "ready"; reclaim_reason));

def _rule6($now):
  _offer_all(
    _subjects
    | select(.claim != null and .claim.by == "human" and is_open
             and .pinged_at == null
             and ($now - (.updated_at | iso_epoch)) > stale_human_seconds)
    | _rec("ping"; .status; ping_reason));

def _rule8:
  _nodes as $all
  | .idx as $idx
  | .warnings += [
      ($all[] | select(is_open) | .id as $id | .deps[].id
       | if $idx[.] == null then "\($id): unknown dep \(.)"
         elif $idx[.].status == "cancelled" then "\($id): blocked on cancelled dep \(.)"
         else empty end),
      ($all | cycles[] | "cycle: \(join(" → "))") ];

def reconcile_plan:
  if (.now | type) != "number" then error("reconcile: `now` must be epoch seconds (got \(.now | tojson))")
  else . end
  | (.nodes | map(validate_node)) as $nodes
  | (.prs | map(validate_pr)) as $prs
  | ($prs | map(select(.state == "open"))) as $open
  | .now as $now
  | {order: ($nodes | map(.id)), idx: ($nodes | index_by_id),
     touched: {}, records: [], warnings: []}
  | _rule3($prs) | _rule7 | _rule4($open) | _rules12 | _rule5($open; $now)
  | _rule6($now) | _rule8
  | {records, warnings};

def reconcile:
  reconcile_plan
  | (.warnings[] | "warn: \(.)\n" | stderr | empty), .records;
