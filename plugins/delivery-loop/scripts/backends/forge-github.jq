# forge-github.jq — normalize `gh` JSON onto the forge-neutral shapes
# (docs/delivery_graph_spec.md §4.2, §4.3, §7.3 github column).
#
# Pure: no I/O. Used by backends/forge-github.sh with `-L lib -L backends`.
#
#   gh_pr($graph_backend)  — one `gh pr view --json …` object → a §4.2 PR, built
#                            field by field and passed through validate_pr.
#   gh_reviews             — `gh pr view --json reviews,comments` → [{author, verdict, body, at, commit}]:
#                            every formal review, then every verdict-headed comment
#                            (forge-verdict.jq).
#   gh_comments            — `gh pr view --json comments` → [{author, body, at, url}]
#   gh_merged_since($t)    — keep list elements whose `mergedAt` ≥ ISO-8601 $t
#
# Line-oriented regexes split on "\n" first: jq's Oniguruma `^`/`$` do not
# reliably anchor at line boundaries.
include "pr";
include "shape";
include "forge-verdict";

def _lines: (. // "") | split("\n") | map(rtrimstr("\r"));

# A deleted account comes back as a null author; §4.2 wants the placeholder login.
def _login: (.login // "") | if . == "" then "ghost" else . end;

# §7.3 state: OPEN/MERGED/CLOSED.
def gh_state:
  {"OPEN": "open", "MERGED": "merged", "CLOSED": "closed"}[.state]
  // error("unknown gh PR state \(.state | tojson)");

# §7.3 mergeable, from mergeStateStatus. Everything not listed (UNKNOWN while
# GitHub computes, DRAFT, HAS_HOOKS, null) is `unknown`, which is never merged.
def gh_mergeable:
  {"CLEAN": "clean", "DIRTY": "conflicting",
   "BLOCKED": "blocked", "UNSTABLE": "blocked", "BEHIND": "blocked"}[.mergeStateStatus // ""]
  // "unknown";

# True when GitHub is still computing mergeability, so a re-poll can help.
def gh_mergeable_computing:
  .state == "OPEN" and ((.mergeStateStatus // "UNKNOWN") == "UNKNOWN");

# §7.3 checks, rolled up over statusCheckRollup. A CheckRun's outcome is its
# `conclusion` once `status` is COMPLETED (pending before); a StatusContext's is
# its `state`. Any failure wins; all success-like → success; else pending.
def gh_checks:
  [ (.statusCheckRollup // [])[]
    | if has("conclusion") or .__typename == "CheckRun"
      then (if (.status // "COMPLETED") == "COMPLETED" then (.conclusion // "") else "PENDING" end)
      else (.state // "")
      end ] as $o
  | if ($o | length) == 0 then "none"
    elif any($o[]; is_enum(["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"])) then "failure"
    elif all($o[]; is_enum(["SUCCESS", "NEUTRAL", "SKIPPED"])) then "success"
    else "pending" end;

# §4.3 linkage precedence (GC33, GC46): trailer, then (github graph only) the
# first closing-keyword line, then the v0.2 head branch, then the legacy one.
def gh_task_id($graph_backend):
  def _first(f): first(f) // null;
  (.body | _lines) as $lines
  | (.headRefName // "") as $head
  | _first($lines[] | capture("^Delivery-Task:[ \t]*(?<id>[a-z0-9]+(-[a-z0-9]+)*)[ \t]*$").id)
    // (if $graph_backend == "github"
        then _first($lines[] | capture("^[ \t]*(closes|fixes|resolves)[ \t]+#(?<id>[0-9]+)\\b"; "i").id)
        else null end)
    // _first($head | capture("^task/(?<id>[a-z0-9]+(-[a-z0-9]+)*)--").id)
    // _first($head | capture("^task/(?<id>[0-9]+)-").id)
    | if . != null and is_node_id then . else null end;

# Highest `Patch iteration: n/m` across the PR comments (0 if none).
def gh_patch_iteration:
  [ (.comments // [])[] | .body | _lines[]
    | capture("^[ \t]*Patch iteration:[ \t]*(?<n>[0-9]+)[ \t]*/[ \t]*[0-9]+").n | tonumber ]
  | max // 0;

# Any review or comment carries a `Reviewed-Head: <sha>` line equal to the head.
def gh_reviewed_at_head:
  (.headRefOid // "" | ascii_downcase) as $sha
  | $sha != ""
    and any( ((.reviews // [])[], (.comments // [])[]) | .body | _lines[]
             | capture("^Reviewed-Head:[ \t]*(?<sha>[0-9A-Fa-f]+)[ \t]*$").sha
             | ascii_downcase;
             . == $sha);

def gh_pr($graph_backend):
  ([ (.labels // [])[] | .name ]) as $labels
  | { number: .number,
      url: .url,
      state: gh_state,
      head: .headRefName,
      base: .baseRefName,
      head_sha: .headRefOid,
      mergeable: gh_mergeable,
      checks: gh_checks,
      task_id: gh_task_id($graph_backend),
      labels: $labels,
      patch_iteration: gh_patch_iteration,
      reviewed_at_head: gh_reviewed_at_head,
      agent: ($labels | any(.[]; . == agent_label)),
      author: (.author | _login) }
  | validate_pr;

def gh_reviews:
  [ (.reviews // [])[]
    | { author: (.author | _login),
        verdict: ({"APPROVED": "approve", "CHANGES_REQUESTED": "request-changes",
                   "COMMENTED": "comment", "DISMISSED": "dismissed",
                   "PENDING": "pending"}[.state] // (.state | ascii_downcase)),
        body: (.body // ""),
        at: .submittedAt,
        commit: (.commit.oid // null) } ]
  + ([ (.comments // [])[] | {author: (.author | _login), body: (.body // ""), at: .createdAt} ]
     | verdict_comments);

def gh_comments:
  [ (.comments // [])[]
    | { author: (.author | _login), body: (.body // ""), at: .createdAt, url: (.url // null) } ];

# ISO-8601 (§4 profile: optional fraction, Z or ±hh:mm) → epoch seconds.
def iso_epoch:
  capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})([.][0-9]+)?(?<tz>Z|[+-][0-9]{2}:[0-9]{2})$")
  // error("not an ISO-8601 timestamp: \(tojson)")
  | (.dt + "Z" | fromdateiso8601)
    - (if .tz == "Z" then 0
       else (.tz[0:1] | if . == "-" then -1 else 1 end)
            * ((.tz[1:3] | tonumber) * 3600 + (.tz[4:6] | tonumber) * 60) end);

def gh_merged_since($t):
  ($t | iso_epoch) as $cut
  | map(select(.mergedAt != null and (.mergedAt | iso_epoch) >= $cut));
