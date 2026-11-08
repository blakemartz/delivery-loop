# tick-plan.jq — the orchestrator tick's action plan (docs/delivery_graph_spec.md
# §5 `tick-plan.jq`, §9 promote nodes). Replaces delivery-tick's prose priority
# rules: the tick executes these actions in order and decides nothing itself.
#
# Input: {nodes, prs, flags: {parallel, auto_merge}, now}
#   nodes  — every node (§4.1), validated with validate_node.
#   prs    — PRs (§4.2), validated with validate_pr. Only open ones are used, so
#            the caller may pass a wider feed.
#   flags  — parallel: the parsed N (tick-plan.sh does the GC17 parsing), or
#            null; N <= 1 means serial. auto_merge: bool (null = false).
#   now    — epoch seconds. No rule here depends on the clock (staleness is
#            reconcile's), so it is accepted for the §5 contract and unused.
# Output: {mode, actions, board, waiting}
#   mode    — {name: "serial"|"parallel", n}: n is the agent-action cap
#             (serial 1, parallel N, at most 16).
#   actions — [{action, pr?, id?, reason}] in execution order: every merge, then
#             every promote (deterministic scripts, not counted against n), then
#             the agent actions (patch | rebase | review | start). A merge also
#             carries `sha`, the head it was judged at, for
#             `tick-merge.sh <pr> <sha>` (§10, GC52).
#   board   — {<status>: count} over task and promote nodes, every status keyed.
#   waiting — [string]: why nothing more is happening (needs-human items,
#             approved PRs awaiting a human, caps, module locks, deferrals).
#
# Rules, in priority order (§5): 1 merge · 2 patch · 3 rebase · 4 review ·
# 5 promote · 6 start. Only open agent PRs (`agent`) linked to a node act; a
# node has one status, so each PR matches at most one rule (GC13). Promotion
# PRs never merge (GC39), and only task PRs are patched, rebased or reviewed:
# §9 leaves a promotion PR to a human. Parity with v0.1.4's delivery-tick
# ("needs-human items: never act on them"): a node with `needs_human`, or a PR
# labeled needs-human, produces no action, only a `waiting` line.
#
# Hardening (GC70): a merge needs the PR's base to equal the node's
# target_branch, and a task gets at most one merge per tick (the lowest PR
# number; the others wait for a human). A node with an open agent PR is never
# started, whatever its status: drift (a cleared claim, a `ready` label) must
# not spawn a duplicate implementation; reconcile rule 4 repairs the status.
#
# Usage: jq -L scripts/lib 'include "tick-plan"; tick_plan' input.json
include "node";
include "pr";
include "graph";
include "ready";

def patch_budget: 3;

def needs_human_label: "needs-human";

def _pr_ref($n): "PR #\(.number) (\($n.id))";

# Input: a PR whose linked node is $n. A merge/patch/rebase/review action, or
# a {wait} line, or empty.
def _pr_rule($n; $auto):
  _pr_ref($n) as $ref
  | "patch iteration \(.patch_iteration)/\(patch_budget)" as $iter
  | if ($n | is_open | not) then empty
    elif $n.needs_human then empty               # listed once, per node
    elif any(.labels[]; . == needs_human_label) then {wait: "\($ref) is labeled needs-human"}
    elif $n.kind == "promote" then
      {wait: "promotion \($ref) awaits a human merge (never auto-merged)"}
    elif $n.kind != "task" then empty
    elif $n.status == "approved" then
      "mergeable=\(.mergeable), checks=\(.checks)" as $state
      | if .mergeable == "conflicting" then
          if .patch_iteration < patch_budget then
            {action: "rebase", pr: .number, id: $n.id,
             reason: "approved but conflicting (\($iter))"}
          else
            {wait: "\($ref) is approved but conflicting at \($iter): needs a human rebase"}
          end
        elif .mergeable == "clean" and (.checks == "success" or .checks == "none") then
          if $auto and .base != $n.target_branch then
            {wait: "\($ref) is approved but targets \(.base), not the node's target \($n.target_branch): awaiting a human"}
          elif $auto then
            {action: "merge", pr: .number, id: $n.id, sha: .head_sha,
             reason: "approved, mergeable clean, checks \(.checks)"}
          else
            {wait: "\($ref) is approved: awaiting a human merge (\($state))"}
          end
        else
          {wait: "\($ref) is approved, not mergeable yet (\($state))"}
        end
    elif $n.status == "changes-requested" then
      {action: "patch", pr: .number, id: $n.id,
       reason: (if .patch_iteration >= patch_budget
                then "changes requested at \($iter): patch-task escalates (GC62)"
                else "changes requested (\($iter))" end)}
    elif $n.status == "in-review" then
      if .reviewed_at_head then
        {wait: "\($ref) is reviewed at head \(.head_sha[0:7]): awaiting its verdict transition"}
      else
        {action: "review", pr: .number, id: $n.id,
         reason: "in review, no verdict at head \(.head_sha[0:7])"}
      end
    else empty end;

# Input: a node. The promote action, or a {wait} line, or empty (§9, GC19).
def _promote_rule($idx):
  if .kind != "promote" or .status != "ready" or .needs_human or .claim != null then empty
  elif deps_done($idx) then
    {action: "promote", id: .id,
     reason: "every dep done: promote \(.target_branch) -> \(.promote_to // "?")"}
  else {wait: "promote \(.id) is ready but a dep is not done"} end;

