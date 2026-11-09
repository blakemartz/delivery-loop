# sweep.jq — the oracle sweep behind tests/plan-verify-test.sh.
#
# Every case is the base plan with one marker string (a form some reader
# parses, or a near miss) placed in one text field, after one line-ending
# transform. Each case runs apply's real checks in order (plan_lint,
# plan_apply, then plan_verify_<backend>), and, independently, the oracle: the
# nodes apply would create, numbered as the backend would number them (github:
# issues after the existing #3, in creation order; local: plan ids), written by
# the backend's own writer (gh_create_body, both create forms; local: its
# create normalizer) and read back by its own reader (gh_node, gh_migrate_plan;
# local: the stored node), compared with the plan's structured intent.
#
# Output: one object per case: {id, stage: "lint" | "preflight"} for a case an
# earlier check refuses, else {id, stage: "checked", refused: the composed-body
# check refuses it, injected: the oracle reads back other metadata}. A bug is
# injected and not refused.
include "plan-lint";
include "plan-apply";
include "plan-verify";
include "graph-github";
include "node";

def _markers:
  [ "Delivery-Plan: o/zzz", "Delivery-Target: evil", "Delivery-Promote-To: evil",
    "Depends-on: #4", "x Depends-on: #4", "Depends-on: o/r#4", "1. Depends-on: #4",
    "**Depends-on**: #4", "Depends-on**: #4", "* **Depends-on:** #4", "Depends-on: #3 (via: q)",
    "Part of epic #4", "**Part of epic** #4", "Part of epic** #4", "Epic #4",
    "- [ ] #4", "* [x] #4" ];

# LF, CRLF, lone CR, CR CR, U+2028, U+0085.
def _seps: ["\n", "\r\n", "\r", "\r\r", "\u2028", "\u0085"];

# [name, text] variants of one marker: as is, mid-line, and each separator
# before it; LF, lone CR and U+2028 also before its `#` and after its colon.
def _transforms:
  . as $m
  | ["id", $m], ["mid", "see " + $m],
    ( _seps | to_entries[] | .key as $i | .value as $s
      | ["pre\($i)", "ok" + $s + $m],
        ( select($s == "\n" or $s == "\r" or $s == "\u2028")
          | (($m | index("#")) as $k | if $k != null then ["hash\($i)", $m[:$k] + $s + $m[$k:]] else empty end),
            (($m | index(":")) as $k | if $k != null then ["colon\($i)", $m[:$k + 1] + $s + $m[$k + 1:]] else empty end) ) );

def _fields:
  ["context", "criteria", "criteria2", "scope", "scope2", "goal", "spec_refs", "spec", "via",
   "title", "etitle", "join_refs_next", "join_refs_prev", "join_spec_refs"];

def _base($backend):
  { schema: 1, plan: "p", spec: ["s"], target_branch: "rel/x", promote_to: "main",
    epics: [ {id: "e", title: "E", goal: "g", spec_refs: ["r"]} ],
    tasks: [ {id: "t1", epic: "e", title: "T1", module: "plan", size: "S", criteria: ["c"],
              context: "ctx", scope: ["s"], deps: [ {id: "t2", via: "v"} ]},
             {id: "t2", epic: "e", title: "T2", module: "plan", size: "S", criteria: ["c"],
              deps: (if $backend == "github" then [ {id: "#3", via: "w"} ] else [] end)} ] };

def _place($f; $t):
  if   $f == "context"        then .tasks[0].context = $t
  elif $f == "criteria"       then .tasks[0].criteria = [$t]
  elif $f == "criteria2"      then .tasks[0].criteria = ["c", $t]
  elif $f == "scope"          then .tasks[0].scope = [$t]
  elif $f == "scope2"         then .tasks[0].scope = ["s", $t]
  elif $f == "goal"           then .epics[0].goal = $t
  elif $f == "spec_refs"      then .epics[0].spec_refs = [$t]
  elif $f == "spec"           then .spec = [$t]
  elif $f == "via"            then .tasks[0].deps[0].via = $t
  elif $f == "title"          then .tasks[0].title = $t
  elif $f == "etitle"         then .epics[0].title = $t
  elif $f == "join_refs_next" then .epics[0].spec_refs = [$t, "#4"]
  elif $f == "join_refs_prev" then .epics[0].spec_refs = ["x\nDepends-on:", $t]
  elif $f == "join_spec_refs" then .spec = [$t] | .epics[0].spec_refs = ["#4"]
  else error("unknown field \($f)") end;

