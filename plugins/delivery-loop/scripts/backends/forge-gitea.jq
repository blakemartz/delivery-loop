# forge-gitea.jq — normalize Gitea / Forgejo REST JSON onto the forge-neutral
# shapes (docs/delivery_graph_spec.md §4.2, §4.3, §7.3 gitea/forgejo column).
#
# Pure: no I/O. Used by backends/forge-gitea.sh with `-L lib -L backends`.
#
#   gt_pr($graph_backend)  — {pr, status, comments, reviews} → a §4.2 PR, built
#                            field by field and passed through validate_pr. `pr` is
#                            one PullRequest, `statuses` every CommitStatus of its
#                            head (all pages), `comments`/`reviews` the issue
#                            comments and PullReviews.
#   gt_mergeable_computing — a PullRequest whose mergeability is still unknown
#                            (open, `mergeable` absent/null), so a re-poll can help.
#   gt_checks              — [CommitStatus] (every page) → success|pending|failure|none.
#   gt_reviews($comments)  — [PullReview] → [{author, verdict, body, at, commit}]:
#                            every review, then every verdict-headed issue comment
#                            of $comments ([Comment]; forge-verdict.jq).
#   gt_comments            — [Comment] → [{author, body, at, url}]
#   gt_older_than($t)      — a list page holds a PR updated before ISO-8601 $t
#                            (the stop rule of the `--since` merged feed).
#   gt_merged              — keep merged PRs (`merged == true`).
#   gt_merged_since($t)    — keep PRs merged at or after ISO-8601 $t.
#
# The §4.3 linkage precedence, `patch_iteration`, `reviewed_at_head` and the
# ISO-8601 parser are forge-neutral rules: they are reused from forge-github.jq
# (fed github-named fields) rather than restated, so the two adapters cannot drift.
include "pr";
include "shape";
include "forge-github";
include "forge-verdict";

# Gitea substitutes its "Ghost" user for a deleted account; a missing user still
# gets the §4.2 placeholder login.
def _gt_login: (if type == "object" then .login else null end) // "" | if . == "" then "ghost" else . end;

# §7.3 state: `merged == true` → merged; else `state` open/closed.
def gt_state:
  if .merged == true then "merged"
  else {"open": "open", "closed": "closed"}[.state // ""]
       // error("unknown gitea PR state \(.state | tojson)") end;

# §7.3 mergeable: true → clean, false → conflicting, absent/null → unknown.
# Only `true` is clean, so `unknown` is never mergeable.
def gt_mergeable:
  if .mergeable == true then "clean"
  elif .mergeable == false then "conflicting"
  else "unknown" end;

def gt_mergeable_computing:
  .state == "open" and .merged != true and .mergeable == null;

# §7.3 checks, rolled up here over every `statuses[].status` of the head commit
# (all pages of GET /commits/{sha}/status). The server's `state`/`total_count`
# cover only the returned page, so they are never read. No statuses → none; any
# error/failure → failure; else any pending or unrecognized status → pending
# (never success); else (every one success/warning/skipped) → success.
def gt_checks:
  [ .[] | .status // "" ] as $s
  | if ($s | length) == 0 then "none"
    elif any($s[]; . == "error" or . == "failure") then "failure"
    elif all($s[]; . == "success" or . == "warning" or . == "skipped") then "success"
    else "pending" end;

def gt_pr($graph_backend):
  .pr as $p
  | (.comments // []) as $comments
  | (.reviews // []) as $reviews
  | ([ ($p.labels // [])[] | .name ]) as $labels
  | { number: $p.number,
      url: $p.html_url,
      state: ($p | gt_state),
      head: $p.head.ref,
      base: $p.base.ref,
      head_sha: $p.head.sha,
      mergeable: ($p | gt_mergeable),
      checks: ((.statuses // []) | gt_checks),
      task_id: ({body: ($p.body // ""), headRefName: ($p.head.ref // "")} | gh_task_id($graph_backend)),
      labels: $labels,
      patch_iteration: ({comments: $comments} | gh_patch_iteration),
      reviewed_at_head: ({headRefOid: $p.head.sha, reviews: $reviews, comments: $comments} | gh_reviewed_at_head),
      agent: ($labels | any(.[]; . == agent_label)),
      author: ($p.user | _gt_login) }
  | validate_pr;

# A dismissed review is reported as `dismissed`, as github's DISMISSED state is.
def gt_reviews($comments):
  [ .[]
    | { author: (.user | _gt_login),
        verdict: (if .dismissed == true then "dismissed"
                  else {"APPROVED": "approve", "REQUEST_CHANGES": "request-changes",
                        "COMMENT": "comment", "PENDING": "pending",
                        "REQUEST_REVIEW": "request-review"}[.state // ""]
                       // (.state // "" | ascii_downcase) end),
        body: (.body // ""),
        at: .submitted_at,
        commit: (.commit_id // null) } ]
  + ([ ($comments // [])[] | {author: (.user | _gt_login), body: (.body // ""), at: .created_at} ]
     | verdict_comments);
def gt_reviews: gt_reviews([]);

def gt_comments:
  [ .[] | { author: (.user | _gt_login), body: (.body // ""), at: .created_at, url: (.html_url // null) } ];

def gt_older_than($t):
  ($t | iso_epoch) as $cut
  | any(.[]; (.updated_at | iso_epoch) < $cut);

def gt_merged: map(select(.merged == true));

def gt_merged_since($t):
  ($t | iso_epoch) as $cut
  | map(select(.merged == true and .merged_at != null and (.merged_at | iso_epoch) >= $cut));
