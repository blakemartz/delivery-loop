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
#   verdict_heading            — the canonical heading prefix `pr-review` adds.
#   heading_verdict            — one line → approve|request-changes|comment|null.
#   body_verdict               — a body → the verdict its first non-blank line names, or null.
#   body_reviewed_head         — a body → the sha of its first `Reviewed-Head:` line, or null.
#   verdict_comments           — [{author, body, at}] → [{author, verdict, body, at, commit}],
#                                keeping only the verdict-headed comments.
#   with_verdict_heading($v)   — a body about to be posted as verdict $v → that body,
#                                headed `## Adversarial review — verdict: <V>` when it
#                                has no verdict heading; an error when its heading
#                                names another verdict (gitlab: every verdict is a
#                                note, so a contradicting body is refused up front).
#   ensure_verdict_heading($v) — the same, except a body whose heading names another
#                                verdict is headed too, so its first line names $v
#                                (github, gitea: the formal review takes any body,
#                                and its comment fallback posts that same body).

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

def _headed($verdict): verdict_heading + ($verdict | ascii_upcase | gsub("-"; "_")) + "\n\n" + .;

def with_verdict_heading($verdict):
  . as $b
  | ($b | body_verdict) as $hv
  | if $hv == null then $b | _headed($verdict)
    elif $hv == $verdict then $b
    else error("body opens '\($b | _first_line)', a \($hv) verdict, not \($verdict); refusing") end;

def ensure_verdict_heading($verdict):
  if body_verdict == $verdict then . else _headed($verdict) end;