# Input: the ready set (ready.jq order). Greedy start selection: at most
# $slots starts, each (target_branch, module) distinct from every lock in
# $locks and from every earlier start; no-module tasks are exempt (GC18).
def _starts($slots; $locks):
  reduce .[] as $r ({starts: [], locks: $locks, capped: 0, waits: []};
    [$r.target_branch, $r.module] as $key
    | if (.starts | length) >= $slots then .capped += 1
      elif $r.module != null and any(.locks[]; . == $key) then
        .waits += ["\($r.id) waits for module \($r.module) on \($r.target_branch)"]
      else
        .starts += [{action: "start", id: $r.id,
                     reason: "ready (module \($r.module // "none"), target \($r.target_branch))"}]
        | if $r.module != null then .locks += [$key] else . end
      end);

def _describe: if .pr != null then "\(.action) PR #\(.pr)" else "\(.action) \(.id)" end;

def tick_plan:
  . as $in
  | ($in.nodes | map(validate_node)) as $nodes
  | ($in.prs | map(validate_pr)) as $prs
  | ($in.flags // {}) as $flags
  | if ($flags.parallel | . == null or (type == "number" and . == floor)) | not then
      error("flags.parallel must be an integer or null (got \($flags.parallel | tojson))")
    elif ($flags.auto_merge | . == null or type == "boolean") | not then
      error("flags.auto_merge must be a boolean or null (got \($flags.auto_merge | tojson))")
    else . end
  | ($flags.auto_merge == true) as $auto
  | (($flags.parallel // 1) | if . > 16 then 16 else . end) as $n
  | (if $n >= 2 then {name: "parallel", n: $n} else {name: "serial", n: 1} end) as $mode
  | ($nodes | index_by_id) as $idx
  | [$prs[] | select(.state == "open" and .agent)] as $open
  | [$open[] | select(.task_id != null and $idx[.task_id] != null)
     | . as $pr | $idx[.task_id] as $node | $pr | _pr_rule($node; $auto)]
    | sort_by(.pr) as $pr_out
  | [$nodes[] | _promote_rule($idx)] as $promote_out
  # At most one merge per task (GC70): the lowest PR number merges; the rest
  # wait, and once the task is done they no longer match any rule.
  | ([$pr_out[] | select(.action == "merge")] | group_by(.id)) as $merge_groups
  | ($merge_groups | map(.[0]) | sort_by(.pr)) as $merges
  | [$merge_groups[] | .[0].pr as $first | .[1:][]
     | {wait: "PR #\(.pr) (\(.id)) is approved too, but PR #\($first) merges for the task: awaiting a human"}] as $dup_waits
  | [$promote_out[] | select(.action == "promote")] as $promotes
  | [("patch", "rebase", "review") as $a | $pr_out[] | select(.action == $a)] as $pr_agent
  # In-flight (§5 batch rules): open agent PRs, approved-unmerged included,
  # plus claimed task nodes. Their (target_branch, module) pairs hold locks.
  | [$nodes[] | select(.kind == "task" and .status == "claimed")] as $claimed
  | (($open | length) + ($claimed | length)) as $in_flight
  | ([($open[] | .task_id // empty | $idx[.] // empty), $claimed[]]
     | map(select(.module != null) | [.target_branch, .module]) | unique) as $locks
  | (if $mode.name == "serial" then 2 else $n end) as $cap
  # Never start a node with an open agent PR, whatever its status (GC70).
  | ([$open[] | .task_id // empty] | unique) as $pr_ids
  | ($nodes | ready_set
     | map(.id as $id | .open_pr = any($pr_ids[]; . == $id))) as $ready_all
  | [$ready_all[] | select(.open_pr | not) | del(.open_pr)] as $ready
  | [$ready_all[] | select(.open_pr) | .id as $id
     | "\($id) is not started: it has an open agent PR (\([$open[] | select(.task_id == $id) | "#\(.number)"] | join(", "))); reconcile repairs its status"]
    as $pr_held
  | (if $mode.name == "serial" then $ready[0:1] else $ready end) as $candidates
  | ($candidates | _starts([$cap - $in_flight, 0] | max; $locks)) as $sel
  | ($pr_agent + $sel.starts) as $agent_all
  | (if $mode.name == "serial" then $agent_all[0:1] else $agent_all[0:$n] end) as $agent
  | $agent_all[($agent | length):] as $deferred
  | [$nodes[] | select(.kind == "task" and .status == "blocked")] as $blocked
  | {
      mode: $mode,
      actions: ($merges + $promotes + $agent),
      board: (reduce ($nodes[] | select(.kind == "task" or .kind == "promote")) as $x
                (reduce node_statuses[] as $s ({}; .[$s] = 0); .[$x.status] += 1)),
      waiting: (
        [$nodes[] | select((.kind == "task" or .kind == "promote") and is_open and .needs_human)
         | "\(.id) needs-human"]
        + [$pr_out[], $promote_out[] | .wait // empty]
        + $dup_waits
        + $pr_held
        + (if $sel.capped > 0 then ["start capped: \($in_flight) in flight of cap \($cap)"] else [] end)
        + $sel.waits
        + (if ($ready | length) == 0 then ["no ready tasks"] else [] end)
        + (if ($blocked | length) > 0
           then ["\($blocked | length) task(s) blocked on deps"] else [] end)
        + (if ($deferred | length) > 0
           then ["deferred to a later tick (\($mode.name) cap \($mode.n)): \($deferred | map(_describe) | join(", "))"]
           else [] end))
    };
