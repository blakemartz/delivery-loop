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
#   export                      every node as pretty-printed JSON, for backup
#                               and debugging.
#
# Exit codes: 0 ok · 1 failed / invalid config · 2 usage · 3 the backend list
# reached LIST_LIMIT · 5 a backend emitted a node that fails validate_node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() {
  echo "usage: graph.sh ready | list | show <id> [--format json|md] | export (docs/delivery_graph_spec.md §6.1)" >&2
  exit 2
}

op="${1:-}"
[ $# -eq 0 ] || shift
case "$op" in
  ready|list|export) [ $# -eq 0 ] || usage ;;
  show) : ;;
  *) usage ;;
esac

backend="$SCRIPT_DIR/backends/graph-$GRAPH_BACKEND.sh"
[ -f "$backend" ] || { echo "graph.sh: no backend for GRAPH_BACKEND=$GRAPH_BACKEND ($backend missing)" >&2; exit 1; }

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
    fi ;;
esac
