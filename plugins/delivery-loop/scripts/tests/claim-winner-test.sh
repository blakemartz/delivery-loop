#!/usr/bin/env bash
# Regression tests for scripts/lib/claim-winner.jq — the claim-race arbiter.
#
# Feeds synthetic comment ledgers to the pure selection logic (no GitHub calls)
# and asserts which CLAIM wins. Guards issue #60: once a task was reclaimed, the
# original (now-void) CLAIM kept winning every future race, so the task became
# permanently unclaimable through the sanctioned path.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib"
filter="$lib/claim-winner.jq"

fails=0
check() {
  local name="$1" ledger="$2" expected="$3" got
  got=$(jq -r -L "$lib" -f "$filter" <<<"$ledger")
  if [ "$got" = "$expected" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name" >&2
    echo "        expected: [$expected]" >&2
    echo "        got:      [$got]" >&2
    fails=1
  fi
}

# (a) normal two-actor race: the earliest CLAIM wins, the loser withdraws.
check "fresh two-actor race -> earliest claim wins" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"},
    {"body": "CLAIM agent-B run-B 2026-07-02T08:00:05Z", "createdAt": "2026-07-02T08:00:05Z"},
    {"body": "CLAIM-WITHDRAWN agent-B run-B (lost to earlier claim)", "createdAt": "2026-07-02T08:00:06Z"}
  ]
}' "CLAIM agent-A run-A 2026-07-02T08:00:00Z"

# (b) post-RECLAIMED re-claim: the pre-reclaim CLAIM is void even though it is
#     still the earliest CLAIM comment, so the fresh post-reclaim claim wins.
check "post-reclaim re-claim -> fresh claim wins (issue #60)" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:20:26Z", "createdAt": "2026-07-02T08:20:26Z"},
    {"body": "RECLAIMED: agent claim was idle >4h with no open PR; task is ready again.", "createdAt": "2026-07-02T12:24:00Z"},
    {"body": "CLAIM agent-C run-C 2026-07-02T13:00:00Z", "createdAt": "2026-07-02T13:00:00Z"}
  ]
}' "CLAIM agent-C run-C 2026-07-02T13:00:00Z"

# (c) withdrawn loser: the earliest CLAIM was withdrawn, so the next live CLAIM
#     wins rather than the withdrawn one.
check "withdrawn earliest -> next live claim wins" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"},
    {"body": "CLAIM-WITHDRAWN agent-A run-A (another assignee appeared — yielding)", "createdAt": "2026-07-02T08:00:01Z"},
    {"body": "CLAIM agent-B run-B 2026-07-02T08:00:05Z", "createdAt": "2026-07-02T08:00:05Z"}
  ]
}' "CLAIM agent-B run-B 2026-07-02T08:00:05Z"

# Edge: a reclaim with no subsequent claim yields no winner, so a fresh
# claimant sees "" (does not lose to the void claim) and proceeds to own it.
check "reclaimed with no re-claim -> no winner" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"},
    {"body": "RECLAIMED: agent claim was idle >4h with no open PR; task is ready again.", "createdAt": "2026-07-02T12:24:00Z"}
  ]
}' ""

if [ "$fails" -ne 0 ]; then
  echo "claim-winner tests FAILED" >&2
  exit 1
fi
echo "claim-winner tests passed"
