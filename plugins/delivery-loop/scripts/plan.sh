#!/usr/bin/env bash
# plan.sh <op> <file> — plan files (docs/delivery_graph_spec.md §8).
#
# Ops:
#   lint <file>    validate a plan file against §8.1 and §8.2. Prints every
#                  error (and warning) on stderr and exits 1 if there is any
#                  error; prints one `ok` line on stdout otherwise. A `size: "L"`
#                  task is a warning, not an error.
#   render <file>  print the plan as a Mermaid `flowchart TD` (§8.4). The plan
#                  must pass lint's structural checks first; existing-node deps
#                  and the other plans in PLANS_DIR are not consulted.
#   apply <file>   create the plan's nodes (§8.3, §9), idempotently; never
#                  deletes or overwrites anything. In order, and nothing is
#                  written until every check has passed:
#                    1. lint, against the full `graph.sh list` (so `#N` deps
#                       resolve only against that list); lint also refuses
#                       plan text carrying a line a backend would read back
#                       as a marker (`Delivery-Plan:`, `Depends-on: #N`, …), so
#                       no plan text can rewrite a node's metadata;
#                    2. `git check-ref-format --branch` on target_branch,
#                       promote_to and the branch a missing target is cut from
#                       (output must equal input, so `@{-1}` never expands),
#                       and none of them `@`, `HEAD` or `HEAD/…` (any case),
#                       `refs/…` or `origin/…`;
#                    3. lib/plan-apply.jq preflight: plan_ref collisions, local
#                       id reuse across plans (GC35), the promote id, one-line
#                       titles, the 50-blocker cap on github;
#                    3b. composed-body validation (lib/plan-verify.jq):
#                       each node to create is rendered as the backend's
#                       create writes it (github: gh_create_body, native and
#                       gh < 2.94 forms; local: its GL_CREATE normalizer) and
#                       read back by the backend's own reader (gh_node,
#                       gh_migrate_plan; local: the stored node); any
#                       difference in deps, epic, checklist, target_branch,
#                       plan_ref or promote_to (or a migrate plan) refuses the
#                       plan, naming the node and field;
#                    4. drift: an existing node (found by plan_ref) whose title,
#                       body, epic, module, size, deps, target_branch or
#                       promote_to differs from the plan prints `drift: <id>
#                       <field>` on stderr and is left unchanged (GC54);
#                    5. a target_branch missing on origin is created from
#                       origin/<promote_to or BASE_BRANCH>: the exact `git push`
#                       is printed, then run (GC53); a failed push, or one
#                       origin does not then show at the pushed commit
#                       (`git ls-remote`), stops apply before any node;
#                    6. `graph.sh create` for each missing node: epics, tasks
#                       in topological order (github: `--parent` and
#                       `--blocked-by`, GC36), then the promote node (deps = the
#                       plan's epics) when promote_to is set;
#                    7. `graph.sh reconcile --fix`.
#                  stdout: `exists: <kind> <plan id> <node id>` / `created: <kind>
#                  <plan id> <node id>` per node, the push, reconcile's `fix:`
#                  lines, then one summary line. A failure part-way leaves what
#                  was created; re-running apply finds it by plan_ref.
#
# What lint needs beyond the file itself:
#   - MODULES (plus infra and docs) for each task's `module`;
#   - BASE_BRANCH, the default `target_branch`;
#   - the existing node ids (`graph.sh list`), read only when some dep is not
#     a task of this plan (on github, `"#42"` names existing issue 42);
#   - every other `*.plan.json` in PLANS_DIR (relative to the repo root), whose
#     `promote_to` must agree with this plan's when they share a target_branch,
#     and whose `plan` id must differ from this plan's (plan_ref keys).
# Every op refuses a plan file with a duplicate JSON object key (jq would keep
# the last value silently).
#
# Validates the config combination once (§11) before any I/O.
#
# Exit codes: 0 ok (apply: drift is reported, still 0) · 1 lint or apply
# errors, an unreadable plan, a failed graph read, git or backend write, or an
# invalid config · 2 usage.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() {
  echo "usage: plan.sh lint <file> | render <file> | apply <file> (docs/delivery_graph_spec.md §8)" >&2
  exit 2
}

[ $# -eq 2 ] || usage
op="$1" file="$2"
case "$op" in lint|render|apply) : ;; *) usage ;; esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-plan.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

pjq() { jq -L "$SCRIPT_DIR/lib" "$@"; }

