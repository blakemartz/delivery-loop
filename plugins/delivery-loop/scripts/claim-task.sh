#!/usr/bin/env bash
# claim-task.sh <issue#> <actor> — atomically-enough claim a ready task.
#
# `gh issue edit --add-assignee` is not test-and-set, but GitHub comments are
# server-ordered, so comment ordering arbitrates races (a cheap Lamport lock):
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
# Exit 0 = you own the task. Exit 1 = not claimable / lost the race.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N=${1:?usage: claim-task.sh <issue#> <actor>}
ACTOR=${2:?usage: claim-task.sh <issue#> <actor>}
RUN_ID="$(hostname -s)-$$-$(date +%s)"

info=$(gh issue view "$N" --json state,assignees,labels)
state=$(jq -r '.state' <<<"$info")
n_assignees=$(jq '.assignees | length' <<<"$info")
is_ready=$(jq '[.labels[].name] | index("status:ready") != null' <<<"$info")

[ "$state" = "OPEN" ]    || { echo "not claimable: #$N is $state" >&2; exit 1; }
[ "$n_assignees" = "0" ] || { echo "not claimable: #$N already has an assignee" >&2; exit 1; }
[ "$is_ready" = "true" ] || { echo "not claimable: #$N is not status:ready" >&2; exit 1; }

gh issue comment "$N" --body "CLAIM $ACTOR $RUN_ID $(date -u +%FT%TZ)" >/dev/null

# Earliest *live* CLAIM comment wins. The selection logic (which ignores claims
# voided by a later RECLAIMED or a matching CLAIM-WITHDRAWN) lives in
# lib/claim-winner.jq so it can be unit-tested against synthetic ledgers.
arbitrate() {
  gh issue view "$N" --json comments \
    | jq -r -L "$SCRIPT_DIR/lib" -f "$SCRIPT_DIR/lib/claim-winner.jq"
}
winner=$(arbitrate)

# If we lost, we may have lost to an ORPHAN: a CLAIM whose claimant died before
# converting it to status:claimed. A live winner converts within seconds, so if
# the issue is STILL status:ready with zero assignees and the blocking claim is
# older than the grace window, it never will — it is poison-pilling the lock
# (issue #64). Reap every such orphan via CLAIM-WITHDRAWN (the ledger's own
# stand-down path, which claim-winner.jq already honors) and re-arbitrate.
if [[ "$winner" != "CLAIM $ACTOR $RUN_ID"* ]]; then
  grace=${CLAIM_GRACE_SECONDS:-90}
  cutoff=$(( $(date +%s) - grace ))
  snapshot=$(gh issue view "$N" --json assignees,labels,comments)
  unconverted=$(jq -r \
    '(.assignees | length == 0) and ([.labels[].name] | index("status:ready") != null)' \
    <<<"$snapshot")
  if [ "$unconverted" = "true" ]; then
    orphans=$(jq -r -L "$SCRIPT_DIR/lib" --argjson cutoffEpoch "$cutoff" \
      -f "$SCRIPT_DIR/lib/orphan-claims.jq" <<<"$snapshot")
    if [ -n "$orphans" ]; then
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        gh issue comment "$N" --body \
          "CLAIM-WITHDRAWN $key (orphaned: claim never converted to status:claimed within ${grace}s; reaped by $ACTOR $RUN_ID)" >/dev/null
        echo "reaped orphan claim on #$N: $key" >&2
      done <<<"$orphans"
      winner=$(arbitrate)
    fi
  fi
fi

if [[ "$winner" != "CLAIM $ACTOR $RUN_ID"* ]]; then
  gh issue comment "$N" --body "CLAIM-WITHDRAWN $ACTOR $RUN_ID (lost to earlier claim)" >/dev/null
  echo "lost claim race for #$N (winner: $winner)" >&2
  exit 1
fi

gh issue edit "$N" --add-assignee "@me" \
  --add-label "status:claimed" --add-label "claim:agent" \
  --remove-label "status:ready" >/dev/null

# Post-edit sanity: a human may have self-assigned between pre-check and edit.
n_after=$(gh issue view "$N" --json assignees --jq '.assignees | length')
if [ "$n_after" != "1" ]; then
  me=$(gh api user --jq .login)
  gh issue edit "$N" --remove-assignee "$me" \
    --remove-label "status:claimed" --remove-label "claim:agent" >/dev/null
  gh issue comment "$N" --body "CLAIM-WITHDRAWN $ACTOR $RUN_ID (another assignee appeared — yielding)" >/dev/null
  echo "withdrew claim on #$N: another assignee appeared" >&2
  exit 1
fi

echo "claimed #$N as $ACTOR ($RUN_ID)"
