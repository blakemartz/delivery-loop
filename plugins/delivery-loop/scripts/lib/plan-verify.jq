# plan-verify.jq — composed-artifact validation for `plan.sh apply`
# (docs/delivery_graph_spec.md §8.3): before any write, every node apply would
# create is rendered exactly as the backend's create writes it and read back
# with that backend's own reader; any difference from the plan's intent is a
# refusal (exit 1, nothing written).
#
# Lint (plan-lint.jq plan_text_markers) checks each plan string on its own, a
# fast first pass. It cannot see what composing does (`spec` + `spec_refs` are
# joined into one `Spec:` line; criteria and scope become list items) nor
# every form a reader accepts (`**Depends-on**:`). This check reads the text
# that is actually written, so it closes the class rather than one input shape.
#
# Pure: no I/O. Needs `-L lib -L backends` (it reuses graph-github.jq's writer
# and readers; it copies neither).
#
#   plan_verify_github($ctx) — input: plan_apply's output ({steps}). $ctx:
#       {base: BASE_BRANCH, nodes: `graph.sh list`}. For each node to create,
#       in both create forms (native relations, and gh < 2.94 text edges), the
#       body gh_create_body writes is read back through gh_node (deps with
#       via, epic, checklist, target_branch, plan_ref, promote_to) and, in the
#       native form, gh_migrate_plan (which must plan nothing: plan text never
#       becomes a migrate link or parent). Issue numbers are not known before
#       create, so the nodes to create get synthetic numbers, under two
#       disjoint numberings: a literal `#N` in plan text can equal a planned
#       node's number under at most one of them, so no injected edge can pass
#       as a planned one. Each node to create must also pass create's own
#       input check, gh_create_errors (the function create runs), so a node
#       create would refuse is refused here, before any write (those errors
#       alone when any, as the read-back needs well-formed nodes). Output: [error
#       strings], one per node and field.
#   plan_verify_local($ctx; create) — the same for the local backend: create
#       is the backend's own create normalizer (graph-local.sh GL_CREATE),
#       called as `{node, all} | create` with all = the nodes stored so far;
#       every node it builds must pass validate_node and carry the plan's
#       metadata. A node create would refuse is an error here, before any
#       write, instead of a half-applied plan.
#
# Usage (plan.sh): jq -L lib -L backends --argjson ctx "$ctx" \
#   'include "plan-verify"; plan_verify_github($ctx)' apply.json

include "plan-apply";
include "graph-github";
include "node";