[ -f "$file" ] || { echo "plan.sh: $file: no such plan file" >&2; exit 1; }
if ! jq -s 'if length == 1 then .[0] else error("expected one JSON document, found \(length)") end' \
     "$file" >"$tmp/plan.json" 2>"$tmp/jq.err"; then
  echo "plan.sh: $file: error: plan: not valid JSON: $(sed 's/^jq: //' "$tmp/jq.err" | head -n 1)" >&2
  exit 1
fi
# A duplicate key: the raw token stream has more leaves than the parsed value.
if [ "$(jq -n --stream '[inputs | select(length == 2)] | length' "$file")" \
     != "$(jq '[tostream | select(length == 2)] | length' "$tmp/plan.json")" ]; then
  echo "plan.sh: $file: error: plan: duplicate JSON object key (a later value would silently replace an earlier one)" >&2
  exit 1
fi

# canon <path>: the physical absolute path, so the linted plan is recognized
# among PLANS_DIR's files however it was named on the command line.
canon() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }

modules_json="$(jq -cn --arg m "$MODULES" '[$m | splits("[[:space:]]+") | select(length > 0)]')"

nodes_json=null
graph_failed=0
: >"$tmp/others.jsonl"
echo '[]' >"$tmp/nodes.json"
if [ "$op" = apply ]; then
  # apply always needs the board: plan_ref lookups, and the deps resolve
  # against it.
  if ! bash "$SCRIPT_DIR/graph.sh" list >"$tmp/nodes.json" </dev/null; then
    echo "plan.sh: $file: error: apply: graph.sh list failed (nothing written)" >&2
    exit 1
  fi
  nodes_json="$(jq -c '[.[].id]' "$tmp/nodes.json")"
fi
if [ "$op" = lint ]; then
  # Existing-node resolution: lint reads the graph only when a dep needs it.
  ext="$(pjq -c --arg backend "$GRAPH_BACKEND" 'include "plan-lint"; plan_external_deps($backend)' "$tmp/plan.json")"
  if [ "$ext" = "[]" ]; then
    nodes_json='[]'
  else
    if bash "$SCRIPT_DIR/graph.sh" list >"$tmp/nodes.json"; then
      nodes_json="$(jq -c '[.[].id]' "$tmp/nodes.json")"
    else
      # Still lint everything else; the unresolvable deps fail the run.
      echo "plan.sh: $file: error: cannot resolve deps $ext: graph.sh list failed" >&2
      graph_failed=1
    fi
  fi
