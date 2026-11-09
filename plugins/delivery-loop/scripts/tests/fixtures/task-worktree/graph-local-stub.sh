#!/usr/bin/env bash
# graph-local-stub.sh — a stand-in local graph backend for task-worktree-test.sh.
#
# The test copies the engine into a throwaway dir and installs this file as
# backends/graph-local.sh, so slug ids (GC55) can be exercised without the real
# local store. `show <id>` prints the node with that id from $STUB_NODES (a JSON
# array of §4.1 nodes) and logs `show <id>` to $SHIM_STATE/log; nothing else is
# implemented.
set -euo pipefail
: "${STUB_NODES:?}" "${SHIM_STATE:?}"
echo "graph-local $*" >> "$SHIM_STATE/log"
case "${1:-}" in
  show)
    obj=$(jq -c --arg id "${2:-}" '.[] | select(.id == $id)' "$STUB_NODES")
    [ -n "$obj" ] || { echo "graph-local: no node '${2:-}'" >&2; exit 1; }
    echo "$obj" ;;
  *) echo "graph-local-stub: unhandled call: $*" >&2; exit 64 ;;
esac
