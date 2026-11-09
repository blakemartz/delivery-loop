# plan-lint.jq — lint and normalize one plan file
# (docs/delivery_graph_spec.md §8.1 schema, §8.2 lint).
#
# Pure: no I/O, no clock. plan.sh gathers everything that needs I/O (the
# existing node ids, the other plans in PLANS_DIR, MODULES) into $ctx.
#
#   plan_dep_id($backend)       — normalize one raw dep id: on the github
#                                 backend "#42" names existing issue 42 → "42".
#   plan_external_deps($backend) — the (normalized) dep ids that are not tasks
#                                 of this plan, so must be existing nodes.
#                                 Tolerant of any input, so plan.sh can decide
#                                 whether to read the graph before linting.
#   plan_lint($ctx)             — {errors, warnings, plan}. `plan` is the
#                                 normalized plan when there are no errors,
#                                 else null.
#
# $ctx:
#   backend      GRAPH_BACKEND (github | local).
#   base_branch  BASE_BRANCH: the default target_branch (§4.1, §9).
#   modules      MODULES as an array; infra and docs are always allowed.
#   nodes        existing node ids (`graph.sh list`), or null to skip
#                existing-node resolution (render needs structure only).
#   others       the other plans in PLANS_DIR, as
#                [{file, plan, target_branch, promote_to}] (raw values): a
#                shared target_branch must agree on promote_to, and a shared
#                plan id is an error (plan_ref keys would collide, §8.3).
#
# Beyond §8.2, whitespace-only titles, vias and criteria count as empty, and a
# task's duplicate deps (same resolved id: "#42" and "42" on github) are a
# warning; normalization keeps the first. Plan text that becomes node body text
# (context, criteria, scope, epic goal and spec_refs, the plan's spec, a dep's
# via) must carry no line a backend reads back as a marker (plan_text_markers),
# on every backend, so a plan stays portable.
# Titles are not checked: no reader parses an issue title.
#
# Normalized plan: target_branch defaulted to base_branch, promote_to to null,
# optional fields filled (goal "", spec_refs [], spec [], deps [], context "",
# scope []), and each dep as {id, via, ref} where ref is "task" (a task of this
# plan) or "node" (an existing node; "#42" → id "42"), deduplicated.
#
# Usage: jq -L scripts/lib --argjson ctx "$ctx" 'include "plan-lint"; plan_lint($ctx)' plan.json

include "shape";
include "graph";

def _id_rule: "^[a-z0-9]+(-[a-z0-9]+)*$, at most 40 chars, no `--`";

def _is_existing_ref($backend):
  type == "string" and $backend == "github" and test("^#[0-9]+$");

def plan_dep_id($backend):
  if _is_existing_ref($backend) then .[1:] else . end;

def _objs: if type == "array" then map(select(type == "object")) else [] end;

def _has_str($s): any(.[]; . == $s);

# A string with at least one non-whitespace character (a whitespace-only `via`,
# criterion or title says nothing; `test("\\S")` avoids Oniguruma's per-line
# `^`/`$`).
def _is_text: type == "string" and test("\\S");

