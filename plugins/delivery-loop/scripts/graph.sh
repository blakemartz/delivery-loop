#!/usr/bin/env bash
# graph.sh <op> [args] — the graph seam (docs/delivery_graph_spec.md §3, §6.1).
#
# Skills and engine scripts read the work graph through this, never `gh issue`
# directly (§3 rule 3). It resolves the config, validates the combination once
# (`delivery-config.sh --check` semantics, §11) before any I/O, loads nodes from
# backends/graph-$GRAPH_BACKEND.sh, runs validate_node on every backend output
# (fail fast on drift, §4.1) and applies the lib/*.jq policy core (§3 rule 1:
# backends store, they never decide).
#
# Ops:
#   ready                       the ready set, best first, one JSON line each
#                               (lib/ready.jq: {id, title, unblocks, size,
#                               started, epic, module, target_branch}).
#   list                        every node, open and closed, as one compact
#                               JSON array.
#   show <id> [--format json|md]
#                               one node (json, the default), or its title and
#                               body as markdown for agent prompts. The markdown
#                               is rendered here from the validated node, so
#                               every backend gets it.
#                               On the local backend the node's last 10 journal
#                               events follow on stderr, one JSON object per
#                               line (§6.3): stdout stays exactly one node, the
#                               §6.1 contract callers parse. The tail is best
#                               effort: a journal read failure only warns.
#   export                      every node as pretty-printed JSON, for backup
#                               and debugging.
#   create <node-json>|-  ·  update <id> <patch-json>|-  ·  link <id> <dep-id> [via]
#   ·  flag <id> needs-human on|off  ·  release <id> <reason>  ·  comment <id> <text>|-
#                               routed unchanged (args, stdin, stdout, exit
#                               status) to the backend primitive (§6.1), which
#                               validates its input. A nonzero id-less create
#                               may still have created the node: look it up by
#                               plan_ref/title before retrying.
#   claim <id> <actor> [--run <run>]  ·  claim <id> --human <name>
#                               policy pre-check (the node is valid, ready ->
#                               claimed is legal for the actor kind, no claim,
#                               and an agent never claims a needs_human node),
#                               then the backend's atomic claim (§6.3, GC21).
#                               The run defaults to <host>-<pid>-<epoch>; a
#                               human claim has none. Exit 0 = owned, 1 = lost
#                               or not claimable.
#   reconcile [--fix]           lib/reconcile.jq over every node and the forge's
#                               PRs: `forge.sh pr-list --state open` plus
#                               `--state merged --since <oldest open node's
#                               created_at>` (§5, §6.2, §6.3). Warnings go to
#                               stderr as `warn: …`. Without --fix the fix
#                               records are printed, one JSON object per line,
#                               and nothing is written. With --fix each record
#                               is applied through the backend's `reconcile`
#                               primitive, a compare-and-set against the node as
#                               the plan saw it, and printed as
#                               `fix: <op> <id> <from> -> <to>: <reason>`; a
#                               record the board outran (backend exit 4) is a
#                               `warn: skipped` line, not a failure.
#
# Exit codes: 0 ok · 1 failed / invalid config / not claimable · 2 usage · 3
# the backend list reached LIST_LIMIT · 5 a backend emitted a node that fails
# validate_node. A routed write op exits with its backend's status.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() {
  echo "usage: graph.sh ready | list | show <id> [--format json|md] | export | create <node-json> | update <id> <patch-json> | link <id> <dep-id> [via] | flag <id> needs-human on|off | claim <id> <actor> [--run <run>] | claim <id> --human <name> | release <id> <reason> | comment <id> <text> | reconcile [--fix] (docs/delivery_graph_spec.md §6.1)" >&2
  exit 2
}

op="${1:-}"
[ $# -eq 0 ] || shift
case "$op" in
  ready|list|export) [ $# -eq 0 ] || usage ;;
  reconcile) [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --fix ]; } || usage ;;
  show|claim|create|update|link|flag|release|comment) : ;;
  *) usage ;;
esac

backend="$SCRIPT_DIR/backends/graph-$GRAPH_BACKEND.sh"
[ -f "$backend" ] || { echo "graph.sh: no backend for GRAPH_BACKEND=$GRAPH_BACKEND ($backend missing)" >&2; exit 1; }

# Plain writes are the backend's primitives verbatim: exec, so stdin (`-`),
# stdout and the exit status pass straight through (§6.1).
case "$op" in
  create|update|link|flag|release|comment) exec bash "$backend" "$op" "$@" ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# pjq <filter> <file> [jq args…]: run a policy filter; any jq failure (a node
# failing validate_node, or output that is not JSON) is shape drift: exit 5.
pjq() {
  local filter="$1" file="$2"; shift 2
  jq -L "$SCRIPT_DIR/lib" "$@" "$filter" "$file" 2> "$tmp/jq.err" || {
    sed 's/^jq: error (at [^)]*): //' "$tmp/jq.err" >&2
    echo "graph.sh: backend $GRAPH_BACKEND emitted invalid nodes (§4.1)" >&2
    exit 5
  }
}

ALL='include "node";
  if type != "array" then error("backend list must emit a JSON array (got \(type))")
  else map(validate_node) end'

# The backend's exit status (3 for LIST_LIMIT) passes through unchanged.
load_all() { bash "$backend" list > "$tmp/nodes.json" || exit $?; }

