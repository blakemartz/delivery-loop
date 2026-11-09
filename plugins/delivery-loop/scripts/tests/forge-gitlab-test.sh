#!/usr/bin/env bash
# Tests for forge.sh + backends/forge-gitlab.sh (docs/delivery_graph_spec.md §7,
# §4.2–§4.3): golden cases GC28 (gitlab), GC29, GC30, GC31, GC32, GC67 (gitlab)
# and GC59 (forge.sh part), plus FORGE_DRY_RUN request assertions (§7.2), origin
# derivation, and a smoke test of every other §7.1 op.
#
# Offline: a recording curl shim (fixtures/forge-gitlab/curl-shim.sh) and a no-op
# `sleep` sit first on PATH. The shim answers from fixtures shaped after the
# docs.gitlab.com REST v4 examples (merge request, note, approvals, MR diff,
# job). Runs in a throwaway git repo whose origin is an ssh gitlab remote with a
# subgroup, so the host repo's .claude/delivery.conf never leaks in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
forge="$here/../forge.sh"
fx="$here/fixtures/forge-gitlab"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-forge-gitlab-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" remote add origin git@gitlab.example.com:example/sub/repo.git
mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/curl-shim.sh" > "$tmp/bin/curl"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$SHIM_STATE/log"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/curl" "$tmp/bin/sleep"

TOKEN=s3cr3t-tok
B=https://gitlab.example.com/api/v4
ENC=example%2Fsub%2Frepo
R=$B/projects/$ENC
M=$R/merge_requests
NOTES='notes?sort=asc&order_by=created_at&per_page=100'
sha() { jq -r --arg n "$1" '.[$n].sha' "$fx/mrs.json"; }
OLD=c00dbbc9dadfbe1e232e93a729dd4752fade0abf

# reset: fresh shim state (log, GET counters, behaviour switches).
reset() { rm -rf "$tmp/state"; mkdir -p "$tmp/state"; : > "$tmp/state/log"; : > "$tmp/state/argv"; }

