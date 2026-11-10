#!/usr/bin/env bash
# Tests for forge.sh + backends/forge-github.sh (docs/delivery_graph_spec.md §7,
# §4.2–§4.3): golden cases GC28 (github), GC29, GC30, GC32, GC33 (`task_id`),
# GC46, GC57, GC58, GC63 and GC67 (github), plus a smoke test of every other
# §7.1 op and forge.sh's start-up config check.
#
# Offline: a recording gh shim (fixtures/forge-github/gh-shim.sh) and a no-op
# `sleep` sit first on PATH, answering from captured-shape JSON fixtures. Runs in
# a throwaway git repo so the host repo's .claude/delivery.conf never leaks in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
forge="$here/../forge.sh"
fx="$here/fixtures/forge-github"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-forge-github-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/gh-shim.sh" > "$tmp/bin/gh"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$SHIM_STATE/log"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"

sha() { jq -r --arg n "$1" '.[$n].headRefOid' "$fx/prs.json"; }
OLD=c00dbbc9dadfbe1e232e93a729dd4752fade0abf

# reset: fresh shim state (log, view counters, behaviour switches).
reset() { rm -rf "$tmp/state"; mkdir -p "$tmp/state"; : > "$tmp/state/log"; }

# run [VAR=value …] -- <forge.sh args…>: sets $rc, $out (stdout), $err (stderr).
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  # shellcheck disable=SC2086
  (cd "$tmp" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REVIEW_TOKEN -u GH_REPO -u GH_HOST \
     -u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u LIST_LIMIT \
     -u GITLAB_TOKEN -u GITEA_TOKEN \
     PATH="$tmp/bin:$PATH" SHIM_FX="$fx" SHIM_STATE="$tmp/state" $envs \
     bash "$forge" "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
log_has()   { grep -qF -- "$1" "$tmp/state/log"; }
log_line()  { grep -qxF -- "$1" "$tmp/state/log"; }   # an exact whole call
log_count() { grep -cF -- "$1" "$tmp/state/log" || true; }
# expect <name> '<condition>': pass when the shell condition (eval'd) succeeds.
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
jq_true() { [ "$(jq -r "$1" <<<"$out" 2>/dev/null)" = true ]; }

# --- GC28: pr-view normalization ---------------------------------------------
reset
: > "$tmp/gc28.jsonl"
for n in 101 102 103 104 105 106; do
  run -- pr-view "$n"
  [ "$rc" = 0 ] || fail "GC28 pr-view $n exits 0"
  printf '%s\n' "$out" >> "$tmp/gc28.jsonl"
done
if [ "$(jq -sc . "$tmp/gc28.jsonl")" = "$(jq -c . "$fx/expected-gc28.json")" ]; then
  ok "GC28: pr-view 101..106 equal expected-gc28.json (states, mergeable, checks, reviewed_at_head)"
else
  fail "GC28: normalized PRs differ" "$(diff <(jq -S . "$fx/expected-gc28.json") <(jq -sS . "$tmp/gc28.jsonl") || true)"
fi
expect "GC28: requests the §7.2 field set" 'log_has "gh pr view 101 --json number,url,state,headRefName,baseRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup,body,labels,comments,reviews,author,closingIssuesReferences"'
expect "GC28: no re-poll for settled or closed PRs" '[ "$(log_count '\''sleep'\'')" = 0 ]'

# Every output passes the merged validate_pr (also enforced inside the adapter).
if jq -se -L "$here/../lib" 'include "pr"; map(validate_pr) | length == 6' "$tmp/gc28.jsonl" >/dev/null; then
  ok "GC28: every normalized PR passes validate_pr"
else
  fail "GC28: validate_pr rejected adapter output"
fi

# GC28: the statusCheckRollup -> checks mapping (§7.3) over every conclusion
# the PR fixtures do not reach (fixtures/forge-github/rollups.json).
while IFS= read -r c; do
  name=$(jq -r .case <<<"$c"); want=$(jq -r .want <<<"$c")
  got=$(jq -r -L "$here/../lib" -L "$here/../backends" 'include "forge-github"; .rollup | {statusCheckRollup: .} | gh_checks' <<<"$c")
  rc=0; out="$got"; err=""
  expect "GC28: checks for $name -> $want" '[ "$got" = "$want" ]'
