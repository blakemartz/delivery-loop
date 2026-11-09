# plan-apply.jq — what `plan.sh apply` creates, and what it only reports
# (docs/delivery_graph_spec.md §8.3 apply, §9 the promote node, §4.1 fields).
#
# Pure: no I/O, no clock. plan.sh runs lint first (plan-lint.jq), so the input
# here is always a normalized plan (`plan_lint(...).plan`): ids valid, deps
# resolved, deduplicated and acyclic.
#
#   plan_promote_id      — the promote node's plan id: "<plan>-promote".
#   plan_body_core       — a node body without the trailer lines a backend
#                          appends (`Delivery-Target:`, `Delivery-Plan:`,
#                          `Delivery-Promote-To:`, `Depends-on:`, `Part of epic
#                          #N`) and without trailing whitespace: the part drift
#                          compares, so a github body (contract + trailers)
#                          equals the contract the plan renders.
#   plan_apply($ctx)     — {errors, drift, steps}:
#     errors  refusals found before anything is written (exit 1, nothing
#             created): a plan_ref on more than one node, an existing node of
#             another kind, (local) an id that already exists under another
#             plan_ref (ids stay unique across plans, GC35), a promote id that
#             collides or is not a valid local id, a multi-line title (github
#             create refuses one, which would strand a half-applied plan), more
#             than 50 blockers on one github issue (§6.2).
#     drift   [{id, field}] for each existing node whose field differs from the
#             plan (title, body, epic, module, size, deps, target_branch,
#             promote_to). Reported, never overwritten (GC54).
#     steps   in creation order (epics, tasks topologically, then the promote
#             node, §8.3), one per plan item: {pid, kind, plan_ref, exists,
#             id (the existing node's id, else null), node (the create
#             template, null when it exists)}. A template's `epic` and task-
#             or epic-ref deps still name plan ids; plan_apply_resolve maps them.
#   plan_apply_resolve($map) — input: a create template; $map: {plan id: node
#             id} of every item created or found so far. Output: the node-json
#             for `graph.sh create`. Errors if a referenced item has no id yet.
#
# $ctx:
#   backend      GRAPH_BACKEND (github | local).
#   nodes        every existing node (`graph.sh list`), full §4.1 objects.
#
# Node ids: on local, plan-applied nodes use their plan id (§6.3), so the
# template carries `id`; on github the backend numbers issues, so it does not.
# The plan_ref (`<plan>/<plan id>`) is the idempotency key on both (§8.3).
#
# Usage: jq -L scripts/lib --argjson ctx "$ctx" 'include "plan-apply"; plan_apply($ctx)' normalized.json

include "shape";

def plan_promote_id: "\(.plan)-promote";

def _rtrim: if length > 0 and (.[-1:] | test("[ \t\r\n]")) then .[:-1] | _rtrim else . end;

