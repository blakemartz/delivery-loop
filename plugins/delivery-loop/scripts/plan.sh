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
#
# What lint needs beyond the file itself:
#   - MODULES (plus infra and docs) for each task's `module`;
#   - BASE_BRANCH, the default `target_branch`;
#   - the existing node ids (`graph.sh list`), read only when some dep is not
#     a task of this plan (on github, `"#42"` names existing issue 42);
#   - every other `*.plan.json` in PLANS_DIR (relative to the repo root), whose
#     `promote_to` must agree with this plan's when they share a target_branch.
#
# Validates the config combination once (§11) before any I/O.
#
# Exit codes: 0 ok · 1 lint errors, an unreadable plan, a failed graph read or
# an invalid config · 2 usage.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() {
  echo "usage: plan.sh lint <file> | render <file> (docs/delivery_graph_spec.md §8)" >&2
  exit 2
}

[ $# -eq 2 ] || usage
op="$1" file="$2"
case "$op" in lint|render) : ;; *) usage ;; esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-plan.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

pjq() { jq -L "$SCRIPT_DIR/lib" "$@"; }

[ -f "$file" ] || { echo "plan.sh: $file: no such plan file" >&2; exit 1; }
if ! jq -s 'if length == 1 then .[0] else error("expected one JSON document, found \(length)") end' \
     "$file" >"$tmp/plan.json" 2>"$tmp/jq.err"; then
  echo "plan.sh: $file: error: plan: not valid JSON: $(sed 's/^jq: //' "$tmp/jq.err" | head -n 1)" >&2
  exit 1
fi

# canon <path>: the physical absolute path, so the linted plan is recognized
# among PLANS_DIR's files however it was named on the command line.
canon() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }

modules_json="$(jq -cn --arg m "$MODULES" '[$m | splits("[[:space:]]+") | select(length > 0)]')"

nodes_json=null
graph_failed=0
: >"$tmp/others.jsonl"
if [ "$op" = lint ]; then
  # Existing-node resolution: read the graph only when a dep needs it.
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
         '{file: $f, target_branch: (.target_branch? // null), promote_to: (.promote_to? // null)}' \
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
    jq -r --arg f "$file" '.plan | "plan.sh: \($f): ok (\(.epics | length) epics, \(.tasks | length) tasks)"' "$tmp/lint.json" ;;
  render)
    pjq -r 'include "plan-render"; .plan | plan_render' "$tmp/lint.json" ;;
esac
