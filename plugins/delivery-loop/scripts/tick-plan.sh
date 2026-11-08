#!/usr/bin/env bash
# tick-plan.sh [--parallel [N]] [--auto-merge] — print the orchestrator tick's
# action plan (docs/delivery_graph_spec.md §5 `tick-plan.jq`, §10
# `delivery-tick`).
#
# Validates the config combination once (§11) before any I/O, reads every node
# (`graph.sh list`) and the open PRs (`forge.sh pr-list --state open`), and
# prints lib/tick-plan.jq's {mode, actions, board, waiting} as JSON. It decides
# nothing itself and changes nothing: the tick executes the actions in order.
#
# Flags (GC17):
#   --parallel [N]  parallel mode with N agent actions. Bare, or a value that is
#                   not a whole number, means 3; above 16 clamps to 16; 1 or
#                   lower means serial. Also accepted as --parallel=N.
#   --auto-merge    allow merge actions (off by default).
#
# Exit codes: 0 ok · 1 invalid config or a failed read · 2 usage.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() { echo "usage: tick-plan.sh [--parallel [N]] [--auto-merge]" >&2; }

# parse_parallel <value>: the GC17 reading of a --parallel value, as an integer
# (<= 1 means serial). Pure string checks, so leading zeros and huge numbers
# never reach shell arithmetic.
parse_parallel() {
  local v="$1" digits
  case "$v" in
    -*[!0-9]*|-) echo 3; return ;;     # "-", "-x": not a whole number
    -*) echo 1; return ;;              # negative: serial
    ''|*[!0-9]*) echo 3; return ;;     # not a whole number
  esac
  digits="${v#"${v%%[!0]*}"}"          # strip leading zeros
  if [ -z "$digits" ]; then echo 1
  elif [ "${#digits}" -gt 2 ] || [ "$digits" -gt 16 ]; then echo 16
  else echo "$digits"; fi
}

parallel=1
auto_merge=false
while [ $# -gt 0 ]; do
  case "$1" in
    --parallel=*) parallel=$(parse_parallel "${1#--parallel=}") ;;
    --parallel)
      # The next word is N unless it is absent or another flag (bare → 3).
      if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then
        parallel=$(parse_parallel "$2"); shift
      else
        parallel=3
      fi ;;
    --auto-merge) auto_merge=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-tick-plan.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Files, not --argjson: a full board can exceed the argument-length limit.
bash "$SCRIPT_DIR/graph.sh" list >"$tmp/nodes.json"
bash "$SCRIPT_DIR/forge.sh" pr-list --state open >"$tmp/prs.json"

jq -n -L "$SCRIPT_DIR/lib" \
  --slurpfile nodes "$tmp/nodes.json" --slurpfile prs "$tmp/prs.json" \
  --argjson parallel "$parallel" --argjson auto_merge "$auto_merge" \
  --argjson now "$(date -u +%s)" \
  'include "tick-plan";
   {nodes: $nodes[0], prs: $prs[0],
    flags: {parallel: $parallel, auto_merge: $auto_merge}, now: $now}
   | tick_plan'