# plan_text_markers — input: one plan text string (a context, criterion, scope
# entry, epic goal, spec ref or via). Output: each marker some line of it
# carries that a backend reads back from node text, so text written into a
# github issue body would rewrite the node: steal its plan_ref (a duplicate on
# every re-apply), retarget it, or add an edge. Derived from what the readers
# match:
#   backends/graph-github.jq  _trailer: a line starting `Delivery-Target:`,
#                             `Delivery-Plan:`, `Delivery-Promote-To:` (the
#                             first such line wins over the appended trailer);
#                             _text_edges: every `#N` on any line containing
#                             `Depends-on:`; gh_epic: `[Ee]pic #N` anywhere in
#                             the body (so `Part of epic #N` too); gh_checklist:
#                             a `- [ ] #N` / `* [x] #N` line (an epic's members).
#   backends/forge-github.jq  `Delivery-Task:` and `Reviewed-Head:` lines.
#   the comment ledger        (lib/claim-ledger.jq, graph-github.jq comments,
#                             reconcile.jq, graph-github.sh transition) `CLAIM`,
#                             `CLAIM-WITHDRAWN`, `RECLAIMED`, `STALE-CLAIM-PING`,
#                             `AUTO-CLOSE:`, `TRANSITIONED:`: read from comments
#                             only today, refused anyway so plan text never
#                             reads as a protocol record wherever it is copied.
# Start-anchored markers also match after leading whitespace (stricter than
# the readers, never looser). Lines are split first: Oniguruma `^` does not
# reliably anchor at line boundaries.
def plan_text_markers:
  ( split("\n")[] | rtrimstr("\r") ) as $l
  | ( ($l | capture("^[ \t]*(?<m>Delivery-Target|Delivery-Plan|Delivery-Promote-To|Delivery-Task|Reviewed-Head|AUTO-CLOSE|TRANSITIONED)[ \t]*:") | "\(.m):"),
      ($l | capture("^[ \t]*(?<m>CLAIM-WITHDRAWN|CLAIM|RECLAIMED|STALE-CLAIM-PING)([ \t:]|$)") | .m),
      ($l | select(test("Depends-on[ \t]*:")) | "Depends-on:"),
      ($l | capture("(?<m>[Ee]pic #[0-9]+)") | .m),
      ($l | select(test("^[ \t]*[-*] \\[[ xX]\\][ \t]*#[0-9]+")) | "- [ ] #N") );

# Error strings for the markers in one field's text: a string, or an array
# whose string entries are checked one by one (other types are reported by the
# field's own type check).
def _marker_errors($w; $field):
  def msg($f): "\($w): \($f) carries `\(.)`, which the github backend would read back from the issue body as node metadata or a protocol record (stealing the plan_ref, retargeting the node or adding an edge): reword it";
  if type == "string" then [plan_text_markers] | unique[] | msg($field)
  elif type == "array" then
    to_entries[] | select(.value | type == "string") | .key as $k
    | [.value | plan_text_markers] | unique[] | msg("\($field)[\($k)]")
  else empty end;

def plan_external_deps($backend):
  (if type == "object" then . else {} end) as $p
  | [$p.tasks | _objs[] | .id | strings] as $tids
  | [ $p.tasks | _objs[] | .deps | _objs[] | .id | strings
      | . as $raw
      | plan_dep_id($backend) as $id
      | select(($raw | _is_existing_ref($backend)) or ($tids | _has_str($id) | not))
      | $id ]
  | unique;

# Error strings for an object with required and optional keys.
def _field_errors($what; $required; $optional):
  (($required - keys)[] | "\($what): missing field `\(.)`"),
  ((keys - $required - $optional)[] | "\($what): unexpected field `\(.)`");

# _typed($what; $name; cond; $msg): shape.jq `check`, prefixed with $what.
def _typed($what; $name; cond; $msg): check($name; cond; $msg) | "\($what): \(.)";

def _malformed($what; $label):
  if has("id") and (.id | is_node_id | not)
  then "\($what): malformed \($label) \(.id | tojson) (want \(_id_rule))"
  else empty end;

def _where($kind; $i):
  if (.id | type) == "string" then "\($kind) `\(.id)`" else "\($kind)s[\($i)]" end;

def _epic_errors:
  to_entries[] | .key as $i | .value
  | if type != "object" then "epics[\($i)]: must be an object (got \(type))"
    else _where("epic"; $i) as $w
      | _field_errors($w; ["id", "title"]; ["goal", "spec_refs"]),
        _malformed($w; "id"),
        _typed($w; "title"; _is_text; "must be a non-empty string"),
        _typed($w; "goal"; type == "string"; "must be a string"),
        _typed($w; "spec_refs"; is_string_array; "must be an array of strings"),
        (.goal | _marker_errors($w; "goal")),
        (.spec_refs | _marker_errors($w; "spec_refs"))
    end;

