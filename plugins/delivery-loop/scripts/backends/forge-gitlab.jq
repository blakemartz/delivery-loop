# forge-gitlab.jq — normalize GitLab REST v4 JSON onto the forge-neutral shapes
# (docs/delivery_graph_spec.md §4.2, §4.3, §7.3 gitlab column).
#
# Pure: no I/O. Used by backends/forge-gitlab.sh with `-L lib -L backends`.
#
#   gl_pr($graph_backend)  — {mr, notes, merge_parents} → a §4.2 PR, built field by field and
#                            passed through validate_pr. `mr` is one single-MR GET
#                            (the only response carrying `head_pipeline`), `notes`
#                            every note of it (all pages), `merge_parents` the
#                            `parent_ids` of a `/merge` head_pipeline's commit
#                            (absent/null when not read).
#   gl_mergeable_computing — an open MR whose `detailed_merge_status` is still being
#                            computed (or absent), so a re-poll can help.
#   gl_mergeable           — detailed_merge_status → clean|conflicting|blocked|unknown.
#   gl_checks($parents)    — a single-MR GET → success|pending|failure|none.
#                            $parents: the `parent_ids` of a merged-results
#                            pipeline's commit, or null when not read.
#   gl_reviews($approvals) — [Note] (system notes included) → [{author, verdict,
#                            body, at, commit}]: every approval of $approvals
#                            (GET …/approvals), then every verdict-headed,
#                            non-system note (forge-verdict.jq). An APPROVE note
#                            whose author revoked the approval afterwards is
#                            reported as `dismissed`.
#   gl_comments($web_url)  — [Note] → [{author, body, at, url}], system notes dropped.
#   gl_merged_since($t)    — keep MRs merged at or after ISO-8601 $t.
#   gl_unified_diff        — [MR diff] (GET …/diffs) → a unified diff text.
#
# The §4.3 linkage precedence, `patch_iteration`, `reviewed_at_head` and the
# ISO-8601 parser are forge-neutral rules: they are reused from forge-github.jq
# (fed github-named fields) rather than restated, so the adapters cannot drift.
# `verdict_at_head`, `approved_at_head` and `approved_head_sha` are
# forge-verdict.jq's rules over the MR's verdict notes (`gl_reviews`): an
# approval itself has no body, so the APPROVE-headed note that `pr-review
# approve` always posts is what ties it to a head.
#
# A revoked approval leaves that note behind. GitLab records the revocation as a
# system note by the revoking user, `unapproved this merge request`; an APPROVE
# note is `dismissed` (as a dismissed github or gitea review is) when its author
# has such a system note at or after it. A note or a revocation with an
# unreadable timestamp counts as revoked, so the doubt never leaves an approval
# standing. A later `pr-review approve` posts a new note, which stands.
include "pr";
include "shape";
include "forge-github";
include "forge-verdict";

# GitLab reassigns a deleted account's content to its "Ghost User" (username
# `ghost`); a missing author still gets the §4.2 placeholder login.
def _gl_login: (if type == "object" then .username else null end) // "" | if . == "" then "ghost" else . end;

