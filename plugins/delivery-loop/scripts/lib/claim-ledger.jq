# claim-ledger.jq — shared helpers for reading an issue's CLAIM comment ledger.
#
# Included (jq module) by both claim-winner.jq (the race arbiter) and
# orphan-claims.jq (the orphan reaper) so the definition of a "live" claim lives
# in exactly one place. Input is the `gh issue view <n> --json comments` object:
#   {"comments": [{"body": "...", "createdAt": "..."}, ...]}
# See docs/agentic_delivery_spec.md §5.1 and §7.2.

# createdAt of the most recent RECLAIMED comment ("" if the ledger has none):
# every live claim must have been posted strictly after it. task-queue.sh --fix
# releases a stale agent claim by resetting the issue's labels/assignee and
# posting RECLAIMED, but it leaves the original CLAIM comment in place, so the
# reclaim timestamp is what voids the pre-reclaim claim.
def reclaimed_at:
  [ .comments[] | select(.body | startswith("RECLAIMED")) | .createdAt ]
  | max // "";

# "<actor> <run-id>" key of every withdrawal, so the matching CLAIM can be
# dropped. A claimant posts CLAIM-WITHDRAWN when it loses an earlier-CLAIM race
# or yields to a human; a third party posts it to reap an orphan (§7.2).
def withdrawn_keys:
  [ .comments[]
    | select(.body | startswith("CLAIM-WITHDRAWN "))
    | (.body | split(" ")) | "\(.[1]) \(.[2])" ];

# The raw CLAIM comments still live: not voided by a later RECLAIMED and not
# matched by a CLAIM-WITHDRAWN. Unsorted — callers order as they need. ISO-8601
# UTC timestamps ("...Z") sort lexicographically, so comparing createdAt as
# strings is correct.
def live_claims:
  reclaimed_at as $reclaimedAt
  | withdrawn_keys as $withdrawn
  | [ .comments[]
      | select(.body | startswith("CLAIM "))   # raw claims only ("CLAIM " excludes CLAIM-WITHDRAWN)
      | select(.createdAt > $reclaimedAt)       # survive the latest reclaim ("" keeps all)
      | select(                                 # was not withdrawn
          ((.body | split(" ")) | "\(.[1]) \(.[2])") as $k
          | $withdrawn | index($k) | not
        )
    ];
