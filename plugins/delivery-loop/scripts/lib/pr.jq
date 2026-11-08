# pr.jq — the normalized pull-request shape (docs/delivery_graph_spec.md §4.2).
#
# Every forge adapter's `pr-view`/`pr-list` emits PRs of exactly this shape, so
# tick-plan and reconcile never see forge-specific fields. Pure: no I/O.
#
#   pr_errors   — [string]: every violation in the input PR ([] when valid).
#   validate_pr — the input unchanged when valid, else error(...) listing every
#                 violation (jq exits 5).
#
# Usage: jq -L scripts/lib 'include "pr"; map(validate_pr)' prs.json
include "shape";

def pr_fields:
  ["number", "url", "state", "head", "base", "head_sha", "mergeable", "checks",
   "task_id", "labels", "patch_iteration", "reviewed_at_head", "agent", "author"];

def pr_states: ["open", "merged", "closed"];

def pr_mergeables: ["clean", "conflicting", "blocked", "unknown"];

def pr_checks: ["success", "pending", "failure", "none"];

# The label that makes a PR an agent PR (design spec §5.2); `agent` mirrors it.
def agent_label: "agent-authored";

def pr_errors:
  if type != "object" then ["PR must be an object (got \(type))"]
  else [
    key_errors(pr_fields),
    check("number"; is_int and . > 0; "must be a positive integer (GitLab iid, not id)"),
    check("url"; is_nonempty_string; "must be a non-empty string"),
    check("state"; is_enum(pr_states); "must be one of \(pr_states | join("|"))"),
    check("head"; is_nonempty_string; "must be a non-empty branch name"),
    check("base"; is_nonempty_string; "must be a non-empty branch name"),
    check("head_sha"; is_nonempty_string; "must be a non-empty string"),
    check("mergeable"; is_enum(pr_mergeables); "must be one of \(pr_mergeables | join("|"))"),
    check("checks"; is_enum(pr_checks); "must be one of \(pr_checks | join("|"))"),
    check("task_id"; . == null or is_nonempty_string; "must be a non-empty string or null"),
    check("labels"; is_string_array; "must be an array of strings"),
    check("patch_iteration"; is_int and . >= 0; "must be a non-negative integer"),
    check("reviewed_at_head"; is_bool; "must be a boolean"),
    check("agent"; is_bool; "must be a boolean"),
    check("author"; type == "string"; "must be a string"),
    (if (.agent | type) == "boolean" and (.labels | is_string_array)
        and .agent != (.labels | any(.[]; . == agent_label))
     then "`agent` must equal whether `labels` contains \"\(agent_label)\"" else empty end)
  ] end;

def validate_pr:
  raise_if_errors("PR \(if type == "object" then .number | tojson else "" end)"; pr_errors);
