# forge-verdict.jq — the forge-neutral comment-form verdict rule
# (docs/delivery_graph_spec.md §7.1 `pr-reviews`, §7.3; design spec §13.2).
#
# Pure: no I/O. Included by every forge adapter's jq (`-L lib -L backends`), so
# github, gitea and gitlab cannot drift on what a verdict comment is.
#
# In single-account mode a forge refuses a formal review of one's own PR, and the
# verdict is posted as a plain comment (a GitLab note) instead. `pr-reviews` must
# still return it. A comment is a verdict when its first non-blank line is a
# markdown h2 naming one: `## <anything> verdict: APPROVE|REQUEST_CHANGES|COMMENT`
# (the verdict word in any case). `verdict` comes from that heading and `commit`
# from the body's `Reviewed-Head:` trailer (null when absent).
#
# It also holds the one rule for which verdict stands at a head (§4.2), applied
# by every adapter to its own `pr-reviews` list.
#
#   verdict_heading            — the canonical heading prefix `pr-review` adds.
#   heading_verdict            — one line → approve|request-changes|comment|null.
#   body_verdict               — a body → the verdict its first non-blank line names, or null.
#   body_reviewed_head         — a body → the sha of its first `Reviewed-Head:` line, or null.
#   verdict_comments           — [{author, body, at}] → [{author, verdict, body, at, commit}],
#                                keeping only the verdict-headed comments.
#   verdict_time               — a timestamp → epoch seconds (fractions kept), or null
#                                when it is not ISO-8601.
#   verdict_at_head($sha)      — a `pr-reviews` list ([{verdict, body, at, …}]) →
#                                approve|request-changes|comment|null: the verdict of
#                                the **latest** entry naming $sha (§4.2
#                                `verdict_at_head`). An entry names $sha when its body
#                                carries a `Reviewed-Head:` line equal to it; only
#                                approve, request-changes and comment entries are
#                                verdicts (the entry's own: a formal review's state, a
#                                comment's heading), so a dismissed, revoked or pending
#                                entry is skipped and the verdict before it stands.
#                                Latest is by `at`. Ties and undated entries resolve
#                                against the approve: at one instant request-changes
#                                outranks comment outranks approve, an undated approve
#                                is the oldest entry and an undated request-changes or
#                                comment the newest.
#   approved_at_head($sha)     — the same list → true when verdict_at_head($sha) is
#                                `approve` (§4.2 `approved_at_head`): a later
#                                request-changes or comment verdict at $sha supersedes
#                                an approve there.
#   approved_head_sha($sha)    — the same list → the head the latest approve verdict
#                                names (its last `Reviewed-Head:` line, lower-cased;
#                                $sha itself when it names $sha), or null when no approve verdict
#                                names a head (§4.2 `approved_head_sha`). Superseded
#                                approves count: this says which head was approved
#                                last, not whether that approval stands.
#   with_verdict_heading($v)   — a body about to be posted as verdict $v → that body,
#                                headed `## Adversarial review — verdict: <V>` when it
#                                has no verdict heading; an error when its heading
#                                names another verdict (gitlab: every verdict is a
#                                note, so a contradicting body is refused up front).
#   ensure_verdict_heading($v) — the same, except a body whose heading names another
#                                verdict is headed too, so its first line names $v
#                                (github, gitea: the formal review takes any body,
#                                and its comment fallback posts that same body).

include "shape";
include "graph";

def verdict_heading: "## Adversarial review — verdict: ";

def verdict_line_re: "^##[ \t].*verdict:[ \t]*(?<v>APPROVE|REQUEST_CHANGES|COMMENT)\\b";

def heading_verdict:
  (capture(verdict_line_re; "i").v // null)
  | if . == null then null
    else {"APPROVE": "approve", "REQUEST_CHANGES": "request-changes", "COMMENT": "comment"}[ascii_upcase] end;

# Lines split on "\n" first: jq's Oniguruma `^`/`$` do not reliably anchor at
# line boundaries.
def _verdict_lines: (. // "") | split("\n") | map(rtrimstr("\r"));

def _first_line: _verdict_lines | map(select(test("\\S"))) | first // "";

def body_verdict: _first_line | heading_verdict;

def body_reviewed_head:
  first(_verdict_lines[] | capture("^Reviewed-Head:[ \t]*(?<sha>[0-9A-Fa-f]+)[ \t]*$").sha) // null;

def verdict_comments:
  [ .[]
    | (.body // "") as $b
    | ($b | body_verdict) as $v
    | select($v != null)
    | { author: .author, verdict: $v, body: $b, at: .at, commit: ($b | body_reviewed_head) } ];

def verdict_time: if is_iso8601 then iso_epoch else null end;

# Input: one `pr-reviews` entry. Every head its body names, lower-cased.
def _reviewed_heads:
  [ .body | _verdict_lines[]
    | capture("^Reviewed-Head:[ \t]*(?<sha>[0-9A-Fa-f]+)[ \t]*$").sha | ascii_downcase ];

# Input: one entry. Null for anything that is not a standing verdict (dismissed,
# pending, …); otherwise its rank among verdicts of one instant.
def _verdict_rank: {"approve": 0, "comment": 1, "request-changes": 2}[.verdict // ""];

# Input: one verdict entry. Its sort key: later sorts higher.
def _verdict_order:
  (.at | verdict_time) as $t
  | [ (if $t != null then 1 elif .verdict == "approve" then 0 else 2 end), ($t // 0), _verdict_rank ];

def verdict_at_head($sha):
  ($sha // "" | ascii_downcase) as $head
  | if $head == "" then null
    else [ .[] | select(_verdict_rank != null and any(_reviewed_heads[]; . == $head)) ]
         | max_by(_verdict_order) | .verdict? end;

def approved_at_head($sha): verdict_at_head($sha) == "approve";

def approved_head_sha($sha):
  ($sha // "" | ascii_downcase) as $head
  | [ .[] | select(.verdict == "approve" and (_reviewed_heads | length) > 0) ]
  | max_by(_verdict_order)
  | if . == null then null
    else _reviewed_heads | if any(.[]; . == $head) then $sha else last end end;

def _headed($verdict): verdict_heading + ($verdict | ascii_upcase | gsub("-"; "_")) + "\n\n" + .;

def with_verdict_heading($verdict):
  . as $b
  | ($b | body_verdict) as $hv
  | if $hv == null then $b | _headed($verdict)
    elif $hv == $verdict then $b
    else error("body opens '\($b | _first_line)', a \($hv) verdict, not \($verdict); refusing") end;

def ensure_verdict_heading($verdict):
  if body_verdict == $verdict then . else _headed($verdict) end;