done < <(jq -c '.[]' "$fx/rollups.json")

# --- GC33 / GC46: task_id linkage precedence (§4.3) ---------------------------
reset
check_task() { # <pr> <expected task_id json> <label> [GRAPH_BACKEND]
  run ${4:+GRAPH_BACKEND=$4} -- pr-view "$1"
  if [ "$rc" = 0 ] && [ "$(jq -c .task_id <<<"$out")" = "$2" ]; then ok "$3"
  else fail "$3" "want task_id $2, got $(jq -c .task_id <<<"$out" 2>/dev/null)"; fi
}
check_task 110 null       'GC33: body that only mentions #12 -> task_id null'
check_task 111 '"12"'     'GC33: Delivery-Task: 12 -> task_id "12"'
check_task 120 '"auth-3"' 'GC46: Delivery-Task trailer -> its id'
check_task 121 '"7"'      'GC46: Closes #7 (github graph) -> "7"'
check_task 121 null       'GC46: Closes #7 is ignored when GRAPH_BACKEND=local' local
check_task 122 '"x"'      'GC46: head task/x--s -> "x"'
check_task 123 '"7"'      'GC46: legacy head task/7-s -> "7"'
check_task 124 null       'GC46: no linkage form -> null'
check_task 125 '"auth-9"' 'GC46: trailer wins over Closes #7 and the head branch'

# --- GC57: mergeability still computing --------------------------------------
reset
run -- pr-view 130
expect "GC57: computing on every poll -> mergeable unknown" '[ "$rc" = 0 ] && [ "$(jq -r .mergeable <<<"$out")" = unknown ]'
expect "GC57: re-polled 3 times with backoff (4 views, 3 sleeps)" '[ "$(log_count '\''gh pr view 130'\'')" = 4 ] && [ "$(log_count '\''sleep'\'')" = 3 ]'
reset
run -- pr-view 131
expect "GC57: computing then CLEAN on re-poll -> clean" '[ "$rc" = 0 ] && [ "$(jq -r .mergeable <<<"$out")" = clean ]'

# --- GC32: pr-list is fully paginated, never silently truncated ---------------
reset
run -- pr-list
expect "GC32: two-page open list -> every PR from both pages" '[ "$rc" = 0 ] && [ "$(jq -c '\''map(.number)'\'' <<<"$out")" = "[101,104,105]" ]'
expect "GC32: list call carries an explicit --limit \$LIST_LIMIT" 'log_has "gh pr list --state open --limit 5000"'
expect "GC32: each listed PR hydrated (comments/reviews) via pr view" '[ "$(log_count '\''gh pr view 10'\'')" = 3 ]'
reset
run LIST_LIMIT=3 -- pr-list
expect "GC32: a list reaching LIST_LIMIT exits 3 naming LIST_LIMIT" '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err"'

# --- GC67 (github): merged feed since T ---------------------------------------
reset
T=2026-11-08T10:00:00Z
run -- pr-list --state merged --since "$T"
expect "GC67: only PRs merged at or after T (102, 151; not 150, 152)" '[ "$rc" = 0 ] && [ "$(jq -c '\''map(.number)'\'' <<<"$out")" = "[102,151]" ]'
expect "GC67: gh called with --search \"merged:>=T\"" 'log_has "gh pr list --state merged --search merged:>=$T --limit 5000"'
expect "GC67: PRs outside the window are never hydrated" '[ "$(log_count '\''gh pr view 150'\'')" = 0 ] && [ "$(log_count '\''gh pr view 152'\'')" = 0 ]'
reset
run -- pr-list --state merged --since 2026-11-08T11:00:00+01:00
expect "GC67: an offset T compares by instant" '[ "$rc" = 0 ] && [ "$(jq -c '\''map(.number)'\'' <<<"$out")" = "[102,151]" ]'
run -- pr-list --since "$T"
expect "pr-list --since without --state merged -> usage exit 2" '[ "$rc" = 2 ]'