# §7.3 state: opened → open, merged → merged, closed/locked → closed.
def gl_state:
  {"opened": "open", "merged": "merged", "closed": "closed", "locked": "closed"}[.state // ""]
  // error("unknown gitlab MR state \(.state | tojson)");

# The detailed_merge_status values GitLab is still computing (§7.3: re-poll).
def gl_async_merge_statuses:
  ["unchecked", "checking", "preparing", "approvals_syncing", "ci_still_running"];

# §7.3 mergeable. Only `mergeable` is clean, so `unknown` is never merged; an
# absent/null status (servers before 15.6) is unknown too.
def gl_mergeable:
  (.detailed_merge_status // null) as $s
  | if $s == "mergeable" then "clean"
    elif $s == "conflict" or $s == "need_rebase" then "conflicting"
    elif $s == null or ($s | is_enum(gl_async_merge_statuses)) then "unknown"
    else "blocked" end;

def gl_mergeable_computing:
  .state == "opened" and ((.detailed_merge_status // null) as $s
                          | $s == null or ($s | is_enum(gl_async_merge_statuses)));

# §7.3 checks, from `head_pipeline.status`: the pipeline's own roll-up over all of
# its jobs (no page of jobs is ever read for it). success → success;
# failed/canceled/canceling → failure; no pipeline → none; anything else
# (created, pending, running, manual, skipped, …) → pending, never success.
#
# Which commit the pipeline ran on depends on its ref:
#   - a merged-results pipeline (`refs/merge-requests/<iid>/merge`) runs on a
#     synthetic merge commit, so its `sha` is never the MR head. GitLab reports
#     the raw `head_pipeline`, not the head-checked `diff_head_pipeline`: right
#     after a push, the previous head's merged-results pipeline can still be the
#     head_pipeline until one exists for the new head. So its status counts only
#     when the MR head is a parent of that merge commit ($parents, the commit's
#     `parent_ids`); unread ($parents null) or not a parent → pending;
#   - a merge-train pipeline (`…/<iid>/train`) is taken as is;
#   - a branch pipeline (ref = the source branch, or `refs/merge-requests/<iid>/head`)
#     runs on the head itself: one built for another commit says nothing about
#     this head, so it is pending. Any other ref is held to the same rule.
def gl_merge_result_ref($iid): (.ref // "") == "refs/merge-requests/\($iid)/merge";
def gl_merge_ref_pipeline($iid):
  (.ref // "") as $r
  | $r == "refs/merge-requests/\($iid)/merge" or $r == "refs/merge-requests/\($iid)/train";

def gl_checks($parents):
  .sha as $sha
  | .iid as $iid
  | .head_pipeline as $p
  | if $p == null then "none"
    elif ($p | gl_merge_ref_pipeline($iid) | not) and ($p.sha // $sha) != $sha then "pending"
    elif ($p | gl_merge_result_ref($iid))
         and (($parents | type) != "array" or (any($parents[]; . == $sha) | not)) then "pending"
    elif $p.status == "success" then "success"
    elif ($p.status // "") | is_enum(["failed", "canceled", "canceling"]) then "failure"
    else "pending" end;
def gl_checks: gl_checks(null);

def _gl_human_notes: map(select(.system != true));

# [Note] → [{author, at}]: each revocation of an approval, from its system note.
def gl_revocations:
  [ .[] | select(.system == true and ((.body // "") | test("^unapproved this merge request")))
    | {author: (.author | _gl_login), at: (.created_at | verdict_time)} ];

# Input: a verdict entry. True when one of $revocations, by its author, is not
# before it.
def _gl_revoked($revocations):
  .author as $who
  | (.at | verdict_time) as $t
  | any($revocations[]; .author == $who and ($t == null or .at == null or .at >= $t));

# Approvals first, then every verdict-headed, non-system note (the shared
# forge-verdict rule: `verdict` from the heading, `commit` from the trailer).
def gl_reviews($approvals):
  gl_revocations as $revocations
  | [ ($approvals.approved_by // [])[]
      | { author: (.user | _gl_login), verdict: "approve", body: "",
          at: (.approved_at // null), commit: null } ]
    + ([ _gl_human_notes[] | {author: (.author | _gl_login), body: (.body // ""), at: .created_at} ]
       | verdict_comments
       | map(if .verdict == "approve" and _gl_revoked($revocations) then .verdict = "dismissed" else . end));

def gl_pr($graph_backend):
  .mr as $m
  | (.merge_parents // null) as $parents
  | (.notes // []) as $all_notes
  | ($all_notes | _gl_human_notes) as $notes
  | ($all_notes | gl_reviews(null)) as $reviews
  | ([ ($m.labels // [])[] | if type == "object" then .name else . end ]) as $labels
  | { number: $m.iid,
      url: $m.web_url,
      state: ($m | gl_state),
      head: $m.source_branch,
      base: $m.target_branch,
      head_sha: $m.sha,
      mergeable: ($m | gl_mergeable),
      checks: ($m | gl_checks($parents)),
      task_id: ({body: ($m.description // ""), headRefName: ($m.source_branch // "")} | gh_task_id($graph_backend)),
      labels: $labels,
      patch_iteration: ({comments: $notes} | gh_patch_iteration),
      reviewed_at_head: ({headRefOid: $m.sha, reviews: [], comments: $notes} | gh_reviewed_at_head),
      approved_at_head: ($reviews | approved_at_head($m.sha)),
      verdict_at_head: ($reviews | verdict_at_head($m.sha)),
      approved_head_sha: ($reviews | approved_head_sha($m.sha)),
      agent: ($labels | any(.[]; . == agent_label)),
      author: ($m.author | _gl_login) }
  | validate_pr;

# Notes carry no URL of their own: GitLab anchors them on the MR page as #note_<id>.
def gl_comments($web_url):
  [ _gl_human_notes[]
    | { author: (.author | _gl_login), body: (.body // ""), at: .created_at,
        url: (if $web_url == "" then null else "\($web_url)#note_\(.id)" end) } ];

def gl_merged_since($t):
  ($t | iso_epoch) as $cut
  | map(select(.state == "merged" and .merged_at != null and (.merged_at | iso_epoch) >= $cut));

# GET …/diffs returns hunks without file headers: rebuild `diff --git` headers.
def gl_unified_diff:
  map( "diff --git a/\(.old_path) b/\(.new_path)\n"
       + (if .new_file == true then "new file mode \(.b_mode // "100644")\n"
          elif .deleted_file == true then "deleted file mode \(.a_mode // "100644")\n"
          elif .renamed_file == true then "rename from \(.old_path)\nrename to \(.new_path)\n"
          else "" end)
       + (if (.diff // "") == "" then ""
          else "--- \(if .new_file == true then "/dev/null" else "a/\(.old_path)" end)\n"
               + "+++ \(if .deleted_file == true then "/dev/null" else "b/\(.new_path)" end)\n"
               + (.diff | if endswith("\n") then . else . + "\n" end) end) )
  | join("");
