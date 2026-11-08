#!/usr/bin/env bash
# delivery-config.sh — print the resolved delivery-loop config for this repo, or
# validate it.
#
#   delivery-config.sh           print every resolved key (KEY=value), for debugging
#   delivery-config.sh --check   validate the combination; exit 1 with a message
#                                per problem, exit 0 silently if valid
#
# Environment-only keys (forge tokens, LOCK_WAIT_SECONDS) are never printed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

case "${1:-}" in
  "") : ;;
  --check) dl_config_check || exit 1; exit 0 ;;
  *) echo "usage: delivery-config.sh [--check]" >&2; exit 2 ;;
esac

cat <<EOF
BASE_BRANCH=$BASE_BRANCH
WORKTREE_SETUP_CMD=$WORKTREE_SETUP_CMD
GATE_CMD=$GATE_CMD
SPEC_SOURCES=$SPEC_SOURCES
STYLEGUIDES_DIR=$STYLEGUIDES_DIR
MODULES=$MODULES
NOTIFY_APPROVE_CMD=$NOTIFY_APPROVE_CMD
NOTIFY_ESCALATE_CMD=$NOTIFY_ESCALATE_CMD
GRAPH_BACKEND=$GRAPH_BACKEND
STATE_DIR=$STATE_DIR
LOCK_STALE_SECONDS=$LOCK_STALE_SECONDS
LIST_LIMIT=$LIST_LIMIT
FORGE=$FORGE
FORGE_URL=$FORGE_URL
FORGE_REPO=$FORGE_REPO
PLANS_DIR=$PLANS_DIR
TASK_MERGE_METHOD=$TASK_MERGE_METHOD
PROMOTE_MERGE_METHOD=$PROMOTE_MERGE_METHOD
PROMOTE_GATE_CMD=$PROMOTE_GATE_CMD
EOF
