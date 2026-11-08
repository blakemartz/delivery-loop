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
  ["id", "kind", "title", "epic", "checklist", "pinged_at", "module", "size",
   "deps", "status", "needs_human", "claim", "target_branch", "promote_to",
   "plan_ref", "body", "created_at", "updated_at"];

def node_kinds: ["task", "epic", "promote"];

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

# `claim`: null, or {actor, run, at, by: "agent"|"human"}.
def _claim_errors:
  if . == null then empty
  elif type != "object" then "`claim` must be null or an object (got \(tojson))"
  else
    (key_errors(["actor", "run", "at", "by"]) | "`claim`: \(.)"),
    (check("actor"; is_nonempty_string; "must be a non-empty string") | "`claim`: \(.)"),
    (check("run"; is_nonempty_string; "must be a non-empty string") | "`claim`: \(.)"),
    (check("at"; is_iso8601; "must be an ISO-8601 timestamp") | "`claim`: \(.)"),
    (check("by"; is_enum(["agent", "human"]); "must be \"agent\" or \"human\"") | "`claim`: \(.)")
  end;

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
     then "`promote_to` is for promote nodes only (kind \(.kind | tojson))" else empty end)
  ] end;

def validate_node:
  raise_if_errors("node \(if type == "object" then .id | tojson else "" end)"; node_errors);
