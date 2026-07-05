#!/usr/bin/env bash
# delivery-config.sh — print the resolved delivery-loop config for this repo.
# Handy for debugging what the engine will actually use.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
cat <<EOF
BASE_BRANCH=$BASE_BRANCH
WORKTREE_SETUP_CMD=$WORKTREE_SETUP_CMD
GATE_CMD=$GATE_CMD
SPEC_SOURCES=$SPEC_SOURCES
STYLEGUIDES_DIR=$STYLEGUIDES_DIR
MODULES=$MODULES
NOTIFY_APPROVE_CMD=$NOTIFY_APPROVE_CMD
NOTIFY_ESCALATE_CMD=$NOTIFY_ESCALATE_CMD
EOF