# run [VAR=value …] -- <forge.sh args…>: sets $rc, $out (stdout), $err (stderr).
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  # shellcheck disable=SC2086
  (cd "$tmp" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REVIEW_TOKEN -u GH_REPO -u GH_HOST \
     -u FORGE_URL -u FORGE_REPO -u LIST_LIMIT -u FORGE_DRY_RUN -u SHIM_PAGING \
     -u GITEA_TOKEN -u GITEA_REVIEW_TOKEN -u GITLAB_REVIEW_TOKEN \
     GRAPH_BACKEND=local FORGE=gitlab GITLAB_TOKEN="$TOKEN" \
     PATH="$tmp/bin:$PATH" SHIM_FX="$fx" SHIM_STATE="$tmp/state" $envs \
     bash "$forge" "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
log_has()   { grep -qF -- "$1" "$tmp/state/log"; }
log_line()  { grep -qxF -- "$1" "$tmp/state/log"; }   # an exact whole request
log_count() { grep -cF -- "$1" "$tmp/state/log" || true; }
# expect <name> '<condition>': pass when the shell condition (eval'd) succeeds.
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
jq_true() { [ "$(jq -r "$1" <<<"$out" 2>/dev/null)" = true ]; }
# body_true <METHOD.route> <jq>: the recorded request body satisfies <jq>.
body_true() { [ -f "$tmp/state/$1.json" ] && [ "$(jq -r "$2" "$tmp/state/$1.json")" = true ]; }
gljq() { jq -L "$here/../lib" -L "$here/../backends" "$@"; }

# --- GC28: pr-view normalization ---------------------------------------------
reset
: > "$tmp/gc28.jsonl"
for n in 201 202 203 204 205 206 207 208 209 210 211 212 213 214; do
  run -- pr-view "$n"
  [ "$rc" = 0 ] || fail "GC28 pr-view $n exits 0"
  printf '%s\n' "$out" >> "$tmp/gc28.jsonl"
done
if [ "$(jq -sc . "$tmp/gc28.jsonl")" = "$(jq -c . "$fx/expected-gc28.json")" ]; then
  ok "GC28: pr-view 201..214 equal expected-gc28.json (opened/merged/closed/locked, conflict, every check state, merged-results/train/stale-branch pipelines, reviewed_at_head)"
else
  fail "GC28: normalized PRs differ" "$(diff <(jq -S . "$fx/expected-gc28.json") <(jq -sS . "$tmp/gc28.jsonl") || true)"
fi
if jq -se -L "$here/../lib" 'include "pr"; map(validate_pr) | length == 14' "$tmp/gc28.jsonl" >/dev/null; then
  ok "GC28: every normalized PR passes validate_pr"
else
  fail "GC28: validate_pr rejected adapter output"
fi
expect "GC28: number is the iid, never the global id" \
  '[ "$(jq -sc "map(.number)" "$tmp/gc28.jsonl")" = "[201,202,203,204,205,206,207,208,209,210,211,212,213,214]" ] && [ "$(jq -r ".[\"201\"].id" "$fx/mrs.json")" = 84201 ]'
expect "GC28: reads the single-MR GET by iid on the URL-encoded project path, PRIVATE-TOKEN header" 'log_line "GET $M/201 token=$TOKEN"'
expect "GC28: notes paged ascending (sort=asc, order_by=created_at, per_page=100)" \
  'log_line "GET $M/201/$NOTES&page=1 token=$TOKEN" && log_line "GET $M/201/$NOTES&page=3 token=$TOKEN" && [ "$(log_count "201/$NOTES&page=4")" = 0 ]'
expect "GC28: the token is never on curl's command line" '! grep -qF "$TOKEN" "$tmp/state/argv"'
expect "GC28: an async detailed_merge_status re-polled 3 times with backoff, then unknown (206)" \
  '[ "$(log_count "GET $M/206 ")" = 4 ] && [ "$(jq -s -r ".[5].mergeable" "$tmp/gc28.jsonl")" = unknown ]'
expect "GC28: unchecked then mergeable on the re-poll -> clean (207: two GETs)" \
  '[ "$(log_count "GET $M/207 ")" = 2 ] && [ "$(jq -s -r ".[6].mergeable" "$tmp/gc28.jsonl")" = clean ]'
expect "GC28: no re-poll for a settled MR (201: one GET)" '[ "$(log_count "GET $M/201 ")" = 1 ]'
expect "GC28: re-polls back off (1 + 3 sleeps for 207 and 206)" '[ "$(log_count sleep)" = 4 ]'
expect "GC28: Reviewed-Head equal to head -> true (201); a note on an older head -> false (205)" \
  '[ "$(jq -sc "map(.reviewed_at_head)" "$tmp/gc28.jsonl")" = "[true,false,false,false,false,false,false,false,false,false,false,false,false,false]" ]'
expect "GC28: system notes are not comments (201: patch_iteration 2 from human notes)" '[ "$(jq -s -r ".[0].patch_iteration" "$tmp/gc28.jsonl")" = 2 ]'
expect "§4.3: Closes #N ignored off the github graph; legacy head task/16-… -> \"16\"" \
  '[ "$(jq -s -r ".[1].task_id" "$tmp/gc28.jsonl")" = 16 ]'
expect "§4.3: a description that only mentions #12 -> task_id null (204)" '[ "$(jq -s -r ".[3].task_id" "$tmp/gc28.jsonl")" = null ]'

# GC28: the detailed_merge_status -> mergeable mapping (§7.3) over every value.
for s in mergeable:clean conflict:conflicting need_rebase:conflicting unchecked:unknown checking:unknown \
         preparing:unknown approvals_syncing:unknown ci_still_running:unknown null:unknown \
         ci_must_pass:blocked discussions_not_resolved:blocked draft_status:blocked not_approved:blocked \
         not_open:blocked requested_changes:blocked merge_request_blocked:blocked status_checks_must_pass:blocked \
         jira_association_missing:blocked commits_status:blocked; do
  v="${s%%:*}"; want="${s#*:}"
  [ "$v" = null ] && j='{"detailed_merge_status":null}' || j="{\"detailed_merge_status\":\"$v\"}"
  got=$(gljq -r 'include "forge-gitlab"; gl_mergeable' <<<"$j")
  rc=0; out="$got"; err=""
  expect "GC28: detailed_merge_status $v -> $want" '[ "$got" = "$want" ]'
done
# GC28: the head_pipeline.status -> checks mapping (§7.3) over every status.
for s in success:success failed:failure canceled:failure canceling:failure running:pending pending:pending \
         created:pending waiting_for_resource:pending preparing:pending manual:pending scheduled:pending \
         skipped:pending null:none; do
  v="${s%%:*}"; want="${s#*:}"
  if [ "$v" = null ]; then j='{"sha":"a","head_pipeline":null}'; else j="{\"sha\":\"a\",\"head_pipeline\":{\"sha\":\"a\",\"status\":\"$v\"}}"; fi
  got=$(gljq -r 'include "forge-gitlab"; gl_checks' <<<"$j")
  rc=0; out="$got"; err=""
  expect "GC28: head_pipeline.status $v -> $want" '[ "$got" = "$want" ]'
done
got=$(gljq -r 'include "forge-gitlab"; gl_checks' <<<'{"sha":"a","head_pipeline":{"sha":"b","status":"success"}}')
rc=0; out="$got"; err=""
expect "GC28: a successful pipeline for another commit is pending, never success" '[ "$got" = pending ]'
# GC28: merged-results / merge-train pipelines run on a synthetic merge commit
# (sha != MR head). A merged-results status counts only when the MR head is a
# parent of that commit (GitLab's head_pipeline is not head-checked); a train's
# maps as is (§7.3); the stale-sha guard holds for branch pipelines (source
# branch or refs/merge-requests/<iid>/head).
expect "GC28: merged-results success, head a parent of its commit -> success (211)" '[ "$(jq -s -r ".[10].checks" "$tmp/gc28.jsonl")" = success ]'
expect "GC28: merged-results failed, head a parent of its commit -> failure (212)" '[ "$(jq -s -r ".[11].checks" "$tmp/gc28.jsonl")" = failure ]'
expect "GC28: the merged-results commit is read for its parent_ids (211)" \
  'log_line "GET $R/repository/commits/$(jq -r ".[\"211\"].head_pipeline.sha" "$fx/mrs.json") token=$TOKEN"'
expect "GC28: no commit read for a branch or train pipeline (201, 213, 214)" \
  '[ "$(log_count "repository/commits/")" = 2 ]'
reset
run -- pr-view 215
expect "GC28: a previous head's merged-results success (head not a parent) -> pending (215)" '[ "$rc" = 0 ] && jq_true ".checks == \"pending\"" && log_has "repository/commits/"'
reset
run -- pr-view 216
expect "GC28: merged-results commit unreadable (404) -> pending, not a failure of pr-view (216)" '[ "$rc" = 0 ] && jq_true ".checks == \"pending\""'
for c in '["x","a"]:success' '["x","y"]:pending' 'null:pending' '[]:pending'; do
  pa="${c%%:*}"; want="${c#*:}"
  got=$(gljq -r --argjson pa "$pa" 'include "forge-gitlab"; {iid: 7, sha: "a", head_pipeline: {sha: "m", ref: "refs/merge-requests/7/merge", status: "success"}} | gl_checks($pa)' <<<null)
  rc=0; out="$got"; err=""
  expect "GC28: merged-results success with parent_ids $pa -> $want" '[ "$got" = "$want" ]'
done
expect "GC28: merge-train success (ref …/213/train, sha != head) -> success (213)" '[ "$(jq -s -r ".[12].checks" "$tmp/gc28.jsonl")" = success ]'
expect "GC28: a stale branch pipeline (ref = source branch, sha != head) -> pending (214)" '[ "$(jq -s -r ".[13].checks" "$tmp/gc28.jsonl")" = pending ]'
for c in 'refs/merge-requests/7/merge:running:pending' 'refs/merge-requests/7/train:canceled:failure' \
         'refs/merge-requests/7/head:success:pending' 'feat:failed:pending' 'refs/merge-requests/8/merge:success:pending'; do
  ref="${c%%:*}"; rest="${c#*:}"; st="${rest%%:*}"; want="${rest#*:}"
  got=$(gljq -r --arg r "$ref" --arg s "$st" 'include "forge-gitlab"; {iid: 7, sha: "a", source_branch: "feat", head_pipeline: {sha: "b", ref: $r, status: $s}} | gl_checks' <<<null)
  rc=0; out="$got"; err=""
  expect "GC28: head_pipeline ref $ref, $st, sha != head -> $want" '[ "$got" = "$want" ]'
done

# GC28: notes span pages under every header shape GitLab may send: the full set,
# above 10k (no x-total / x-total-pages / rel=last), Link only, x-total only,
# and none. Each reads every page and no page past the last (none: one empty read).
for mode in gitlab big link total none; do
  { reset; run SHIM_PAGING=$mode -- pr-view 201; }
  if [ "$mode" = none ]; then lastp=4; else lastp=3; fi
  expect "GC28 [$mode]: every note read -> reviewed_at_head true, patch_iteration 2, no page past $lastp" \
    '[ "$rc" = 0 ] && jq_true ".reviewed_at_head == true and .patch_iteration == 2" && log_has "201/$NOTES&page=$lastp " && [ "$(log_count "201/$NOTES&page=$((lastp + 1))")" = 0 ]'
  { reset; run LIST_LIMIT=4 SHIM_PAGING=$mode -- pr-view 201; }
  expect "GC28 [$mode]: a note list reaching LIST_LIMIT exits 3, prints nothing" \
    '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err" && [ -z "$out" ]'
  { reset; run SHIM_PAGING=$mode -- pr-list; }
  expect "GC32 [$mode]: open list read in full over both pages" \
    '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[201,204,205]" ]'
done

# --- GC32: pr-list is fully paginated, never silently truncated ---------------
reset
run -- pr-list
expect "GC32: two-page open list -> every MR from both pages" '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[201,204,205]" ]'
expect "GC32: pages state=opened, stable created_at asc order, per_page=100" \
  'log_line "GET $M?state=opened&order_by=created_at&sort=asc&per_page=100&page=1 token=$TOKEN" && log_line "GET $M?state=opened&order_by=created_at&sort=asc&per_page=100&page=2 token=$TOKEN"'
expect "GC32: follows x-next-page until empty, no page past the last" '[ "$(log_count "sort=asc&per_page=100&page=3")" = 0 ]'
expect "GC32: head_pipeline is hydrated by a single-MR GET per listed MR" \
  'log_line "GET $M/201 token=$TOKEN" && log_line "GET $M/204 token=$TOKEN" && log_line "GET $M/205 token=$TOKEN"'
expect "GC32: checks come from the hydrated head_pipeline (201 success, 204 running -> pending, 205 none)" \
  '[ "$(jq -c "map(.checks)" <<<"$out")" = "[\"success\",\"pending\",\"none\"]" ]'
expect "GC32: every listed PR passes validate_pr" 'jq -e -L "$here/../lib" "include \"pr\"; map(validate_pr) | length == 3" <<<"$out" >/dev/null'
reset
run LIST_LIMIT=3 -- pr-list
expect "GC32: a list reaching LIST_LIMIT exits 3 naming LIST_LIMIT, prints nothing" '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err" && [ -z "$out" ]'
reset
run LIST_LIMIT=2 -- pr-list
expect "GC32: the ceiling is checked before following the next page" '[ "$rc" = 3 ] && [ "$(log_count "page=2")" = 0 ]'
reset
touch "$tmp/state/rate-limit-once"
run -- pr-list
expect "pr-list: a 429 is retried after a backoff" '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[201,204,205]" ] && [ "$(log_count sleep)" = 1 ]'

# --- GC67 (gitlab): merged feed since T ---------------------------------------
reset
T=2026-11-08T10:00:00Z
run -- pr-list --state merged --since "$T"
expect "GC67: only MRs merged at or after T (202, 260); not 262 (updated after T, merged before), 263" \
  '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[202,260]" ] && jq_true "all(.[]; .state == \"merged\")"'
expect "GC67: server-side state=merged&updated_after=T (URL-encoded), paged" \
  'log_line "GET $M?state=merged&updated_after=2026-11-08T10%3A00%3A00Z&order_by=created_at&sort=asc&per_page=100&page=1 token=$TOKEN"'
expect "GC67: MRs outside the window are never hydrated" '[ "$(log_count "$M/262")" = 0 ] && [ "$(log_count "$M/263")" = 0 ]'
reset
run -- pr-list --state merged --since 2026-11-08T11:00:00+01:00
expect "GC67: an offset T compares by instant (+ URL-encoded)" \
  '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[202,260]" ] && log_has "updated_after=2026-11-08T11%3A00%3A00%2B01%3A00&"'
got=$(gljq -c --arg t "$T" 'include "forge-gitlab"; gl_merged_since($t) | map(.iid)' <<<'[
  {"iid":1,"state":"merged","merged_at":"2026-11-08T10:00:00.000Z"},
  {"iid":2,"state":"closed","merged_at":null,"updated_at":"2026-11-08T12:00:00.000Z"},
  {"iid":3,"state":"merged","merged_at":"2026-11-08T09:59:59.999Z"},
  {"iid":4,"state":"merged","merged_at":"2026-11-08T11:00:00+01:00"}]')
rc=0; out="$got"; err=""
expect "GC67: merged exactly at T kept; closed-unmerged and merged before T dropped" '[ "$got" = "[1,4]" ]'
reset
run -- pr-list --state merged
expect "pr-list --state merged (no --since): every merged MR over all pages" '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[262,202,260,263]" ]'
run -- pr-list --since "$T"
expect "pr-list --since without --state merged -> usage exit 2" '[ "$rc" = 2 ]'
run -- pr-list --state merged --since yesterday
expect "pr-list --since with a non-ISO value -> usage exit 2" '[ "$rc" = 2 ]'

# --- GC29: approve rejected / request-changes is always a note ----------------
printf '## Adversarial review — verdict: APPROVE\n\nLooks right.\n' > "$tmp/verdict.md"
reset
touch "$tmp/state/reject-self-approval"
run -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "GC29: approval refused (401) -> note fallback, {posted:true, form:\"comment\"}" \
  '[ "$rc" = 0 ] && jq_true ".posted == true and .form == \"comment\" and .url == \"https://gitlab.example.com/example/sub/repo/-/merge_requests/201#note_9001\""'
expect "GC29: approval attempted first, pinned to the head (sha)" \
  'log_line "POST $M/201/approve token=$TOKEN" && body_true POST.merge_requests_201_approve ". == {sha: \"$(sha 201)\"}"'
expect "GC29: then posted as a note" 'log_line "POST $M/201/notes token=$TOKEN"'
expect "GC29: note body ends with Reviewed-Head: <sha> and keeps the verdict text" \
  'body_true POST.merge_requests_201_notes "(.body | rtrimstr(\"\n\") | split(\"\n\") | last) == \"Reviewed-Head: $(sha 201)\" and (.body | test(\"verdict: APPROVE\"))"'
reset
run -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "pr-review approve: /approve accepted -> form formal, AND the verdict note posted (approve takes no body)" \
  '[ "$rc" = 0 ] && jq_true ".form == \"formal\" and .posted == true" && log_line "POST $M/201/approve token=$TOKEN" && body_true POST.merge_requests_201_notes ".body | endswith(\"Reviewed-Head: $(sha 201)\n\")"'
printf 'One blocker: the test is missing.\n' > "$tmp/rc.md"
reset
run -- pr-review 201 request-changes --sha "$(sha 201)" --body-file "$tmp/rc.md"
expect "GC29: request-changes -> no endpoint called, a note only, form comment" \
  '[ "$rc" = 0 ] && jq_true ".posted == true and .form == \"comment\"" && [ "$(log_count approve)" = 0 ] && [ "$(log_count POST)" = 1 ]'
expect "GC29: the request-changes note opens with the verdict heading and ends with Reviewed-Head" \
  'body_true POST.merge_requests_201_notes "(.body | startswith(\"## Adversarial review — verdict: REQUEST_CHANGES\n\")) and (.body | rtrimstr(\"\n\") | split(\"\n\") | last) == \"Reviewed-Head: $(sha 201)\" and (.body | test(\"the test is missing\"))"'
printf '## Adversarial review — verdict: REQUEST_CHANGES\n\n1. Missing test.\n' > "$tmp/rc2.md"
reset
run -- pr-review 201 request-changes --sha "$(sha 201)" --body-file "$tmp/rc2.md"
expect "pr-review request-changes: a body already headed is not headed twice" \
  '[ "$rc" = 0 ] && body_true POST.merge_requests_201_notes "[.body | split(\"\n\")[] | select(startswith(\"## Adversarial review\"))] | length == 1"'
reset
run -- pr-review 201 request-changes --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "pr-review request-changes with an APPROVE heading -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count POST)" = 0 ]'
reset
run -- pr-review 201 comment --sha "$(sha 201)" --body-file "$tmp/rc.md"
expect "pr-review comment -> a note, no approval, form comment" \
  '[ "$rc" = 0 ] && jq_true ".form == \"comment\"" && [ "$(log_count approve)" = 0 ] && body_true POST.merge_requests_201_notes ".body | endswith(\"Reviewed-Head: $(sha 201)\n\")"'