# GitHub search caps at 1000 results: on the --since path that is the ceiling
# even when LIST_LIMIT is higher, so a capped window exits 3 (§11, §7.1).
reset
touch "$tmp/state/many-merged"
run -- pr-list --state merged --since "$T"
expect "GC67: search capped at 1000 (< LIST_LIMIT 5000) -> exit 3, no silent truncation" '[ "$rc" = 3 ] && grep -qF 1000 <<<"$err" && [ -z "$out" ]'
expect "GC67: a capped search hydrates nothing" '[ "$(log_count '\''gh pr view'\'')" = 0 ]'
reset
touch "$tmp/state/many-merged"
run LIST_LIMIT=500 -- pr-list --state merged --since "$T"
expect "GC67: LIST_LIMIT below the search cap is the ceiling -> exit 3 naming LIST_LIMIT" '[ "$rc" = 3 ] && grep -qF "LIST_LIMIT (500)" <<<"$err"'

# --- GC29: self-review rejected -> comment-form fallback ----------------------
reset
touch "$tmp/state/reject-self-review"
printf '## Review — verdict: APPROVE\n\nLooks right.\n' > "$tmp/verdict.md"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "GC29: fallback -> {posted:true, form:\"comment\"}" '[ "$rc" = 0 ] && jq_true '\''.posted == true and .form == "comment" and (.url | test("issuecomment"))'\'''
expect "GC29: formal review was attempted first" 'log_has "gh pr review 101 --approve"'
expect "GC29: comment body ends with Reviewed-Head: <sha>" '[ "$(tail -n 1 "$tmp/state/comment-body")" = "Reviewed-Head: $(sha 101)" ]'
expect "GC29: comment body keeps the verdict text" 'grep -qF '\''verdict: APPROVE'\'' "$tmp/state/comment-body"'

# D4 round trip: the comment-form verdict comes back from pr-reviews, with
# `verdict` from its heading and `commit` from its Reviewed-Head: trailer.
run -- pr-reviews 101
expect "round trip: pr-reviews returns the comment-form approve, commit == head" \
  '[ "$rc" = 0 ] && jq_true "map(select(.commit == \"$(sha 101)\" and .author == \"shim-user\")) | length == 1 and .[0].verdict == \"approve\" and (.[0].body | startswith(\"## Review — verdict: APPROVE\n\"))"'
expect "round trip: the formal reviews are still returned first" \
  '[ "$rc" = 0 ] && jq_true "length == 3 and (.[0:2] | map(.verdict)) == [\"request-changes\", \"approve\"] and .[0].author == \"reviewer\""'
expect "round trip: pr-reviews reads reviews and comments" 'log_has "gh pr view 101 --json reviews,comments"'
expect "round trip: the caller's own heading is kept, not re-headed" \
  '[ "$(head -n 1 "$tmp/state/comment-body")" = "## Review — verdict: APPROVE" ] && [ "$(grep -c "^## " "$tmp/state/comment-body")" = 1 ]'
# A plain comment and an h1 verdict-looking comment are not verdicts.
printf 'Thanks, will look.\n\nReviewed-Head: %s\n' "$(sha 101)" > "$tmp/plain.md"
printf '# Review — verdict: APPROVE\n\nReviewed-Head: %s\n' "$(sha 101)" > "$tmp/h1.md"
run -- pr-comment 101 --body-file "$tmp/plain.md"
run -- pr-comment 101 --body-file "$tmp/h1.md"
run -- pr-reviews 101
expect "pr-reviews: a plain comment and a '# …' heading are NOT returned" \
  '[ "$rc" = 0 ] && jq_true "length == 3 and ([.[] | select(.body | startswith(\"Thanks\") or startswith(\"# \"))] | length == 0)"'
