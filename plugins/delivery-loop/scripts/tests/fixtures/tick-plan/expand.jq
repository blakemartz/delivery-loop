# expand.jq — fills sparse tick-plan fixtures out to the full §4.1 node and §4.2
# PR shapes, so each fixture states only the fields its case is about.
#   full_node  — defaults: an unclaimed, ready, size-S task on `main`; `deps`
#                may be bare ids. A node in a claimed-or-later open status gets
#                an agent claim unless the fixture gives one, as on a real
#                board (the claimant stays assigned through review).
#   full_pr    — defaults: an open agent PR into `main`, clean, checks success;
#                `agent` always follows `labels` (default ["agent-authored"]).
#   full_input — {flags, nodes, prs} → the tick_plan input.
def full_node:
  {kind: "task", title: "Task \(.id)", epic: null, checklist: [], pinged_at: null,
   applied_prs: [], module: null, size: "S", deps: [], status: "ready", needs_human: false,
   claim: null, target_branch: "main", promote_to: null, plan_ref: null,
   body: "", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"}
  + .
  | .deps |= map(if type == "string" then {id: ., via: null} else . end)
  | .status as $s
  | if .claim == null
       and any(["claimed", "in-review", "changes-requested", "approved"][]; . == $s)
    then .claim = {actor: "agent-1", run: "run-1", at: "2026-01-01T00:00:00Z", by: "agent"}
    else . end;

def full_pr:
  {url: "https://forge.example/pr/\(.number)", state: "open",
   head: "task/\(.task_id // "x")--branch", base: "main",
   head_sha: "abcdef0123456789abcdef0123456789abcdef01",
   mergeable: "clean", checks: "success", task_id: null,
   labels: ["agent-authored"], patch_iteration: 0, reviewed_at_head: false,
   author: "agent"}
  + .
  | .agent = any(.labels[]; . == "agent-authored");

def full_input:
  {nodes: ((.nodes // []) | map(full_node)), prs: ((.prs // []) | map(full_pr)),
   flags: (.flags // {}), now: 1798761600};