# A failed note is never reported as posted.
reset
touch "$tmp/state/reject-self-approval" "$tmp/state/fail-note"
run -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "GC29: fallback note fails (403) -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF "nothing posted" <<<"$err"'
reset
touch "$tmp/state/fail-note"
run -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "pr-review: approved but the verdict note fails -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF "verdict note failed" <<<"$err"'
reset
touch "$tmp/state/fail-note"
run -- pr-review 201 request-changes --sha "$(sha 201)" --body-file "$tmp/rc.md"
expect "pr-review request-changes: note fails -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ]'
reset
touch "$tmp/state/approve-conflict"
run -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "pr-review approve: 409 (head moved under the approval) -> exit 1, no note" '[ "$rc" = 1 ] && [ "$(log_count "POST $M/201/notes")" = 0 ]'

# Every verdict note reads as a verdict to pr-reviews, whatever its heading.
for h in '## Adversarial review — verdict: APPROVE' '## Review — verdict: APPROVE' '## review: verdict: approve' 'not a heading' '# Review — verdict: APPROVE' '## Review — verdict: APPROVED'; do
  got=$(gljq -c --arg b "$h" 'include "forge-gitlab"; [{body: "\n\($b)\n\nok\n\nReviewed-Head: abc", system: false, author: {username: "r"}, created_at: "2026-11-08T15:00:00.000Z"}] | gl_reviews({approved_by: []}) | map(.verdict)' <<<null)
  case "$h" in "not a heading"|"# "*|*APPROVED) want='[]' ;; *) want='["approve"]' ;; esac
  rc=0; out="$got"; err=""
  expect "gl_reviews: first line '$h' -> $want" '[ "$got" = "$want" ]'