def sweep_cases($backend):
  _base($backend) as $b
  | _markers[] as $m
  | ($m | _transforms) as [$tn, $t]
  | _fields[] as $f
  | {id: "\($f)|\($tn)|\($m | tojson)", plan: ($b | _place($f; $t))};

# The existing board: closed task #3 (github), nothing (local).
def _nodes($backend):
  if $backend == "github" then
    [ {id: "3", kind: "task", title: "x", epic: null, checklist: [], pinged_at: null, applied_prs: [],
       module: null, size: null, deps: [], status: "done", needs_human: false, claim: null,
       target_branch: "main", promote_to: null, plan_ref: null, body: "",
       created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"} ]
  else [] end;

def _want:
  { deps: ([ (.deps // [])[] | {id: (.id | tostring), via} ] | unique),
    epic: (if .epic == null then null else .epic | tostring end), checklist: [],
    target_branch, plan_ref, promote_to: (if .kind == "promote" then .promote_to else null end),
    migrate: [] };

def _got: { deps: ([ .deps[] | {id: (.id | tostring), via} ] | unique), epic, checklist,
            target_branch, plan_ref, promote_to };

# Oracle: true when some node would be read back with other metadata.
def _oracle_github($a):
  [ $a.steps[] | select(.exists | not) | .pid ] as $new
  | ($new | to_entries | map({key: .value, value: (4 + .key | tostring)}) | from_entries) as $map
  | any( $a.steps[] | select(.exists | not) | (.node | plan_apply_resolve($map)) as $n
         | (0, 1) as $native
         | { number: ($map[$n.plan_ref | split("/")[1]] | tonumber), title: $n.title, state: "OPEN",
             stateReason: "", labels: [{name: $n.kind}], assignees: [], comments: [],
             createdAt: null, updatedAt: null,
             body: ($n | gh_create_body($native; "main")),
             parent: (if $native == 1 and $n.epic != null then {number: ($n.epic | tonumber)} else null end),
             blockedBy: (if $native == 1 then {nodes: [ ($n.deps // [])[] | {number: (.id | tonumber)} ],
                                               totalCount: (($n.deps // []) | length)} else null end) } as $i
         | ($i | gh_node("main") | _got
            + {migrate: (if $native == 1 then [$i] | gh_migrate_plan else [] end)}) != ($n | _want);
       . );

def _oracle_local($a; create):
  ([ $a.steps[] | {key: .pid, value: .pid} ] | from_entries) as $map
  | reduce ($a.steps[] | select(.exists | not)) as $s ({all: [], bad: false};
      ($s.node | plan_apply_resolve($map)) as $n
      | (try ({node: $n, all: .all} | create) catch null) as $r
      | if $r == null then .bad = true
        else .all += [$r] | .bad = (.bad or (($r | _got + {migrate: []}) != ($n | _want))) end)
  | .bad;

def sweep($backend; create):
  _nodes($backend) as $nodes
  | {backend: $backend, base_branch: "main", modules: ["plan"], nodes: [$nodes[].id], others: []} as $lctx
  | sweep_cases($backend)
  | .id as $id
  | (.plan | plan_lint($lctx)) as $l
  | if $l.errors != [] then {id: $id, stage: "lint"}
    else ($l.plan | plan_apply({backend: $backend, nodes: $nodes})) as $a
    | if $a.errors != [] then {id: $id, stage: "preflight"}
      else {id: $id, stage: "checked",
            refused: ((if $backend == "github" then $a | plan_verify_github({base: "main", nodes: $nodes})
                       else $a | plan_verify_local({base: "main", nodes: $nodes}; create) end) != []),
            injected: (if $backend == "github" then _oracle_github($a) else _oracle_local($a; create) end)}
      end
    end;