def plan_body_core:
  (. // "") | split("\n") | map(rtrimstr("\r"))
  | map(select((test("^(Delivery-Target|Delivery-Plan|Delivery-Promote-To|Depends-on):")
                or test("^Part of epic #[0-9]+")) | not))
  | join("\n") | _rtrim;

def _has_str($s): any(.[]; . == $s);

# A criterion or scope entry as one markdown list item: continuation lines are
# indented so a multi-line string stays inside its item.
def _item: gsub("\r?\n"; "\n  ");

def _task_body:
  [ (if .context != "" then "## Context", "", .context, "" else empty end),
    "## Acceptance criteria",
    (.criteria[] | "- [ ] \(_item)"),
    (if .scope != [] then "", "## Scope", (.scope[] | "- \(_item)") else empty end) ]
  | join("\n");

def _epic_body($spec):
  ([$spec[]] + [.spec_refs[]]) as $refs
  | [ (if .goal != "" then .goal else empty end),
      (if $refs != [] then (if .goal != "" then "" else empty end), "Spec: \($refs | join(", "))" else empty end) ]
  | join("\n");

def _promote_body($p):
  "Promotion of plan `\($p.plan)`: when every epic of the plan is done, the tick promotes `\($p.target_branch)` into `\($p.promote_to)` (a promotion PR a human merges)."
  + "\n\nCreated by `plan.sh apply`. Never claimed by `next-task`.";

# Kahn's algorithm, stable in plan order: a task comes after every plan task it
# depends on. Lint has already rejected cycles.
def _topo:
  {out: [], left: .}
  | until(.left == [];
      [.out[].id] as $done
      | (first(.left[] | select(all(.deps[]; .ref != "task" or (.id as $x | $done | _has_str($x))))) // null) as $n
      | if $n == null then error("plan_apply: the task graph has a cycle (lint should have refused it)")
        else .out += [$n] | .left |= map(select(.id != $n.id)) end)
  | .out;

# The create template of each plan item, before ids are known. Deps carry
# `ref`: "plan" (a plan epic or task: mapped later) or "node" (an existing id).
def _templates($backend):
  . as $p
  | (if $backend == "local" then {} else null end) as $local
  | ( ($p.epics[]
       | {pid: .id, kind: "epic",
          node: {kind: "epic", title, body: _epic_body($p.spec), status: "ready",
                 target_branch: $p.target_branch}}),
      ($p.tasks | _topo[]
       | {pid: .id, kind: "task",
          node: {kind: "task", title, body: _task_body, epic, module, size,
                 deps: [.deps[] | {id, via, ref: (if .ref == "task" then "plan" else "node" end)}],
                 status: (if .deps == [] then "ready" else "blocked" end),
                 target_branch: $p.target_branch}}),
      (if $p.promote_to != null then
         {pid: ($p | plan_promote_id), kind: "promote",
          node: {kind: "promote", title: "Promote \($p.target_branch) → \($p.promote_to)",
                 body: _promote_body($p),
                 deps: [$p.epics[] | {id, via: null, ref: "plan"}],
                 status: "blocked", target_branch: $p.target_branch, promote_to: $p.promote_to}}
       else empty end) )
  | .plan_ref = "\($p.plan)/\(.pid)"
  | .node.plan_ref = .plan_ref
  | if $local != null then .node = ({id: .pid} + .node) else . end;

def plan_apply_resolve($map):
  def m($what): . as $pid | $map[$pid] // error("plan_apply_resolve: \($what) `\($pid)` has no node id yet");
  (if .epic != null then .epic |= m("epic") else . end)
  | (if has("deps") then .deps |= map({id: (if .ref == "plan" then .id | m("dep") else .id end), via}) else . end);

def plan_apply($ctx):
  . as $p
  | ($ctx.backend // "github") as $backend
  | ($ctx.nodes // []) as $nodes
  | ($p | plan_promote_id) as $prid
  | [_templates($backend)] as $tpl
  | [$p.epics[].id, $p.tasks[].id] as $pids
  # every item's existing node, by plan_ref (the idempotency key)
  | [ $tpl[] | .plan_ref as $k | . + {matches: [$nodes[] | select(.plan_ref == $k)]} ] as $items
  | ( [ $items[] | select(.matches | length == 1) | {key: .pid, value: .matches[0].id} ]
      | from_entries ) as $found
  | [ ( $items[] | . as $it
        | (if (.matches | length) > 1 then
             "`\(.pid)`: plan_ref `\(.plan_ref)` is on \(.matches | length) nodes (\(.matches | map(.id) | join(", "))): refusing to guess which one is the plan's"
           elif (.matches | length) == 1 and .matches[0].kind != .kind then
             "`\(.pid)`: existing node \(.matches[0].id) with plan_ref `\(.plan_ref)` is a \(.matches[0].kind), the plan says \(.kind)"
           elif $backend == "local" and (.matches | length) == 1 and .matches[0].id != .pid then
             "`\(.pid)`: plan_ref `\(.plan_ref)` is on node \(.matches[0].id), not on id \(.pid)"
           else empty end),
          (if $backend == "local" then
             $nodes[] | select(.id == $it.pid and .plan_ref != $it.plan_ref)
             | "`\($it.pid)`: id already exists with plan_ref \(.plan_ref | tojson) (ids are unique across plans; rename the plan's id)"
           else empty end),
          (if (.node.title | test("[\r\n]")) then "`\(.pid)`: title must be one line to apply" else empty end),
          (if $backend == "github" and ((.node.deps // []) | length) > 50 then
             "`\(.pid)`: \(.node.deps | length) blockers exceed GitHub's 50 per issue (§6.2): split the work"
           else empty end) ),
      (if $p.promote_to != null and ($pids | _has_str($prid)) then
         "promote node id `\($prid)` collides with a plan epic or task id: rename it"
       else empty end),
      (if $p.promote_to != null and $backend == "local" and ($prid | is_node_id | not) then
         "promote node id `\($prid)` is not a valid local id (at most 40 chars): shorten the plan id"
       else empty end),
      (if $backend == "local" and ($pids | _has_str("inbox")) then
         "id `inbox` is reserved by the local backend: rename it"
       else empty end) ] as $errors
  # drift: the existing node against the plan, with every known id mapped (an
  # item not yet created maps to null, so an edge to it is missing: drift).
  | [ $items[] | select(.matches | length == 1) | .matches[0] as $n | .pid as $pid | .node as $t
      | ($t | .epic |= (if . == null then null else $found[.] end)
            | if has("deps") then .deps |= map(if .ref == "plan" then $found[.id] else .id end) else . end) as $want
      | ( (if $n.title != $want.title then "title" else empty end),
          (if ($n.body | plan_body_core) != ($want.body | plan_body_core) then "body" else empty end),
          (if $t.kind == "task" and $n.epic != $want.epic then "epic" else empty end),
          (if $t.kind == "task" and $n.module != $want.module then "module" else empty end),
          (if $t.kind == "task" and $n.size != $want.size then "size" else empty end),
          (if $t.kind != "epic" and ([$n.deps[].id] | unique) != ($want.deps | unique) then "deps" else empty end),
          (if $n.target_branch != $want.target_branch then "target_branch" else empty end),
          (if $t.kind == "promote" and $n.promote_to != $want.promote_to then "promote_to" else empty end) )
      | {id: $pid, field: .} ] as $drift
  | { errors: $errors,
      drift: $drift,
      steps: [ $items[]
               | {pid, kind, plan_ref,
                  exists: (.matches | length == 1),
                  id: (if (.matches | length) == 1 then .matches[0].id else null end),
                  node: (if (.matches | length) == 1 then null else .node end)} ] };
