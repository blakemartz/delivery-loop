#!/usr/bin/env bash
# Regression tests for scripts/lib/orphan-claims.jq — the orphan-claim reaper.
#
# Feeds synthetic comment ledgers (no GitHub calls) plus a grace cutoff to the
# pure selection logic and asserts which CLAIMs are reaped. Guards issue #64: an
# orphan CLAIM whose claimant died before converting to status:claimed has
# neither a CLAIM-WITHDRAWN nor a RECLAIMED, so it stayed the earliest live claim
# forever and poison-pilled the Lamport lock.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib"
filter="$lib/orphan-claims.jq"

# Grace boundary shared by the cases below: 08:00:30Z. Claims before it are older
# than the window (orphans); claims at/after it are still within grace.
cutoff=$(jq -n '"2026-07-02T08:00:30Z" | fromdateiso8601')

fails=0
check() {
  local name="$1" ledger="$2" expected="$3" got
  got=$(jq -r -L "$lib" --argjson cutoffEpoch "$cutoff" -f "$filter" <<<"$ledger")
  if [ "$got" = "$expected" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name" >&2
    echo "        expected: [$expected]" >&2
    echo "        got:      [$got]" >&2
    fails=1
  fi
}

# (a) a lone CLAIM older than the grace window is an orphan -> reaped.
check "old unconverted claim -> reaped" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"}
  ]
}' "agent-A run-A"

# (b) a CLAIM still inside the grace window may yet convert -> not reaped.
check "fresh claim within grace -> not reaped" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:01:00Z", "createdAt": "2026-07-02T08:01:00Z"}
  ]
}' ""

# (c) an already-withdrawn claim is not live -> never reaped again (no dup).
check "withdrawn old claim -> not reaped" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"},
    {"body": "CLAIM-WITHDRAWN agent-A run-A (lost to earlier claim)", "createdAt": "2026-07-02T08:00:01Z"}
  ]
}' ""

# (d) a pre-reclaim claim is void; only the live post-reclaim orphan is reaped.
check "pre-reclaim claim excluded; post-reclaim orphan reaped" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T07:00:00Z", "createdAt": "2026-07-02T07:00:00Z"},
    {"body": "RECLAIMED: agent claim was idle >4h with no open PR; task is ready again.", "createdAt": "2026-07-02T07:30:00Z"},
    {"body": "CLAIM agent-C run-C 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"}
  ]
}' "agent-C run-C"

# (e) several stacked orphans are all reaped, oldest first.
check "multiple orphans -> all reaped oldest first" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"},
    {"body": "CLAIM agent-B run-B 2026-07-02T08:00:10Z", "createdAt": "2026-07-02T08:00:10Z"}
  ]
}' "agent-A run-A
agent-B run-B"

# (f) an old orphan alongside a live racer: only the orphan is reaped; the racer
#     (within grace) keeps its shot and arbitrates normally afterward.
check "old orphan + fresh racer -> only orphan reaped" '{
  "comments": [
    {"body": "CLAIM agent-A run-A 2026-07-02T08:00:00Z", "createdAt": "2026-07-02T08:00:00Z"},
    {"body": "CLAIM agent-B run-B 2026-07-02T08:01:00Z", "createdAt": "2026-07-02T08:01:00Z"}
  ]
}' "agent-A run-A"

if [ "$fails" -ne 0 ]; then
  echo "orphan-claims tests FAILED" >&2
  exit 1
fi
echo "orphan-claims tests passed"