def _dep_errors($w; $backend; $tids; $eids; $nodes):
  to_entries[] | .key as $j | .value
  | if type != "object" then "\($w): deps[\($j)] must be an object {id, via} (got \(type))"
    elif (.id | type) != "string" then
      if has("id") then "\($w): deps[\($j)]: `id` must be a string (got \(.id | tojson))"
      else "\($w): deps[\($j)]: missing field `id`" end
    else
      .id as $raw
      | ($raw | plan_dep_id($backend)) as $id
      | "\($w): dep `\($raw)`" as $d
      | ((keys - ["id", "via"])[] | "\($d): unexpected field `\(.)`"),
        (if (.via == null) or ((.via | type) == "string" and (.via | _is_text | not))
         then "\($d) has no `via` (plan deps require one; a whitespace-only via counts as none)"
         elif (.via | type) != "string" then "\($d): `via` must be a string (got \(.via | tojson))"
         else .via | _marker_errors($d; "via") end),
        (if ($id | is_node_id | not) then "\($d): malformed dep id (want \(_id_rule)\(if $backend == "github" then ", or #N" else "" end))"
         elif ($raw | _is_existing_ref($backend)) then
           (if $nodes != null and ($nodes | _has_str($id) | not)
            then "\($d): unresolved dep: no existing node \($id)" else empty end)
         elif ($tids | _has_str($id)) then empty
         elif ($eids | _has_str($id)) then "\($d): unresolved dep: names an epic; deps name tasks or existing nodes"
         elif $nodes == null or ($nodes | _has_str($id)) then empty
         else "\($d): unresolved dep: not a task in this plan or an existing node" end)
    end;

def _task_errors($backend; $modules; $tids; $eids; $nodes):
  to_entries[] | .key as $i | .value
  | if type != "object" then "tasks[\($i)]: must be an object (got \(type))"
    else _where("task"; $i) as $w
      | _field_errors($w; ["id", "epic", "title", "module", "size", "criteria"];
                          ["deps", "context", "scope"]),
        _malformed($w; "id"),
        _typed($w; "title"; _is_text; "must be a non-empty string"),
        _typed($w; "context"; type == "string"; "must be a string"),
        _typed($w; "scope"; is_string_array; "must be an array of strings"),
        (.context | _marker_errors($w; "context")),
        (.criteria | _marker_errors($w; "criteria")),
        (.scope | _marker_errors($w; "scope")),
        (if has("epic") then
           if (.epic | type) != "string" then "\($w): `epic` must be a string (got \(.epic | tojson))"
           elif (.epic as $e | $eids | _has_str($e) | not) then "\($w): epic `\(.epic)` is not an epic in this plan"
           else empty end
         else empty end),
        (if has("module") then
           if (.module | type) != "string" then "\($w): `module` must be a string (got \(.module | tojson))"
           elif (.module as $m | $modules | _has_str($m) | not) then
             "\($w): module `\(.module)` is not in MODULES ∪ {infra, docs} (allowed: \($modules | join(" ")))"
           else empty end
         else empty end),
        (if has("size") and (.size | is_enum(["S", "M", "L"]) | not)
         then "\($w): size \(.size | tojson) is not S/M/L" else empty end),
        (if has("criteria") then
           if (.criteria | type) != "array" then "\($w): `criteria` must be an array of strings (got \(.criteria | tojson))"
           elif (.criteria | length) == 0 then "\($w): `criteria` is empty"
           elif (.criteria | all(.[]; _is_text) | not) then "\($w): `criteria` must hold non-empty strings (not whitespace-only)"
           else empty end
         else empty end),
        (if has("deps") then
           if (.deps | type) != "array" then "\($w): `deps` must be an array (got \(.deps | tojson))"
           else .deps | _dep_errors($w; $backend; $tids; $eids; $nodes) end
         else empty end)
    end;