done
# B2 round trip: /approve refused (401, an author's own MR), the caller's own
# `## Review — verdict: APPROVE` heading kept, and pr-reviews finds that note.
printf '## Review — verdict: APPROVE\n\nok\n' > "$tmp/own.md"
reset
touch "$tmp/state/reject-self-approval"
run -- pr-review 202 approve --sha "$(sha 202)" --body-file "$tmp/own.md"
expect "round trip: approve refused (401) -> form comment, the caller's heading kept, not re-headed" \
  '[ "$rc" = 0 ] && jq_true ".form == \"comment\"" && body_true POST.merge_requests_202_notes "(.body | startswith(\"## Review — verdict: APPROVE\n\")) and ([.body | split(\"\n\")[] | select(startswith(\"## \"))] | length == 1)"'
run -- pr-reviews 202
expect "round trip: pr-reviews returns that note as approve, commit == head" \
  '[ "$rc" = 0 ] && jq_true "[.[] | select(.verdict == \"approve\")] | length == 1 and .[0].commit == \"$(sha 202)\" and .[0].author == \"shim-user\""'
printf 'Looks right, no heading.\n' > "$tmp/bare.md"
for v in approve:APPROVE comment:COMMENT; do
  reset
  touch "$tmp/state/reject-self-approval"
  run -- pr-review 202 "${v%%:*}" --sha "$(sha 202)" --body-file "$tmp/bare.md"
  expect "round trip: a heading-less ${v%%:*} body is headed '## Adversarial review — verdict: ${v#*:}'" \
    '[ "$rc" = 0 ] && body_true POST.merge_requests_202_notes ".body | startswith(\"## Adversarial review — verdict: ${v#*:}\n\n\")"'
  run -- pr-reviews 202
  expect "round trip: pr-reviews returns the heading-less ${v%%:*} as ${v%%:*}, commit == head" \
    '[ "$rc" = 0 ] && jq_true "map(select(.commit == \"$(sha 202)\")) | length == 1 and .[0].verdict == \"${v%%:*}\""'
