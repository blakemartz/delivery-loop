# expand.jq — fills sparse reconcile fixtures out to the full §4.1 node and
# §4.2 PR shapes, so each fixture states only the fields its case is about.
#   full_node  — defaults: an unclaimed, ready, size-S task on `main`, updated
#                1h before `now` (so no claim is stale unless the fixture says
#                so); `deps` may be bare ids.
#   full_pr    — defaults: an open agent PR into `main`; `agent` always follows
#                `labels` (default ["agent-authored"]).
#   full_input — {nodes, prs, now?} → the reconcile input; now defaults to
#                2027-01-01T00:00:00Z.
def fixture_now: 1798761600;

def full_node:
  {kind: "task", title: "Task \(.id)", epic: null, checklist: [], pinged_at: null,
   module: null, size: "S", deps: [], status: "ready", needs_human: false,
   claim: null, target_branch: "main", promote_to: null, plan_ref: null,
   body: "", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-12-31T23:00:00Z"}
  + .
  | .deps |= map(if type == "string" then {id: ., via: null} else . end);

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
   now: (.now // fixture_now)};
