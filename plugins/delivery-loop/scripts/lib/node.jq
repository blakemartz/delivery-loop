# node.jq — the normalized graph node shape (docs/delivery_graph_spec.md §4.1).
#
# Every graph backend's `list`/`show` emits nodes of exactly this shape; graph.sh
# runs validate_node on every backend output so drift fails fast instead of
# silently skewing readiness. Pure: no I/O, no clock.
#
#   node_errors   — [string]: every violation in the input node ([] when valid).
#   validate_node — the input unchanged when valid, else error(...) listing every
#                   violation (jq exits 5).
#
# Usage: jq -L scripts/lib 'include "node"; map(validate_node)' nodes.json
include "shape";

def node_fields:
  ["id", "kind", "title", "epic", "checklist", "pinged_at", "applied_prs", "module",
   "size", "deps", "status", "needs_human", "claim", "target_branch", "promote_to",
   "plan_ref", "body", "created_at", "updated_at"];

def node_kinds: ["task", "epic", "promote", "external"];

def node_sizes: ["S", "M", "L", null];

def node_statuses:
  ["blocked", "ready", "claimed", "in-review", "changes-requested", "approved",
   "done", "cancelled"];

# `deps` element: {id, via}, via a string or null (legacy edge).
def _dep_errors:
  to_entries[]
  | "`deps[\(.key)]`" as $at
  | .value
  | if type != "object" then "\($at) must be an object {id, via} (got \(tojson))"
    else
      (key_errors(["id", "via"]) | "\($at): \(.)"),
      (check("id"; is_node_id; "must be a node id") | "\($at): \(.)"),
      (check("via"; is_string_or_null; "must be a string or null") | "\($at): \(.)")
    end;

# `claim`: null, or {actor, run, at, by: "agent"|"human"}. §4.1 types only `by`.
# `run` and `at` are null when the backend has no record of them: a github human
# claim is just an assignee (no `CLAIM` comment, so no run; no assignment time in
# the read fields), and a local `--human` claim has no run. They are never
# replaced by a sentinel.
def _claim_errors:
  if . == null then empty
  elif type != "object" then "`claim` must be null or an object (got \(tojson))"
  else
    (key_errors(["actor", "run", "at", "by"]) | "`claim`: \(.)"),
    (check("actor"; is_nonempty_string; "must be a non-empty string") | "`claim`: \(.)"),
    (check("run"; . == null or is_nonempty_string; "must be a non-empty string or null") | "`claim`: \(.)"),
    (check("at"; is_iso8601_or_null; "must be an ISO-8601 timestamp or null") | "`claim`: \(.)"),
    (check("by"; is_enum(["agent", "human"]); "must be \"agent\" or \"human\"") | "`claim`: \(.)")
  end;

# `external` (§4.1): a non-delivery issue the graph references (a dep target or
# an epic child). Its labels are ignored, so every label-derived field is fixed,
# and its status comes only from the issue's own state: open -> blocked, closed
# -> done | cancelled. (`checklist` and `promote_to` are already kind-scoped
# below; `epic` is derived as for any node, so it is free.)
def external_statuses: ["blocked", "done", "cancelled"];

def _external_errors:
  "for external nodes" as $why
  | check("module"; . == null; "must be null \($why)"),
    check("size"; . == null; "must be null \($why)"),
    check("claim"; . == null; "must be null \($why)"),
    check("pinged_at"; . == null; "must be null \($why)"),
    check("plan_ref"; . == null; "must be null \($why)"),
    check("deps"; . == []; "must be [] \($why)"),
    check("needs_human"; . == false; "must be false \($why)"),
    check("status"; is_enum(external_statuses);
          "must be one of \(external_statuses | join("|")) \($why)");

def node_errors:
  if type != "object" then ["node must be an object (got \(type))"]
  else [
    key_errors(node_fields),
    check("id"; is_node_id; "must match ^[a-z0-9]+(-[a-z0-9]+)*$, at most 40 chars"),
    check("kind"; is_enum(node_kinds); "must be one of \(node_kinds | join("|"))"),
    check("title"; type == "string"; "must be a string"),
    check("epic"; . == null or is_node_id; "must be a node id or null"),
    check("checklist"; type == "array" and all(.[]; is_node_id); "must be an array of node ids"),
    check("pinged_at"; is_iso8601_or_null; "must be an ISO-8601 timestamp or null"),
    # PR numbers whose merge reconcile rule 3 already applied (§4.1, §5): an
    # external node keeps it free, since rule 3 never acts on one.
    check("applied_prs"; type == "array" and all(.[]; is_int and . > 0);
          "must be an array of positive integers (PR numbers)"),
    # Bare name: adapters strip the `module:` label prefix (a bare `module:`
    # label maps to null).
    check("module"; . == null or (is_nonempty_string and (startswith("module:") | not));
          "must be a bare module name (no `module:` prefix) or null"),
    check("size"; is_enum(node_sizes); "must be S|M|L or null"),
    check("deps"; type == "array"; "must be an array"),
    (if (.deps | type) == "array" then .deps | _dep_errors else empty end),
    check("status"; is_enum(node_statuses); "must be one of \(node_statuses | join("|"))"),
    check("needs_human"; is_bool; "must be a boolean"),
    (if has("claim") then .claim | _claim_errors else empty end),
    check("target_branch"; is_nonempty_string; "must be a non-empty string"),
    check("promote_to"; is_string_or_null; "must be a string or null"),
    check("plan_ref"; . == null or (type == "string" and test("^[^/]+/[^/]+$"));
          "must be `<plan>/<plan-task-id>` or null"),
    check("body"; type == "string"; "must be a string"),
    check("created_at"; is_iso8601; "must be an ISO-8601 timestamp"),
    check("updated_at"; is_iso8601; "must be an ISO-8601 timestamp"),
    # Kind-scoped fields (§4.1): only epics carry a checklist, only promote
    # nodes carry promote_to.
    (if .kind != "epic" and (.checklist | type) == "array" and (.checklist | length) > 0
     then "`checklist` is for epic nodes only (kind \(.kind | tojson))" else empty end),
    (if .kind != "promote" and .promote_to != null
     then "`promote_to` is for promote nodes only (kind \(.kind | tojson))" else empty end),
    (if .kind == "external" then _external_errors else empty end)
  ] end;

def validate_node:
  raise_if_errors("node \(if type == "object" then .id | tojson else "" end)"; node_errors);