done
reset
run -- pr-review 202 comment --sha "$(sha 202)" --body-file "$tmp/own.md"
expect "pr-review comment with an APPROVE heading (any form) -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count POST)" = 0 ]'

# The trailer is appended exactly once; another head's trailer is refused.
reset
printf 'verdict: APPROVE\n\nReviewed-Head: %s\n\n' "$(sha 201)" > "$tmp/trailed.md"
run -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/trailed.md"
expect "pr-review: a body already ending in Reviewed-Head: <sha> gets no second one" \
  '[ "$rc" = 0 ] && body_true POST.merge_requests_201_notes "[.body | split(\"\n\")[] | select(startswith(\"Reviewed-Head:\"))] | length == 1"'
reset
printf 'verdict: APPROVE\n\nReviewed-Head: %s\n' "$OLD" > "$tmp/trailed.md"
run -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/trailed.md"
expect "pr-review: a body ending in another head's trailer -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count POST)" = 0 ]'

# GITLAB_REVIEW_TOKEN posts the approval and the note as the reviewer.
reset
touch "$tmp/state/reject-self-approval"
run GITLAB_REVIEW_TOKEN=rev-tok -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "GITLAB_REVIEW_TOKEN -> approval and note under that token, form formal" \
  '[ "$rc" = 0 ] && jq_true ".form == \"formal\"" && log_line "POST $M/201/approve token=rev-tok" && log_line "POST $M/201/notes token=rev-tok"'
