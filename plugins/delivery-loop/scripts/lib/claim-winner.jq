# claim-winner.jq — arbitrate a claim race from an issue's comment ledger.
#
# Input:  the `gh issue view <n> --json comments` object, i.e.
#         {"comments": [{"body": "...", "createdAt": "..."}, ...]}.
# Output: the body of the earliest *live* `CLAIM ` comment, or "" if none.
#
# "Live" — not voided by a later RECLAIMED and not matched by a CLAIM-WITHDRAWN —
# is defined once in claim-ledger.jq (shared with orphan-claims.jq). The winner
# is the earliest such claim. Requires the lib dir on jq's search path:
#   jq -L scripts/lib -f scripts/lib/claim-winner.jq
include "claim-ledger";

live_claims | sort_by(.createdAt) | .[0].body // ""