# A heading-less body, and one whose heading names another verdict, get the
# canonical heading on the comment fallback; pr-reviews reads that verdict.
printf 'Looks right, no heading.\n' > "$tmp/bare.md"
for c in "approve:$tmp/bare.md:APPROVE" "request-changes:$tmp/verdict.md:REQUEST_CHANGES"; do
  v="${c%%:*}"; rest="${c#*:}"; f="${rest%:*}"; V="${rest##*:}"
  reset
  touch "$tmp/state/reject-self-review"
  run -- pr-review 101 "$v" --sha "$(sha 101)" --body-file "$f"
  expect "fallback $v ($(basename "$f")): comment headed '## Adversarial review — verdict: $V'" \
    '[ "$rc" = 0 ] && jq_true ".form == \"comment\"" && [ "$(head -n 1 "$tmp/state/comment-body")" = "## Adversarial review — verdict: $V" ]'
  run -- pr-reviews 101
  expect "fallback $v: pr-reviews returns it as $v, commit == head" \
    '[ "$rc" = 0 ] && jq_true "map(select(.author == \"shim-user\")) | length == 1 and .[0].verdict == \"$v\" and .[0].commit == \"$(sha 101)\""'
done
reset
touch "$tmp/state/reject-self-review"
run GH_REVIEW_TOKEN=rev-tok -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/bare.md"
expect "formal review body is sent as given (no heading added)" \
  '[ "$rc" = 0 ] && jq_true ".form == \"formal\"" && [ "$(head -n 1 "$tmp/state/review-body")" = "Looks right, no heading." ]'

# A failed fallback comment is never reported as posted.
reset
touch "$tmp/state/reject-self-review" "$tmp/state/fail-comment"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "GC29: fallback comment fails -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF "nothing posted" <<<"$err"'

# The trailer is appended exactly once.
reset
touch "$tmp/state/reject-self-review"
printf 'verdict: APPROVE\n\nReviewed-Head: %s\n\n' "$(sha 101)" > "$tmp/trailed.md"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/trailed.md"
expect "pr-review: a body already ending in Reviewed-Head: <sha> gets no second one" '[ "$rc" = 0 ] && [ "$(grep -c "^Reviewed-Head:" "$tmp/state/comment-body")" = 1 ]'
reset
printf 'verdict: APPROVE\n\nReviewed-Head: %s\n' "$OLD" > "$tmp/trailed.md"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/trailed.md"
expect "pr-review: a body ending in another head's trailer -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count '\''pr review'\'')" = 0 ] && [ "$(log_count '\''pr comment'\'')" = 0 ]'

# --- GC58: GH_REVIEW_TOKEN -> formal review under that identity ---------------
reset
touch "$tmp/state/reject-self-review"
run GH_REVIEW_TOKEN=rev-tok -- pr-review 101 request-changes --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "GC58: form formal" '[ "$rc" = 0 ] && jq_true '\''.posted == true and .form == "formal"'\'''
expect "GC58: the review request carries the review token" 'log_has "gh[GH_TOKEN=rev-tok] pr review 101 --request-changes"'
expect "GC58: formal body ends with Reviewed-Head: <sha>" '[ "$(tail -n 1 "$tmp/state/review-body")" = "Reviewed-Head: $(sha 101)" ]'
expect "GC58: no comment fallback" '[ "$(log_count '\''pr comment'\'')" = 0 ]'

# A verdict against a moved head is refused before anything is posted.
reset
run -- pr-review 101 approve --sha "$OLD" --body-file "$tmp/verdict.md"
expect "pr-review with a stale --sha -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count '\''pr review'\'')" = 0 ] && [ "$(log_count '\''pr comment'\'')" = 0 ]'

# --- GC30: pr-merge with a stale sha ------------------------------------------
reset
run -- pr-merge 101 --method squash --sha "$OLD"
expect "GC30: stale --sha -> exit nonzero, no merge request sent" '[ "$rc" != 0 ] && [ "$(log_count '\''pr merge'\'')" = 0 ]'