expect "GITLAB_REVIEW_TOKEN: neither token is on curl's command line" '! grep -qF rev-tok "$tmp/state/argv" && ! grep -qF "$TOKEN" "$tmp/state/argv"'
reset
run FORGE_DRY_RUN=1 -- pr-review 201 approve --sha "$(sha 201)" --body-file "$tmp/verdict.md"
expect "FORGE_DRY_RUN: pr-review approve prints POST /api/v4/projects/<enc>/merge_requests/201/approve + {sha}, sends nothing" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v4/projects/$ENC/merge_requests/201/approve" ] && [ "$(sed -n 2p <<<"$out" | jq -r .sha)" = "$(sha 201)" ] && [ "$(log_count POST)" = 0 ]'
reset
run FORGE_DRY_RUN=1 -- pr-review 201 request-changes --sha "$(sha 201)" --body-file "$tmp/rc.md"
expect "FORGE_DRY_RUN: pr-review request-changes prints POST …/notes + the headed body" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v4/projects/$ENC/merge_requests/201/notes" ] && sed -n "2,\$p" <<<"$out" | jq -e ".body | startswith(\"## Adversarial review — verdict: REQUEST_CHANGES\")" >/dev/null'

# A verdict against a moved head is refused before anything is posted.
reset
run -- pr-review 201 approve --sha "$OLD" --body-file "$tmp/verdict.md"
expect "pr-review with a stale --sha -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count POST)" = 0 ] && grep -qF refusing <<<"$err"'

# --- GC30: pr-merge with a stale sha ------------------------------------------
reset
run -- pr-merge 241 --method squash --sha "$OLD"
expect "GC30: stale --sha -> exit nonzero, no merge request sent" '[ "$rc" != 0 ] && [ "$(log_count PUT)" = 0 ] && grep -qF refusing <<<"$err"'
reset
run FORGE_DRY_RUN=1 -- pr-merge 241 --method squash --sha "$OLD"
expect "GC30: stale --sha under FORGE_DRY_RUN -> exit nonzero, no merge request in the dry-run log" '[ "$rc" != 0 ] && ! grep -q "^PUT" <<<"$out"'
reset
run FORGE_DRY_RUN=1 -- pr-merge 241 --method squash --sha "$(sha 241)"
expect "FORGE_DRY_RUN: pr-merge prints PUT …/merge_requests/241/merge + {squash, should_remove_source_branch, sha}" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "PUT /api/v4/projects/$ENC/merge_requests/241/merge" ] && [ "$(sed -n 2p <<<"$out" | jq -c .)" = "$(jq -cn --arg s "$(sha 241)" "{squash: true, should_remove_source_branch: true, sha: \$s}")" ] && [ "$(log_count PUT)" = 0 ]'
reset
run FORGE_DRY_RUN=1 -- pr-merge 241 --method merge --sha "$(sha 241)"
expect "FORGE_DRY_RUN: --method merge -> squash false, branch kept" '[ "$rc" = 0 ] && [ "$(sed -n 2p <<<"$out" | jq -r "[.squash, .should_remove_source_branch] | @tsv")" = "$(printf "false\tfalse")" ]'
reset
run -- pr-merge 241 --method squash --sha "$(sha 241)"
expect "pr-merge: re-read merged -> exit 0" '[ "$rc" = 0 ] && jq_true ".number == 241 and .state == \"merged\"" && [ "$(log_count "GET $M/241 ")" = 2 ]'
expect "pr-merge: request pinned with sha" 'body_true PUT.merge_requests_241_merge ".sha == \"$(sha 241)\" and .squash == true"'
reset
run -- pr-merge 240 --method squash --sha "$(sha 240)"
expect "pr-merge: merge accepted but the MR still reads opened after 3 re-polls -> exit 1" \
  '[ "$rc" = 1 ] && grep -qF "not merged" <<<"$err" && [ "$(log_count "GET $M/240 ")" = 5 ] && [ "$(log_count sleep)" = 3 ]'