fi
if [ "$op" != render ]; then
  # Cross-plan consistency: the other plans in PLANS_DIR.
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  case "$PLANS_DIR" in /*) plans_dir="$PLANS_DIR" ;; *) plans_dir="$root/$PLANS_DIR" ;; esac
  plans_dir="${plans_dir%/}"
  self="$(canon "$file")"
  for f in "$plans_dir"/*.plan.json; do
    [ -f "$f" ] || continue
    [ "$(canon "$f")" = "$self" ] && continue
    shown="${PLANS_DIR%/}/$(basename "$f")"
    if ! jq -c --arg f "$shown" \
         '{file: $f, plan: (.plan? // null), target_branch: (.target_branch? // null), promote_to: (.promote_to? // null)}' \
         "$f" >>"$tmp/others.jsonl" 2>/dev/null; then
      echo "plan.sh: $file: warning: skipping $shown: not valid JSON" >&2
    fi
  done
fi

jq -n --argjson nodes "$nodes_json" --argjson modules "$modules_json" \
  --arg backend "$GRAPH_BACKEND" --arg base "$BASE_BRANCH" \
  --slurpfile others "$tmp/others.jsonl" \
  '{backend: $backend, base_branch: $base, modules: $modules, nodes: $nodes, others: $others}' \
  >"$tmp/ctx.json"

pjq --slurpfile ctx "$tmp/ctx.json" 'include "plan-lint"; plan_lint($ctx[0])' "$tmp/plan.json" >"$tmp/lint.json"

jq -r --arg f "$file" '.errors[] | "plan.sh: \($f): error: \(.)"' "$tmp/lint.json" >&2
jq -r --arg f "$file" '.warnings[] | "plan.sh: \($f): warning: \(.)"' "$tmp/lint.json" >&2
if [ "$graph_failed" -ne 0 ] || [ "$(jq '.errors | length' "$tmp/lint.json")" -ne 0 ]; then
  [ "$op" = render ] && echo "plan.sh: $file: render needs a plan that passes lint" >&2
  exit 1
fi

case "$op" in
  lint)
    jq -r --arg f "$file" '.plan | "plan.sh: \($f): ok (\(.epics | length) epics, \(.tasks | length) tasks)"' "$tmp/lint.json"
    exit 0 ;;
  render)
    pjq -r 'include "plan-render"; .plan | plan_render' "$tmp/lint.json"
    exit 0 ;;
esac

# --- apply (§8.3) ---------------------------------------------------------------
die() { echo "plan.sh: $file: error: apply: $*" >&2; exit 1; }

jq '.plan' "$tmp/lint.json" >"$tmp/norm.json"
target="$(jq -r .target_branch "$tmp/norm.json")"
promote_to="$(jq -r '.promote_to // empty' "$tmp/norm.json")"
source_branch="${promote_to:-$BASE_BRANCH}"

# Branch names, before anything is created or pushed. `--branch` prints the
# name it resolved; it must be the name itself (`@{-1}` would expand). Some
# names it accepts are refused too: `@` (HEAD's shorthand); a first path
# component of HEAD in any case (`HEAD/x` pushed as refs/heads/HEAD/x collides
# with refs/remotes/origin/HEAD in every clone, so `git clone`/`git fetch` of
# origin break; `head/x` does the same on a case-insensitive filesystem); and
# a name starting `refs/` or `origin/`, which would be pushed as
# refs/heads/refs/… or refs/heads/origin/… and shadow other refs.
bad_branches=0
check_branch() {
  local what="$1" b="$2" norm=""
  case "$b" in
    -*|@|[Hh][Ee][Aa][Dd]|[Hh][Ee][Aa][Dd]/*|refs/*|origin/*|*@\{*) norm="" ;;
    *) norm="$(git check-ref-format --branch "$b" 2>/dev/null)" || norm="" ;;
  esac
  if [ "$norm" != "$b" ]; then
    echo "plan.sh: $file: error: apply: $what \`$b\` is not a valid branch name (git check-ref-format --branch; not @, HEAD[/…] in any case, refs/…, origin/…)" >&2
    bad_branches=1
  fi
}
check_branch target_branch "$target"
if [ -n "$promote_to" ]; then check_branch promote_to "$promote_to"
else check_branch BASE_BRANCH "$BASE_BRANCH"; fi
[ "$bad_branches" -eq 0 ] || exit 1

jq -n --arg backend "$GRAPH_BACKEND" --slurpfile nodes "$tmp/nodes.json" \
  '{backend: $backend, nodes: $nodes[0]}' >"$tmp/actx.json"
pjq --slurpfile ctx "$tmp/actx.json" 'include "plan-apply"; plan_apply($ctx[0])' "$tmp/norm.json" >"$tmp/apply.json"
if [ "$(jq '.errors | length' "$tmp/apply.json")" -ne 0 ]; then
  jq -r --arg f "$file" '.errors[] | "plan.sh: \($f): error: apply: \(.)"' "$tmp/apply.json" >&2
  echo "plan.sh: $file: apply refused (nothing written)" >&2
  exit 1
fi
# Composed-body validation (lib/plan-verify.jq): every node to create, rendered
# as the backend's create writes it and read back by the backend's own reader,
# must carry exactly the plan's metadata.
case "$GRAPH_BACKEND" in
  github)
    jq -n --arg base "$BASE_BRANCH" --slurpfile nodes "$tmp/nodes.json" '{base: $base, nodes: $nodes[0]}' >"$tmp/vctx.json"
    pjq -L "$SCRIPT_DIR/backends" --slurpfile ctx "$tmp/vctx.json" \
      'include "plan-verify"; plan_verify_github($ctx[0])' "$tmp/apply.json" >"$tmp/verify.json" \
      || die "composed-body validation failed to run (nothing written)" ;;
  local)
    # The local backend's own create normalizer, GL_CREATE (sourcing the
    # backend defines it and runs nothing).
    gl_create="$(. "$SCRIPT_DIR/backends/graph-local.sh" && printf '%s' "$GL_CREATE")" \
      || die "cannot load the local backend's create normalizer (nothing written)"
    jq -n --arg base "$BASE_BRANCH" --slurpfile nodes "$tmp/nodes.json" '{base: $base, nodes: $nodes[0]}' >"$tmp/vctx.json"
    pjq -L "$SCRIPT_DIR/backends" --slurpfile ctx "$tmp/vctx.json" --arg base "$BASE_BRANCH" \
      "include \"plan-verify\"; def _gl_create(\$all; \$now; \$base): $gl_create;
       plan_verify_local(\$ctx[0]; . as \$x | \$x.node | _gl_create([\$x.all]; \"1970-01-01T00:00:00Z\"; \$base))" \
      "$tmp/apply.json" >"$tmp/verify.json" \
      || die "composed-body validation failed to run (nothing written)" ;;
  *) die "no composed-body validation for GRAPH_BACKEND=$GRAPH_BACKEND (nothing written)" ;;
esac
if [ "$(jq 'length' "$tmp/verify.json")" -ne 0 ]; then
  jq -r --arg f "$file" '.[] | "plan.sh: \($f): error: apply: \(.)"' "$tmp/verify.json" >&2
  echo "plan.sh: $file: apply refused (nothing written)" >&2
  exit 1
fi
jq -r '.drift[] | "drift: \(.id) \(.field)"' "$tmp/apply.json" >&2

# The target branch (GC53): the only branch-creating step. `origin/<src>` must
# be the remote-tracking ref itself, never a local branch or tag of that name.
# The push is the exact §8.3/GC53 command (no force): if someone creates the
# target between the ls-remote and the push, a diverged target is rejected as
# non-fast-forward, and only an ancestor of origin/<src> can be advanced.
rc=0
git ls-remote --exit-code --heads origin "refs/heads/$target" >/dev/null </dev/null || rc=$?
case "$rc" in
  0) : ;;
  2)
    git fetch --quiet origin "+refs/heads/$source_branch:refs/remotes/origin/$source_branch" </dev/null \
      || die "target branch $target is missing on origin, and origin has no branch $source_branch to create it from (nothing written)"
    want="$(git rev-parse --verify --quiet "refs/remotes/origin/$source_branch^{commit}")" || want=""
    got="$(git rev-parse --verify --quiet "origin/$source_branch^{commit}")" || got=""
    [ -n "$want" ] && [ "$want" = "$got" ] \
      || die "origin/$source_branch is ambiguous (a local branch or tag shadows the remote-tracking ref; nothing written)"
    echo "plan.sh: target branch $target is missing on origin; creating it from origin/$source_branch:"
    echo "git push origin origin/$source_branch:refs/heads/$target"
    git push origin "origin/$source_branch:refs/heads/$target" </dev/null \
      || die "git push failed: target branch $target not created (nothing else written)"
    # The push's exit status is not the whole result (a ref-update error on
    # either side can still exit 0): origin must now hold the target at the
    # commit pushed, or nothing is created.
    remote_heads="$(git ls-remote --heads origin "refs/heads/$target" </dev/null)" \
      || die "git push: cannot re-read origin to confirm target branch $target (nothing else written)"
    pushed_at="$(printf '%s\n' "$remote_heads" | awk -v r="refs/heads/$target" '$2 == r { print $1 }')"
    [ -n "$want" ] && [ "$pushed_at" = "$want" ] \
      || die "git push reported success but origin does not hold refs/heads/$target at $want (nothing else written)" ;;
  *) die "cannot read origin (git ls-remote exit $rc; nothing written)" ;;
esac

# Create what is missing, in step order; $tmp/map.json maps plan ids to node ids.
jq -c '[.steps[] | select(.exists) | {key: .pid, value: .id}] | from_entries' "$tmp/apply.json" >"$tmp/map.json"
jq -c '.steps[]' "$tmp/apply.json" >"$tmp/steps.jsonl"
created=0 existing=0
while IFS= read -r step; do
  kind="$(jq -r .kind <<<"$step")" pid="$(jq -r .pid <<<"$step")"
  if [ "$(jq -r .exists <<<"$step")" = true ]; then
    echo "exists: $kind $pid $(jq -r .id <<<"$step")"
    existing=$((existing + 1))
    continue
  fi
  pjq -c --slurpfile map "$tmp/map.json" 'include "plan-apply"; .node | plan_apply_resolve($map[0])' \
    <<<"$step" >"$tmp/node.json" || die "cannot build node $pid"
  rc=0
  id="$(bash "$SCRIPT_DIR/graph.sh" create - <"$tmp/node.json")" || rc=$?
  id="$(printf '%s\n' "$id" | tail -n 1)"
  if [ "$rc" -ne 0 ] || [ -z "$id" ]; then
    die "graph.sh create failed for $kind $pid (exit $rc) after $created created; re-run plan.sh apply: it finds existing nodes by plan_ref"
  fi
  jq -c --arg k "$pid" --arg v "$id" '.[$k] = $v' "$tmp/map.json" >"$tmp/map.next" && mv "$tmp/map.next" "$tmp/map.json"
  echo "created: $kind $pid $id"
  created=$((created + 1))
done <"$tmp/steps.jsonl"

rc=0
bash "$SCRIPT_DIR/graph.sh" reconcile --fix </dev/null || rc=$?
[ "$rc" -eq 0 ] || die "every node exists ($created created), but graph.sh reconcile --fix exited $rc: re-run it"
echo "plan.sh: $file: applied ($created created, $existing existing, $(jq '.drift | length' "$tmp/apply.json") drift)"
