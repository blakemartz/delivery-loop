# forge-gitlab.jq — normalize GitLab REST v4 JSON onto the forge-neutral shapes
# (docs/delivery_graph_spec.md §4.2, §4.3, §7.3 gitlab column).
#
# Pure: no I/O. Used by backends/forge-gitlab.sh with `-L lib -L backends`.
#
#   gl_pr($graph_backend)  — {mr, notes} → a §4.2 PR, built field by field and
#                            passed through validate_pr. `mr` is one single-MR GET
#                            (the only response carrying `head_pipeline`), `notes`
#                            every note of it (all pages).
#   gl_mergeable_computing — an open MR whose `detailed_merge_status` is still being
#                            computed (or absent), so a re-poll can help.
#   gl_mergeable           — detailed_merge_status → clean|conflicting|blocked|unknown.
#   gl_checks              — a single-MR GET → success|pending|failure|none.
#   gl_reviews($approvals) — [Note] → [{author, verdict, body, at, commit}]: every
#                            approval of $approvals (GET …/approvals), then every
#                            verdict-headed, non-system note.
#   gl_comments($web_url)  — [Note] → [{author, body, at, url}], system notes dropped.
#   gl_merged_since($t)    — keep MRs merged at or after ISO-8601 $t.
#   gl_unified_diff        — [MR diff] (GET …/diffs) → a unified diff text.
#
# The §4.3 linkage precedence, `patch_iteration`, `reviewed_at_head` and the
# ISO-8601 parser are forge-neutral rules: they are reused from forge-github.jq
# (fed github-named fields) rather than restated, so the adapters cannot drift.
include "pr";
include "shape";
include "forge-github";

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
# A head_pipeline built for another commit than the MR head says nothing about
# this head, so it is pending.
def gl_checks:
  .sha as $sha
  | .head_pipeline as $p
  | if $p == null then "none"
    elif ($p.sha // $sha) != $sha then "pending"
    elif $p.status == "success" then "success"
    elif ($p.status // "") | is_enum(["failed", "canceled", "canceling"]) then "failure"
    else "pending" end;

def _gl_human_notes: map(select(.system != true));

def gl_pr($graph_backend):
  .mr as $m
  | ((.notes // []) | _gl_human_notes) as $notes
  | ([ ($m.labels // [])[] | if type == "object" then .name else . end ]) as $labels
  | { number: $m.iid,
      url: $m.web_url,
      state: ($m | gl_state),
      head: $m.source_branch,
      base: $m.target_branch,
      head_sha: $m.sha,
      mergeable: ($m | gl_mergeable),
      checks: ($m | gl_checks),
      task_id: ({body: ($m.description // ""), headRefName: ($m.source_branch // "")} | gh_task_id($graph_backend)),
      labels: $labels,
      patch_iteration: ({comments: $notes} | gh_patch_iteration),
      reviewed_at_head: ({headRefOid: $m.sha, reviews: [], comments: $notes} | gh_reviewed_at_head),
      agent: ($labels | any(.[]; . == agent_label)),
      author: ($m.author | _gl_login) }
  | validate_pr;

# The verdict heading every review note opens with (§7.3), and its verdict.
def gl_verdict_heading: "## Adversarial review — verdict: ";
def _gl_note_verdict:
  (.body // "" | split("\n") | map(rtrimstr("\r")) | map(select(test("\\S"))) | first // "") as $l
  | if $l | startswith(gl_verdict_heading)
    then ($l | ltrimstr(gl_verdict_heading) | capture("^(?<v>[A-Za-z_]+)").v // ""
          | {"APPROVE": "approve", "REQUEST_CHANGES": "request-changes", "COMMENT": "comment"}[ascii_upcase]
            // ascii_downcase)
    else null end;

# The head a note's `Reviewed-Head:` trailer ties it to, else null.
def _gl_note_commit:
  first(.body // "" | split("\n")[] | rtrimstr("\r")
        | capture("^Reviewed-Head:[ \t]*(?<sha>[0-9A-Fa-f]+)[ \t]*$").sha) // null;

def gl_reviews($approvals):
  [ ($approvals.approved_by // [])[]
    | { author: (.user | _gl_login), verdict: "approve", body: "",
        at: (.approved_at // null), commit: null } ]
  + [ _gl_human_notes[]
      | _gl_note_verdict as $v
      | select($v != null)
      | { author: (.author | _gl_login), verdict: $v, body: (.body // ""),
          at: .created_at, commit: _gl_note_commit } ];

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