for c in 405 409 422; do
  reset
  touch "$tmp/state/merge-$c"
  run -- pr-merge 241 --method squash --sha "$(sha 241)"
  expect "pr-merge: HTTP $c -> exit 1 after one attempt" '[ "$rc" = 1 ] && [ "$(log_count "PUT $M/241/merge")" = 1 ] && grep -qF "HTTP $c" <<<"$err"'
done
reset
run -- pr-merge 241 --method rebase --sha "$(sha 241)"
expect "pr-merge --method rebase -> usage exit 2" '[ "$rc" = 2 ]'

# --- GC31: dry-run pr-create --------------------------------------------------
printf 'Implements it.\n\nDelivery-Task: ready-policy\n' > "$tmp/body.md"
reset
run FORGE_DRY_RUN=1 -- pr-create --head task/ready-policy--x --base release/0.2.0 --title "T (ready-policy)" --body-file "$tmp/body.md"
expect "GC31: prints POST /api/v4/projects/<enc>/merge_requests (subgroup path URL-encoded)" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v4/projects/example%2Fsub%2Frepo/merge_requests" ]'
expect "GC31: + body with source/target/title (and description)" \
  '[ "$(sed -n 2p <<<"$out" | jq -c "[.source_branch, .target_branch, .title]")" = "[\"task/ready-policy--x\",\"release/0.2.0\",\"T (ready-policy)\"]" ] && sed -n 2p <<<"$out" | jq -e ".description | test(\"Delivery-Task: ready-policy\")" >/dev/null'
expect "GC31: nothing sent" '[ "$(log_count POST)" = 0 ]'
run FORGE_DRY_RUN=1 -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --draft
expect "pr-create --draft -> Draft: title prefix" '[ "$rc" = 0 ] && [ "$(sed -n 2p <<<"$out" | jq -r .title)" = "Draft: T" ]'
reset
run -- pr-create --head task/ready-policy--x --base release/0.2.0 --title T --body-file "$tmp/body.md"
expect "pr-create -> {number, url} from iid/web_url" '[ "$rc" = 0 ] && jq_true ". == {number: 250, url: \"https://gitlab.example.com/example/sub/repo/-/merge_requests/250\"}"'
run -- pr-create --head h --base b --title T
expect "pr-create without --body-file -> usage exit 2" '[ "$rc" = 2 ]'

# --- every other §7.1 op ------------------------------------------------------
reset
run -- whoami
expect "whoami -> GET /user username" '[ "$rc" = 0 ] && [ "$out" = shim-user ] && log_line "GET $B/user token=$TOKEN"'
run -- pr-find --head task/none--here
expect "pr-find --head with no MR -> empty, exit 0" '[ "$rc" = 0 ] && [ -z "$out" ]'
run -- pr-find --head task/plan-lint--rules
expect "pr-find --head -> that open MR, hydrated" '[ "$rc" = 0 ] && jq_true ".number == 205 and .task_id == \"plan-lint\" and .checks == \"none\""'
expect "pr-find filters source_branch server-side (URL-encoded)" \
  'log_line "GET $M?state=opened&source_branch=task%2Fplan-lint--rules&order_by=created_at&sort=asc&per_page=100&page=1 token=$TOKEN"'
run -- pr-reviews 201
expect "pr-reviews -> the approval, then the verdict notes, with commits from their trailers" \
  '[ "$rc" = 0 ] && jq_true "map(.verdict) == [\"approve\", \"request-changes\", \"approve\"] and .[0].author == \"reviewer\" and .[0].at == \"2026-11-05T09:01:00.000Z\" and .[2].commit == \"$(sha 201)\" and (.[0] | keys) == [\"at\",\"author\",\"body\",\"commit\",\"verdict\"]"'
expect "pr-reviews reads GET …/approvals and every page of notes" 'log_line "GET $M/201/approvals token=$TOKEN" && log_has "201/$NOTES&page=3 "'
run -- pr-comment 201 --body-file "$tmp/body.md"
expect "pr-comment -> posted, url is the note anchor" '[ "$rc" = 0 ] && jq_true ".posted == true and (.url | endswith(\"/-/merge_requests/201#note_9001\"))"'
touch "$tmp/state/fail-note"
run -- pr-comment 201 --body-file "$tmp/body.md"
expect "pr-comment: the forge refuses (403) -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ]'
reset   # drop the note posted above (the shim appends posted notes to the GET)
run -- pr-comments 201
expect "pr-comments -> 4 human notes (system note dropped), note-anchor urls" \
  '[ "$rc" = 0 ] && jq_true "length == 4 and .[0].author == \"astra\" and (.[0].url | endswith(\"#note_3002\")) and (.[0] | keys) == [\"at\",\"author\",\"body\",\"url\"]"'