case "$op" in
  ready)
    load_all
    pjq 'include "ready"; ready' "$tmp/nodes.json" -c ;;
  list)
    load_all
    pjq "$ALL" "$tmp/nodes.json" -c ;;
  export)
    load_all
    pjq "$ALL" "$tmp/nodes.json" ;;
  show)
    id="" format=json
    while [ $# -gt 0 ]; do
      case "$1" in
        --format) format="${2:-}"; [ $# -ge 2 ] || usage; shift 2 ;;
        -*) usage ;;
        *) [ -z "$id" ] || usage; id="$1"; shift ;;
      esac
    done
    [ -n "$id" ] || usage
    case "$format" in json|md) : ;; *) usage ;; esac
    bash "$backend" show "$id" > "$tmp/node.json" || exit $?
    if [ "$format" = md ]; then
      pjq 'include "node"; validate_node | "# \(.title)\n\n\(.body)"' "$tmp/node.json" -r
    else
      pjq 'include "node"; validate_node' "$tmp/node.json" -c
    fi
    # §6.3: the journal is the local store's audit trail (github's history is
    # the issue timeline). On stderr, so stdout stays one node; best effort, so
    # an unreadable journal never fails the read of a valid node.
    if [ "$GRAPH_BACKEND" = local ]; then
      bash "$backend" journal "$id" 10 >&2 \
        || echo "graph.sh: warning: cannot print the journal of $id" >&2
    fi ;;
  claim)
    id="${1:-}" actor="" run="" by=agent
    [ -n "$id" ] && [ "${id#-}" = "$id" ] || usage
    shift
    case "${1:-}" in
      --human) [ $# -eq 2 ] && [ -n "$2" ] || usage; actor="$2" by=human ;;
      ''|-*) usage ;;
      *) actor="$1"; shift
         case $# in
           0) : ;;
           2) [ "$1" = --run ] && [ -n "$2" ] || usage; run="$2" ;;
           *) usage ;;
         esac ;;
    esac
    [ "$by" = human ] || [ -n "$run" ] || run="$(uname -n)-$$-$(date +%s)"
    bash "$backend" show "$id" > "$tmp/node.json" || exit $?
    why=$(pjq 'include "node"; include "transitions"; validate_node
      | transition_error("claimed"; $by) as $e
      | if $e != null then $e
        elif .claim != null then "\(.id | tojson) is already claimed by \(.claim.actor)"
        elif $by == "agent" and .needs_human then "\(.id | tojson) is needs-human"
        else empty end' "$tmp/node.json" -r --arg by "$by")
    [ -z "$why" ] || { echo "graph.sh: not claimable: $why" >&2; exit 1; }
    exec bash "$backend" claim "$id" "$actor" "${run:--}" "$by" ;;
  reconcile)
    load_all
    pjq "$ALL" "$tmp/nodes.json" -c > "$tmp/valid.json"
    # Ground truth (§6.2, §6.3): the open PRs, plus every PR merged since the
    # oldest open node was created (none open: no merged read is needed).
    bash "$SCRIPT_DIR/forge.sh" pr-list --state open > "$tmp/open.json" || exit $?
    since=$(jq -r -L "$SCRIPT_DIR/lib" 'include "graph";
      [.[] | select(is_open)] | if length == 0 then empty
      else min_by(.created_at | iso_epoch) | .created_at end' "$tmp/valid.json")
    if [ -n "$since" ]; then
      bash "$SCRIPT_DIR/forge.sh" pr-list --state merged --since "$since" > "$tmp/merged.json" || exit $?
    else
      echo '[]' > "$tmp/merged.json"
    fi
    jq -n -L "$SCRIPT_DIR/lib" --slurpfile nodes "$tmp/valid.json" \
      --slurpfile open "$tmp/open.json" --slurpfile merged "$tmp/merged.json" \
      --argjson now "$(date -u +%s)" 'include "reconcile"; include "graph";
      ($nodes[0] | index_by_id) as $idx
      | {nodes: $nodes[0], prs: ($open[0] + $merged[0] | unique_by(.number)), now: $now}
      | reconcile_plan
      | .records |= map(. + {updated_at: $idx[.id].updated_at})' > "$tmp/plan.json" 2> "$tmp/jq.err" || {
      sed 's/^jq: error (at [^)]*): //' "$tmp/jq.err" >&2
      echo "graph.sh: reconcile: cannot plan over the board and the forge's PRs" >&2
      exit 1
    }
    jq -r '.warnings[] | "warn: \(.)"' "$tmp/plan.json" >&2
    if [ $# -eq 0 ]; then
      jq -c '.records[] | del(.updated_at)' "$tmp/plan.json"
      exit 0
    fi
    jq -c '.records[]' "$tmp/plan.json" > "$tmp/records.jsonl"
    failed=0
    while IFS= read -r rec; do
      line=$(jq -r '"\(.op) \(.id) \(.from) -> \(.to): \(.reason)"' <<<"$rec")
      rc=0
      bash "$backend" reconcile "$rec" < /dev/null 2> "$tmp/apply.err" || rc=$?
      case "$rc" in
        0) echo "fix: $line" ;;
        4) echo "warn: skipped $line: $(cat "$tmp/apply.err")" >&2 ;;
        *) cat "$tmp/apply.err" >&2; echo "graph.sh: reconcile: failed to apply $line (exit $rc)" >&2; failed=1 ;;
      esac
    done < "$tmp/records.jsonl"
    exit "$failed" ;;
esac
