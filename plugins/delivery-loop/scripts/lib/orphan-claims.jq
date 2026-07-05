# orphan-claims.jq — identify orphaned CLAIMs poison-pilling the claim lock.
#
# An orphan is a *live* CLAIM whose claimant died before converting it to
# status:claimed (never assigned itself, never posted CLAIM-WITHDRAWN, was never
# RECLAIMED). It stays the earliest live claim forever, so claim-winner.jq keeps
# handing it the win and every fresh claimer loses — the task is un-claimable
# (issue #64).
#
# Input:  the `gh issue view <n> --json comments` object.
# Arg:    --argjson cutoffEpoch <unix-seconds> — the grace boundary.
# Output: the "<actor> <run-id>" key of every live claim posted before the
#         cutoff, oldest first, one per line (empty when there is none).
#
# A live winner converts within seconds, so caller (claim-task.sh §7.2) only
# consults this when the issue is STILL status:ready with zero assignees — i.e.
# nothing ever converted — and treats any live claim older than the grace window
# as an orphan to reap via CLAIM-WITHDRAWN. Requires the lib dir on jq's search
# path: jq -L scripts/lib --argjson cutoffEpoch N -f scripts/lib/orphan-claims.jq
include "claim-ledger";

live_claims
| map(select((.createdAt | fromdateiso8601) < $cutoffEpoch))
| sort_by(.createdAt)
| .[]
| (.body | split(" ")) | "\(.[1]) \(.[2])"