run -- pr-set-base 201 main
expect "pr-set-base -> PUT /merge_requests/:iid {target_branch}" '[ "$rc" = 0 ] && log_line "PUT $M/201 token=$TOKEN" && body_true PUT.merge_requests_201 ". == {target_branch: \"main\"}"'
run -- pr-files 201
expect "pr-files -> new_path over both pages of …/diffs" '[ "$rc" = 0 ] && [ "$out" = "$(printf "a.sh\nb/c.jq\nd/e.md\nbig.json")" ]'
run -- pr-diff 201
expect "pr-diff -> unified diff with git file headers rebuilt" \
  '[ "$rc" = 0 ] && [ "$(grep -c "^diff --git" <<<"$out")" = 4 ] && grep -qxF -- "--- /dev/null" <<<"$out" && grep -qxF "rename to d/e.md" <<<"$out" && grep -qxF "+new" <<<"$out"'
expect "pr-diff names a file GitLab omitted (too large) on stderr" 'grep -qF "big.json omitted" <<<"$err"'
reset
run -- ci-failures 201
expect "ci-failures -> the trace of every failed job of the head pipeline" \
  '[ "$rc" = 0 ] && grep -qF "=== job 9901 (unit) ===" <<<"$out" && grep -qF "FAIL: case 9902" <<<"$out" && log_line "GET $R/pipelines/5201/jobs?scope%5B%5D=failed&per_page=100&page=1 token=$TOKEN" && log_line "GET $R/jobs/9901/trace token=$TOKEN"'
run -- ci-failures 205
expect "ci-failures with no head pipeline -> nothing, exit 0" '[ "$rc" = 0 ] && [ -z "$out" ]'
run -- pr-view 999
expect "pr-view of a missing MR (404) -> exit 1" '[ "$rc" = 1 ] && grep -qF 404 <<<"$err"'
run -- pr-bogus
expect "unknown op -> usage exit 2" '[ "$rc" = 2 ]'

# --- FORGE_URL / FORGE_REPO defaults (§7.2) -----------------------------------
reset
run FORGE_URL=https://code.example.org/ FORGE_REPO=team/a/b/proj -- pr-set-base 201 main
expect "FORGE_URL/FORGE_REPO override the origin; nested subgroups encoded" 'log_has "PUT https://code.example.org/api/v4/projects/team%2Fa%2Fb%2Fproj/merge_requests/201 "'
run FORGE_URL=https://code.example.org/gitlab FORGE_REPO=team/proj FORGE_DRY_RUN=1 -- pr-set-base 201 main
expect "FORGE_DRY_RUN prints the URL path, relative URL root included" '[ "$(sed -n 1p <<<"$out")" = "PUT /gitlab/api/v4/projects/team%2Fproj/merge_requests/201" ]'
reset
run FORGE_REPO=solo -- pr-view 201
expect "FORGE_REPO without a namespace -> exit 1, no request" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ]'
git -C "$tmp" remote set-url origin https://gitlab.example.com/example/sub/repo.git
reset
run -- pr-set-base 201 main
expect "origin https -> FORGE_URL host, FORGE_REPO the whole path" 'log_has "PUT $M/201 "'
git -C "$tmp" remote set-url origin ssh://git@gitlab.example.com:2222/example/sub/repo.git
run -- pr-set-base 201 main
expect "origin ssh:// with a port -> https://host, ssh port dropped" '[ "$(log_count "PUT $M/201 ")" = 2 ]'
git -C "$tmp" remote set-url origin git@gitlab.example.com:example/sub/repo.git

# --- GC59 (forge.sh part): the config check runs before any I/O ---------------
reset
run GITLAB_TOKEN= -- pr-view 201
expect "GC59: FORGE=gitlab without GITLAB_TOKEN -> exit 1, no request" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ] && grep -qF GITLAB_TOKEN <<<"$err"'
run GITLAB_TOKEN= FORGE_DRY_RUN=1 -- pr-create --head h --base b --title T --body-file "$tmp/body.md"
expect "GC59: … also under FORGE_DRY_RUN (nothing printed)" '[ "$rc" = 1 ] && [ -z "$out" ] && [ ! -s "$tmp/state/log" ]'
run GRAPH_BACKEND=github -- pr-view 201
expect "GC40 via forge.sh: GRAPH_BACKEND=github with FORGE=gitlab -> exit 1, no request" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ]'

if [ "$fails" -ne 0 ]; then
  echo "forge-gitlab tests FAILED" >&2
  exit 1
fi
echo "forge-gitlab tests passed"