# --- GC63: post-merge re-read shows auto-merge enabled ------------------------
reset
run -- pr-merge 140 --method squash --sha "$(sha 140)"
expect "GC63: merge pinned with --match-head-commit" 'log_has "gh pr merge 140 --squash --match-head-commit $(sha 140)"'
expect "GC63: re-read open + autoMergeRequest -> gh pr merge --disable-auto" 'log_line "gh pr merge 140 --disable-auto"'
expect "GC63: exit 1" '[ "$rc" = 1 ]'
expect "GC63: no branch deletion for an unmerged PR" '[ "$(log_count '\''api -X DELETE'\'')" = 0 ]'

# The happy path: re-read MERGED -> exit 0; squash deletes the source branch.
reset
run -- pr-merge 141 --method squash --sha "$(sha 141)"
expect "pr-merge: re-read MERGED -> exit 0" '[ "$rc" = 0 ] && jq_true '\''.number == 141 and .state == "merged"'\'''
expect "pr-merge: squash deletes the source branch" 'log_has "gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/task/141-merges"'
expect "pr-merge: never --disable-auto on success" '[ "$(log_count '\''disable-auto'\'')" = 0 ]'
reset
run -- pr-merge 141 --method rebase --sha "$(sha 141)"
expect "pr-merge --method rebase -> usage exit 2" '[ "$rc" = 2 ]'

# --- every other §7.1 op ------------------------------------------------------
reset
run -- whoami
expect "whoami -> login" '[ "$rc" = 0 ] && [ "$out" = shim-user ]'
printf 'Closes #20\n\nDelivery-Task: 20\n' > "$tmp/body.md"
run -- pr-create --head task/20-x --base release/0.2.0 --title "T (#20)" --body-file "$tmp/body.md"
expect "pr-create -> {number, url}" '[ "$rc" = 0 ] && jq_true '\''. == {number: 150, url: "https://github.com/example/repo/pull/150"}'\'''
expect "pr-create passes head/base/title/body-file" 'log_has "gh pr create --head task/20-x --base release/0.2.0 --title T (#20) --body-file $tmp/body.md"'
expect "pr-create without --label passes no --label" '[ "$(log_count "--label")" = 0 ]'
reset
run -- pr-create --head task/20-x --base release/0.2.0 --title "T (#20)" --body-file "$tmp/body.md" --label agent-authored --label task --draft
expect "pr-create --label x2 -> gh pr create --label agent-authored --label task, one call" \
  '[ "$rc" = 0 ] && jq_true ".number == 150" && log_line "gh pr create --head task/20-x --base release/0.2.0 --title T (#20) --body-file $tmp/body.md --draft --label agent-authored --label task" && [ "$(log_count "pr create")" = 1 ]'
reset
touch "$tmp/state/unknown-label"
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label no-such-label
expect "pr-create --label unknown (gh resolves before creating) -> exit 1, no PR, no JSON" \
  '[ "$rc" = 1 ] && grep -qF "no PR created" <<<"$err" && grep -qF "no-such-label" <<<"$err" && [ -z "$out" ]'
reset
touch "$tmp/state/fail-label-update"
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label agent-authored
expect "pr-create: gh created the PR but its label step failed -> exit 1 naming the PR URL" \
  '[ "$rc" = 1 ] && grep -qF "opened https://github.com/example/repo/pull/150 but failed to apply its labels" <<<"$err" && [ -z "$out" ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label
expect "pr-create --label without a name -> usage exit 2" '[ "$rc" = 2 ]'
# Each --label value is exactly one label: gh CSV-splits it, so refuse first.
reset
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label agent-authored --label "a,b"
expect "pr-create --label a,b -> exit 1 before gh runs (gh would apply a and b)" \
  '[ "$rc" = 1 ] && grep -qF "cannot contain" <<<"$err" && grep -qF "a,b" <<<"$err" && [ "$(log_count gh)" = 0 ] && [ -z "$out" ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label 'q"x'