def plan_lint($ctx):
  ($ctx.backend // "github") as $backend
  | (($ctx.modules // []) + ["infra", "docs"] | unique) as $modules
  | ($ctx.nodes) as $nodes
  | if type != "object" then {errors: ["plan: must be a JSON object (got \(type))"], warnings: [], plan: null}
    else
      . as $p
      | ($p.epics | _objs) as $epics
      | ($p.tasks | _objs) as $tasks
      | [$epics[].id | strings] as $eids
      | [$tasks[].id | strings] as $tids
      | ($p.target_branch // $ctx.base_branch) as $target
      | ($p.promote_to // null) as $promote
      # the task graph inside this plan, for cycle detection (graph.jq `cycle_text`)
      | [ $tasks[] | select(.id | type == "string")
          | {id, deps: [.deps | _objs[] | .id | strings
                        | select(_is_existing_ref($backend) | not)
                        | select(. as $d | $tids | _has_str($d)) | {id: .}]} ]
        as $graph
      | [ _field_errors("plan"; ["schema", "plan", "epics", "tasks"];
                                ["spec", "target_branch", "promote_to"]),
          _typed("plan"; "schema"; . == 1; "must be 1"),
          (if has("plan") and (.plan | is_node_id | not)
           then "plan: malformed plan id \(.plan | tojson) (want \(_id_rule))" else empty end),
          _typed("plan"; "spec"; is_string_array; "must be an array of strings"),
          (.spec | _marker_errors("plan"; "spec")),
          _typed("plan"; "target_branch"; is_nonempty_string; "must be a non-empty string"),
          _typed("plan"; "promote_to"; . == null or is_nonempty_string; "must be a non-empty string or null"),
          (if $promote != null and $promote == $target
           then "plan: promote_to must differ from target_branch (both `\($target)`)" else empty end),
          _typed("plan"; "epics"; type == "array"; "must be an array"),
          _typed("plan"; "tasks"; type == "array" and length > 0; "must be a non-empty array"),
          (if (.epics | type) == "array" then .epics | _epic_errors else empty end),
          (if (.tasks | type) == "array"
           then .tasks | _task_errors($backend; $modules; $tids; $eids; $nodes) else empty end),
          ($eids + $tids | group_by(.)[] | select(length > 1)
           | "plan: duplicate id `\(.[0])` (epic and task ids share one namespace)"),
          ($graph | cycle_text(" -> ") | "plan: cycle: \(.)"),
          ($ctx.others // [] | .[]
           | select((.target_branch // $ctx.base_branch) == $target
                    and (.promote_to // null) != $promote)
           | "plan: target_branch `\($target)` has promote_to \($promote | tojson) here but \(.promote_to // null | tojson) in \(.file)"),
          ($ctx.others // [] | .[]
           | select(.plan != null and .plan == $p.plan)
           | "plan: plan id `\($p.plan)` is also the plan id of \(.file) (plan_ref idempotency keys would collide)")
        ] as $errors
      | ( [ $tasks[] | select(.size == "L")
          | "\(.id // "?" | if type == "string" then "task `\(.)`" else "task" end): size L is a placeholder: split it before it can be claimed" ]
        + [ $tasks[] | select(.id | type == "string") | .id as $tid
            | [.deps | _objs[] | .id | strings
               | {id: plan_dep_id($backend),
                  task: ((_is_existing_ref($backend) | not) and (plan_dep_id($backend) as $i | $tids | _has_str($i)))}]
            | group_by(.)[] | select(length > 1)
            | "task `\($tid)`: duplicate dep `\(.[0].id)` (kept the first)" ] )
        as $warnings
      | { errors: $errors,
          warnings: $warnings,
          plan: (if $errors != [] then null
                 else {
                   schema: 1,
                   plan: $p.plan,
                   spec: ($p.spec // []),
                   target_branch: $target,
                   promote_to: $promote,
                   epics: [$epics[] | {id, title, goal: (.goal // ""), spec_refs: (.spec_refs // [])}],
                   tasks: [ $tasks[]
                     | {id, epic, title, module, size,
                        deps: ([ .deps // [] | .[]
                                | (.id | _is_existing_ref($backend)) as $ext
                                | (.id | plan_dep_id($backend)) as $id
                                | {id: $id, via,
                                   ref: (if ($ext | not) and ($tids | _has_str($id)) then "task" else "node" end)} ]
                              | reduce .[] as $d ([]; if any(.[]; .id == $d.id and .ref == $d.ref) then . else . + [$d] end)),
                        context: (.context // ""),
                        criteria,
                        scope: (.scope // [])} ]
                 } end) }
    end;
