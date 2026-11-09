#!/usr/bin/env bash
# claim-task.sh <issue#> <actor> — atomically-enough claim a ready task.
#
# A compatibility wrapper (docs/delivery_graph_spec.md §3 rule 4) over
# `graph.sh claim <id> <actor> --run <run>`: graph.sh's policy pre-check (a legal
# ready -> claimed move, no claim, not needs-human), then the backend's atomic
# claim. Arguments, stdout and exit codes are v0.1.4's.
#
# On the github backend the claim is v0.1.4's comment-ordered Lamport lock,
# unchanged (backends/graph-github.sh claim; docs/agentic_delivery_spec.md §7.2):
#   1. pre-check: open, status:ready, ZERO assignees (any assignee = stop —
#      that's how human UI claims are respected; humans never post CLAIM)
#   2. post `CLAIM <actor> <run-id> <ts>`
#   3. re-read: earliest *live* CLAIM comment wins; loser withdraws. "Live"
#      excludes claims voided by a later RECLAIMED or a matching CLAIM-WITHDRAWN
#      (see lib/claim-winner.jq), so a reclaimed task can be claimed afresh.
#   3b. orphan reap: if we lost but the issue is still status:ready with zero
#      assignees and the blocking claim is older than the grace window, its
#      claimant died before converting to status:claimed — an orphan poison-
#      pilling the lock (issue #64). Withdraw it on its behalf and re-arbitrate.
#   4. post-edit sanity: if a human raced in as a second assignee, withdraw
#
# Exit 0 = you own the task. Exit 1 = not claimable / lost the race (75 = a
# local backend's lock was busy: retry).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N=${1:?usage: claim-task.sh <issue#> <actor>}
ACTOR=${2:?usage: claim-task.sh <issue#> <actor>}
RUN_ID="$(hostname -s)-$$-$(date +%s)"

bash "$SCRIPT_DIR/graph.sh" claim "$N" "$ACTOR" --run "$RUN_ID"

echo "claimed #$N as $ACTOR ($RUN_ID)"