expect "pr-create --label with a '\"' -> exit 1 before gh runs (gh's CSV split)" \
  '[ "$rc" = 1 ] && grep -qF "cannot contain" <<<"$err" && [ "$(log_count gh)" = 0 ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label $'a\nb'
expect "pr-create --label \$'a\\nb' -> exit 1 before gh runs" \
  '[ "$rc" = 1 ] && grep -qF "newline or CR" <<<"$err" && [ "$(log_count gh)" = 0 ] && [ -z "$out" ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label $'a\rb'
expect "pr-create --label \$'a\\rb' -> exit 1 before gh runs" \
  '[ "$rc" = 1 ] && grep -qF "newline or CR" <<<"$err" && [ "$(log_count gh)" = 0 ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label task --label agent-authored --label task
expect "pr-create --label task x2 -> passed once, first-seen order kept" \
  '[ "$rc" = 0 ] && log_line "gh pr create --head h --base b --title T --body-file $tmp/body.md --label task --label agent-authored"'
reset
run -- pr-find --head task/104-conflict
expect "pr-find --head -> that open PR" '[ "$rc" = 0 ] && jq_true '\''.number == 104'\'''
run -- pr-find --head no-such-branch
expect "pr-find --head with no PR -> empty, exit 0" '[ "$rc" = 0 ] && [ -z "$out" ]'
run -- pr-reviews 101
expect "pr-reviews -> [{author, verdict, body, at, commit}]" '[ "$rc" = 0 ] && jq_true "map(.verdict) == [\"request-changes\", \"approve\"] and .[1].commit == \"$(sha 101)\" and (.[0] | keys) == [\"at\",\"author\",\"body\",\"commit\",\"verdict\"]"'
run -- pr-comment 101 --body-file "$tmp/body.md"
expect "pr-comment -> posted" '[ "$rc" = 0 ] && jq_true '\''.posted == true and (.url | test("issuecomment"))'\'''
touch "$tmp/state/fail-comment"
run -- pr-comment 101 --body-file "$tmp/body.md"
expect "pr-comment: gh pr comment fails -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ]'
rm -f "$tmp/state/fail-comment"
reset
run -- pr-comments 101
expect "pr-comments -> 3 comments" '[ "$rc" = 0 ] && jq_true '\''length == 3 and .[0].author == "astra"'\'''
run -- pr-set-base 101 main
expect "pr-set-base -> gh pr edit --base" '[ "$rc" = 0 ] && log_has "gh pr edit 101 --base main"'
run -- pr-files 101
expect "pr-files -> changed paths" '[ "$rc" = 0 ] && [ "$out" = "$(printf '\''a.sh\nb/c.jq'\'')" ]'
run -- pr-diff 101
expect "pr-diff -> unified diff" '[ "$rc" = 0 ] && grep -q '\''^diff --git'\'' <<<"$out"'
run -- ci-failures 101
expect "ci-failures -> gh run view --log-failed for the head's failed runs" '[ "$rc" = 0 ] && log_has "gh run list --commit $(sha 101) --status failure" && log_has "gh run view 77 --log-failed"'
run -- pr-bogus
expect "unknown op -> usage exit 2" '[ "$rc" = 2 ]'
run FORGE_REPO=example/other -- pr-view 101
expect "FORGE_REPO overrides the repo gh resolves (GH_REPO)" '[ "$rc" = 0 ] && log_has "gh[GH_REPO=example/other] pr view 101"'

# --- forge.sh runs the config check before any I/O ----------------------------
reset
run FORGE=gitlab -- pr-view 101
expect "invalid config (FORGE=gitlab, no token) -> exit 1, no forge call" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ] && grep -qF GITLAB_TOKEN <<<"$err"'
run GRAPH_BACKEND=github FORGE=gitea GITEA_TOKEN=x -- whoami
expect "GRAPH_BACKEND=github with FORGE=gitea -> exit 1, no forge call" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ]'

if [ "$fails" -ne 0 ]; then
  echo "forge-github tests FAILED" >&2
  exit 1
fi
echo "forge-github tests passed"