# The metadata a reader must give back, from a resolved create template.
def _pv_want:
  { deps: ([ (.deps // [])[] | {id: (.id | tostring), via} ] | unique),
    epic: (if .epic == null then null else .epic | tostring end),
    checklist: [],
    target_branch,
    plan_ref,
    promote_to: (if .kind == "promote" then .promote_to else null end) };

# The same fields of a node as read (§4.1).
def _pv_have:
  { deps: ([ .deps[] | {id: (.id | tostring), via} ] | unique),
    epic, checklist, target_branch, plan_ref, promote_to };

def _pv_fields: ["deps", "epic", "checklist", "target_branch", "plan_ref", "promote_to", "migrate"];

# A node id in plan terms: a plan id for a node apply creates, else `#N` (an
# issue number) or the id itself (local).
def _pv_name($back):
  if . == null then "none" else ($back[.] // (if test("^[0-9]+$") then "#\(.)" else . end)) end;

def _pv_show($field; $back):
  if $field == "deps" then
    "[" + (map((.id | _pv_name($back)) + (if .via != null then " (via: \(.via))" else "" end)) | join(", ")) + "]"
  elif $field == "epic" then _pv_name($back)
  elif $field == "checklist" then "[" + (map(_pv_name($back)) | join(", ")) + "]"
  elif $field == "migrate" then
    if . == [] then "nothing"
    else map((.warnings // []) + [ (.links // [])[] | "link #\(.)" ]
             + (if .parent != null then ["parent #\(.parent)"] else [] end) | join("; ")) | join("; ")
         | gsub("#(?<n>[0-9]+)"; .n | _pv_name($back)) end
  else tojson end;

def _pv_messages($what):
  reduce .[] as $e ([]; if any(.[]; .pid == $e.pid and .field == $e.field) then . else . + [$e] end)
  | map("`\(.pid)`: \($what) reads back \(.field) \(.got), not the plan's \(.want) (\(.form)): plan text carries a line the reader parses as node metadata; reword it");

def plan_verify_github($ctx):
  .steps as $steps
  | ([ $steps[] | select(.exists) | {key: .pid, value: .id} ] | from_entries) as $found
  | [ $steps[] | select(.exists | not) | .pid ] as $new
  | ([ ($ctx.nodes // [])[] | .id | select(test("^[0-9]+$")) | tonumber ] | max // 0) as $hi
  | ($found + ($new | to_entries | map({key: .value, value: ($hi + 1 + .key | tostring)}) | from_entries)) as $map0
  # create's own input check first (gh_create_errors, the function create
  # runs; any issue number passes it): a node create would refuse is an error
  # here, before any write, instead of a half-applied plan. The read-back
  # below runs only on nodes create accepts (well-formed by then).
  | [ $steps[] | select(.exists | not) | .pid as $pid
      | (.node | plan_apply_resolve($map0)) | gh_create_errors($ctx.base)[]
      | "`\($pid)`: the github backend's create would refuse this node (\(.)): nothing written" ]
  | if . != [] then .
    else [ ($hi + 1000000, $hi + 2000000 + ($new | length)) as $off
      | ($found + ($new | to_entries | map({key: .value, value: ($off + .key | tostring)}) | from_entries)) as $map
      | ($new | map({key: $map[.], value: .}) | from_entries) as $back
      | $steps[] | select(.exists | not) | .pid as $pid
      | (.node | plan_apply_resolve($map)) as $n
      | ($n | _pv_want + {migrate: []}) as $want
      | (1, 0) as $native
      | ($n | gh_create_body($native; $ctx.base)) as $body
      | { number: ($map[$pid] | tonumber), title: $n.title, state: "OPEN", stateReason: "",
          labels: [{name: $n.kind}], assignees: [], comments: [], body: $body,
          createdAt: null, updatedAt: null,
          parent: (if $native == 1 and $n.epic != null then {number: ($n.epic | tonumber)} else null end),
          blockedBy: (if $native == 1
                      then {nodes: [ ($n.deps // [])[] | {number: (.id | tonumber)} ], totalCount: (($n.deps // []) | length)}
                      else null end) } as $issue
      | ($issue | gh_node($ctx.base) | _pv_have
         + {migrate: (if $native == 1 then [$issue] | gh_migrate_plan else [] end)}) as $have
      | _pv_fields[] as $f
      | select($have[$f] != $want[$f])
      | {pid: $pid, field: $f,
         form: (if $native == 1 then "native relations" else "gh < 2.94 text edges" end),
         got: ($have[$f] | _pv_show($f; $back)), want: ($want[$f] | _pv_show($f; $back))} ]
  | _pv_messages("the github issue body apply would write")
  end;

def plan_verify_local($ctx; create):
  .steps as $steps
  | ([ $steps[] | select(.exists) | {key: .pid, value: .id} ] | from_entries
     + ([ $steps[] | select(.exists | not) | {key: .pid, value: .pid} ] | from_entries)) as $map
  | reduce ($steps[] | select(.exists | not)) as $s ({all: ($ctx.nodes // []), errors: [], bad: []};
      ($s.node | plan_apply_resolve($map)) as $n
      | (try {node: ({node: $n, all: .all} | create
                     | . + {pinged_at: null, applied_prs: []} | validate_node)}
         catch {error: .}) as $r
      | if $r.error != null then
          .errors += ["`\($s.pid)`: the local backend's create would refuse this node (\($r.error | tostring)): nothing written"]
        else
          .all += [$r.node]
          | ($n | _pv_want + {migrate: []}) as $want
          | ($r.node | _pv_have + {migrate: []}) as $have
          | .bad += [ _pv_fields[] as $f | select($have[$f] != $want[$f])
                      | {pid: $s.pid, field: $f, form: "local store",
                         got: ($have[$f] | _pv_show($f; {})), want: ($want[$f] | _pv_show($f; {}))} ]
        end)
  | .errors + (.bad | _pv_messages("the local node apply would store"));
