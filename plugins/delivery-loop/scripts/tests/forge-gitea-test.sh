#!/usr/bin/env bash
# Tests for forge.sh + backends/forge-gitea.sh (docs/delivery_graph_spec.md §7,
# §4.2–§4.3): golden cases GC28 (gitea), GC29, GC30, GC32, GC67 (gitea) and GC76, plus
# FORGE_DRY_RUN request assertions (§7.2), origin derivation, and a smoke test of
# every other §7.1 op.
#
# Offline: a recording curl shim (fixtures/forge-gitea/curl-shim.sh) and a no-op
# `sleep` sit first on PATH. The shim answers from fixtures shaped after the
# Gitea/Forgejo REST v1 swagger (PullRequest, CombinedStatus, PullReview,
# Comment, ChangedFile; repo objects trimmed). Runs in a throwaway git repo whose
# origin is an ssh gitea remote, so the host repo's .claude/delivery.conf never
# leaks in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
forge="$here/../forge.sh"
fx="$here/fixtures/forge-gitea"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-forge-gitea-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" remote add origin git@gitea.example.com:example/repo.git
mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/curl-shim.sh" > "$tmp/bin/curl"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$SHIM_STATE/log"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/curl" "$tmp/bin/sleep"

TOKEN=s3cr3t-tok
B=https://gitea.example.com/api/v1
R=$B/repos/example/repo
sha() { jq -r --arg n "$1" '.[$n].head.sha' "$fx/prs.json"; }
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
     -u FORGE_URL -u FORGE_REPO -u LIST_LIMIT -u FORGE_DRY_RUN \
     -u GITLAB_TOKEN -u GITEA_REVIEW_TOKEN -u GITLAB_REVIEW_TOKEN \
     GRAPH_BACKEND=local FORGE=gitea GITEA_TOKEN="$TOKEN" \
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

# --- GC28: pr-view normalization ---------------------------------------------
reset
: > "$tmp/gc28.jsonl"
for n in 101 102 103 104 105 106; do
  run -- pr-view "$n"
  [ "$rc" = 0 ] || fail "GC28 pr-view $n exits 0"
  printf '%s\n' "$out" >> "$tmp/gc28.jsonl"
done
if [ "$(jq -sc . "$tmp/gc28.jsonl")" = "$(jq -c . "$fx/expected-gc28.json")" ]; then
  ok "GC28: pr-view 101..106 equal expected-gc28.json (open/merged/closed, conflict, checks, reviewed_at_head)"
else
  fail "GC28: normalized PRs differ" "$(diff <(jq -S . "$fx/expected-gc28.json") <(jq -sS . "$tmp/gc28.jsonl") || true)"
fi
if jq -se -L "$here/../lib" 'include "pr"; map(validate_pr) | length == 6' "$tmp/gc28.jsonl" >/dev/null; then
  ok "GC28: every normalized PR passes validate_pr"
else
  fail "GC28: validate_pr rejected adapter output"
fi
expect "GC28: reads GET /pulls/{n} with the token header" 'log_line "GET $R/pulls/101 token=$TOKEN"'
expect "GC28: checks from the head commit's status list, paged with limit/page" 'log_line "GET $R/commits/$(sha 101)/status?limit=2&page=1 token=$TOKEN"'
expect "GC28: hydrates issue comments and paged reviews" 'log_line "GET $R/issues/101/comments token=$TOKEN" && log_line "GET $R/pulls/101/reviews?limit=2&page=1 token=$TOKEN"'
expect "GC28: reviews page 2 followed via X-Total-Count (the route sends no Link)" 'log_line "GET $R/pulls/101/reviews?limit=2&page=2 token=$TOKEN"'
expect "GC28: the token is never on curl's command line" '! grep -qF "$TOKEN" "$tmp/state/argv"'
expect "GC28: mergeable null re-polled 3 times, then unknown (106)" '[ "$(log_count "GET $R/pulls/106 ")" = 4 ]'
expect "GC28: only the unsettled open PRs (104 false, 106 null) are re-polled" '[ "$(log_count sleep)" = 6 ]'
expect "GC28: a closed or merged PR is never re-polled (102, 103: one GET)" '[ "$(log_count "GET $R/pulls/102 ")" = 1 ] && [ "$(log_count "GET $R/pulls/103 ")" = 1 ]'
expect "GC28: no re-poll for a settled PR (101: one GET)" '[ "$(log_count "GET $R/pulls/101 ")" = 1 ]'
reset
run -- pr-view 107
expect "GC28: null then true on the re-poll -> clean" '[ "$rc" = 0 ] && jq_true ".mergeable == \"clean\"" && [ "$(log_count sleep)" = 1 ]'

# --- GC76: a gitea `mergeable: false` is confirmed before it is a conflict ----
# Gitea reads false while its conflict check re-runs (§7.3), so the adapter
# re-reads: bounded to 3 re-reads with backoff 2 s, 4 s, 6 s (12 s per call).
reset
run -- pr-view 109
expect "GC76: false then true on the re-poll -> clean, after one re-read" \
  '[ "$rc" = 0 ] && jq_true ".mergeable == \"clean\"" && [ "$(log_count "GET $R/pulls/109 ")" = 2 ] && [ "$(log_count sleep)" = 1 ]'
reset
run -- pr-view 104
expect "GC76: false on every read -> conflicting" '[ "$rc" = 0 ] && jq_true ".mergeable == \"conflicting\""'
expect "GC76: the wait is bounded: 4 GETs, backoff 2 s, 4 s, 6 s, no more" \
  '[ "$(log_count "GET $R/pulls/104 ")" = 4 ] && [ "$(grep -F sleep "$tmp/state/log" | tr "\n" ",")" = "sleep 2,sleep 4,sleep 6," ]'
reset
run -- pr-view 110
expect "GC76: null then false (false not seen on every read) -> unknown, never clean" \
  '[ "$rc" = 0 ] && jq_true ".mergeable == \"unknown\"" && [ "$(log_count "GET $R/pulls/110 ")" = 4 ]'
reset
run -- pr-view 111
expect "GC76: false on 3 reads, true on the last -> clean (a slow check is still not a conflict)" \
  '[ "$rc" = 0 ] && jq_true ".mergeable == \"clean\"" && [ "$(log_count "GET $R/pulls/111 ")" = 4 ]'

# GC28: the status list spans pages and the failing job is on page 2. Page 1's
# own state is "success", so only a roll-up over every page reads it right.
reset
run -- pr-view 108
expect "GC28: a failing status on page 2 -> checks failure" '[ "$rc" = 0 ] && jq_true ".checks == \"failure\""'
expect "GC28: status pages 1 and 2 both read (Forgejo: X-Total-Count, no Link)" \
  'log_line "GET $R/commits/$(sha 108)/status?limit=2&page=1 token=$TOKEN" && log_line "GET $R/commits/$(sha 108)/status?limit=2&page=2 token=$TOKEN" && [ "$(log_count "$(sha 108)/status?limit=2&page=3")" = 0 ]'
expect "GC28: the shim's page 1 alone would roll up to success (the case is real)" \
  '[ "$(jq -c --arg s "$(sha 108)" ".[\$s].statuses[0:2] | map(.status)" "$fx/statuses.json")" = "[\"success\",\"success\"]" ]'
reset
run LIST_LIMIT=3 -- pr-view 108
expect "GC28: a status list reaching LIST_LIMIT exits 3, prints nothing" '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err" && [ -z "$out" ]'

# GC28 under every header shape a paginated route can send (src): Link and
# X-Total-Count (Gitea's status route, /pulls, /files), X-Total-Count only
# (/reviews on both forges, Forgejo's status route), and neither. PR 108's
# failing status is on page 2; PR 101's head-matching APPROVED review is its
# 3rd (page 2). Each must be read in full, with no page past the last.
for mode in "SHIM_FORGE=gitea" "SHIM_LINK=all" "SHIM_LINK=none" "SHIM_LINK=none SHIM_NO_TOTAL=1" "SHIM_FORGE=forgejo"; do
  # shellcheck disable=SC2086
  { reset; run $mode -- pr-view 108; }
  expect "GC28 [$mode]: page-2 failure -> checks failure, pages 1-2 read, no page 3" \
    '[ "$rc" = 0 ] && jq_true ".checks == \"failure\"" && log_has "$(sha 108)/status?limit=2&page=2 " && [ "$(log_count "$(sha 108)/status?limit=2&page=3")" = 0 ]'
  # shellcheck disable=SC2086
  { reset; run $mode -- pr-view 101; }
  expect "GC28 [$mode]: every review read -> reviewed_at_head true (101)" \
    '[ "$rc" = 0 ] && jq_true ".reviewed_at_head == true" && log_has "pulls/101/reviews?limit=2&page=2 " && [ "$(log_count "pulls/101/reviews?limit=2&page=3")" = 0 ]'
  # shellcheck disable=SC2086
  { reset; run $mode -- pr-reviews 101; }
  expect "GC28 [$mode]: pr-reviews 101 -> all 3 reviews, newest verdict last" \
    '[ "$rc" = 0 ] && jq_true "length == 3 and .[2].verdict == \"approve\""'
  # shellcheck disable=SC2086
  { reset; run LIST_LIMIT=3 $mode -- pr-view 108; }
  expect "GC28 [$mode]: status list reaching LIST_LIMIT -> exit 3, prints nothing" \
    '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err" && [ -z "$out" ]'
  # shellcheck disable=SC2086
  { reset; run LIST_LIMIT=3 $mode -- pr-reviews 101; }
  expect "GC28 [$mode]: review list reaching LIST_LIMIT -> exit 3, prints nothing" \
    '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err" && [ -z "$out" ]'
  # shellcheck disable=SC2086
  { reset; run $mode -- pr-list; }
  expect "GC32 [$mode]: open list read in full over both pages" \
    '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[101,104,105]" ] && [ "$(log_count "sort=oldest&limit=2&page=3")" = 0 ]'
done
reset
run SHIM_LINK=none SHIM_NO_TOTAL=1 -- pr-view 104
expect "GC28 [no headers]: a full last page costs one empty read, then stops" \
  '[ "$rc" = 0 ] && log_has "$(sha 104)/status?limit=2&page=2 " && [ "$(log_count "$(sha 104)/status?limit=2&page=3")" = 0 ]'

# GC28: the combined status -> checks mapping (§7.3) over every state.
while IFS= read -r c; do
  name=$(jq -r .case <<<"$c"); want=$(jq -r .want <<<"$c")
  got=$(jq -r -L "$here/../lib" -L "$here/../backends" 'include "forge-gitea"; .statuses | gt_checks' <<<"$c")
  rc=0; out="$got"; err=""
  expect "GC28: checks for $name -> $want" '[ "$got" = "$want" ]'
done < <(jq -c '.[]' "$fx/status-cases.json")

# GC28: the `Reviewed-Head:` verdict ties to the head (101 true via its APPROVED
# review; 105 false: its only review carries an older head).
expect "GC28: Reviewed-Head trailer equal to head -> reviewed_at_head true; older head -> false" \
  '[ "$(jq -sc "map(.reviewed_at_head)" "$tmp/gc28.jsonl")" = "[true,false,false,false,false,false]" ]'
expect "GC28: an APPROVED review at the head -> approved_at_head true (101); no approve at the head -> false" \
  '[ "$(jq -sc "map(.approved_at_head)" "$tmp/gc28.jsonl")" = "[true,false,false,false,false,false]" ]'
# approved_at_head (§4.2) over gitea's review states and its comment fallback:
# only an approve verdict at the head counts. H is the head.
H=aaaaaaa000000000000000000000000000000000
gt_at_head() { # <name> <reviews json> <comments json> <want "reviewed approved">
  got=$(jq -r -L "$here/../lib" -L "$here/../backends" --arg h "$H" --argjson r "$2" --argjson c "$3" \
    'include "forge-gitea";
     {pr: {number: 1, html_url: "u", state: "open", merged: false, mergeable: true, body: "",
           head: {ref: "h", sha: $h}, base: {ref: "main"}, labels: [], user: {login: "a"}},
      statuses: [], comments: $c, reviews: $r}
     | gt_pr("local") | "\(.reviewed_at_head) \(.approved_at_head)"' <<<null)
  rc=0; out="$got"; err=""; want="$4"
  expect "GC28: $1 -> reviewed/approved at head: $want" '[ "$got" = "$want" ]'
}
# gt_rv <state> <body> [dismissed] / gt_cm <body>: `\n` in <body> is a newline.
gt_rv() { jq -cn --arg s "$1" --arg b "$(printf '%b' "$2")" --argjson d "${3:-false}" '[{state: $s, dismissed: $d, body: $b, user: {login: "r"}, submitted_at: "2026-11-08T15:00:00Z", commit_id: "x"}]'; }
gt_cm() { jq -cn --arg b "$(printf '%b' "$1")" '[{body: $b, user: {login: "r"}, created_at: "2026-11-08T15:00:00Z"}]'; }
gt_at_head "an APPROVED review at the head" "$(gt_rv APPROVED "ok\n\nReviewed-Head: $H")" '[]' "true true"
gt_at_head "a REQUEST_CHANGES review at the head" "$(gt_rv REQUEST_CHANGES "no\n\nReviewed-Head: $H")" '[]' "true false"
gt_at_head "a dismissed APPROVED review at the head" "$(gt_rv APPROVED "ok\n\nReviewed-Head: $H" true)" '[]' "true false"
gt_at_head "an APPROVE-headed comment at the head" '[]' "$(gt_cm "## Adversarial review — verdict: APPROVE\n\nReviewed-Head: $H")" "true true"
gt_at_head "a REQUEST_CHANGES-headed comment at the head" '[]' "$(gt_cm "## Adversarial review — verdict: REQUEST_CHANGES\n\nReviewed-Head: $H")" "true false"

# §4.3 on gitea: GRAPH_BACKEND is local, so `Closes #16` (102) is not linkage;
# the legacy head branch is.
expect "§4.3: Closes #N ignored off the github graph; legacy head task/16-… -> \"16\"" \
  '[ "$(jq -s -r ".[1].task_id" "$tmp/gc28.jsonl")" = 16 ]'

# --- GC32: pr-list is fully paginated, never silently truncated ---------------
reset
run -- pr-list
expect "GC32: two-page open list -> every PR from both pages" '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[101,104,105]" ]'
expect "GC76: pr-list confirms a listed false too (104: re-read 3 times, conflicting)" \
  '[ "$(log_count "GET $R/pulls/104 ")" = 3 ] && jq_true "map(select(.number == 104))[0].mergeable == \"conflicting\""'
expect "GC32: page size from GET /settings/api (max_response_items)" 'log_line "GET $B/settings/api token=$TOKEN"'
expect "GC32: page 1 and page 2 requested with limit=max_response_items, stable sort=oldest" 'log_line "GET $R/pulls?state=open&sort=oldest&limit=2&page=1 token=$TOKEN" && log_line "GET $R/pulls?state=open&sort=oldest&limit=2&page=2 token=$TOKEN"'
expect "GC32: no page past the last Link rel=next" '[ "$(log_count "pulls?state=open&sort=oldest&limit=2&page=3")" = 0 ]'
expect "GC32: listed PRs hydrated without re-reading settled ones" '[ "$(log_count "GET $R/pulls/101 ")" = 0 ] && [ "$(log_count "GET $R/pulls/105 ")" = 0 ] && log_has "GET $R/commits/$(sha 105)/status"'
expect "GC32: every listed PR passes validate_pr" 'jq -e -L "$here/../lib" "include \"pr\"; map(validate_pr) | length == 3" <<<"$out" >/dev/null'
# §7.3: the confirmation wait is capped per call, not per PR. Listed: 104, 112
# and 113 read false on every read, 114 false then true, 110 false then null
# then false, 101 true. One backoff (2 s, 4 s, 6 s = 12 s) covers them all; a
# wait per PR would have slept 3 times for each of the four that stay unsettled.
reset
run SHIM_OPEN_LIST=open-unsettled -- pr-list
expect "§7.3 cap: a list with several persistently-false PRs waits one backoff in total (2 s, 4 s, 6 s)" \
  '[ "$rc" = 0 ] && [ "$(grep -F sleep "$tmp/state/log" | tr "\n" ",")" = "sleep 2,sleep 4,sleep 6," ]'
expect "§7.3 cap: each persistently-false PR is still re-read 3 times and confirmed conflicting (104, 112, 113)" \
  '[ "$(log_count "GET $R/pulls/104 ")" = 3 ] && [ "$(log_count "GET $R/pulls/112 ")" = 3 ] && [ "$(log_count "GET $R/pulls/113 ")" = 3 ] && [ "$(jq -c "map(select(.number == 104 or .number == 112 or .number == 113) | .mergeable)" <<<"$out")" = "[\"conflicting\",\"conflicting\",\"conflicting\"]" ]'
expect "§7.3 cap: a false not confirmed within the wait reads unknown, never clean or conflicting (110)" \
  '[ "$(log_count "GET $R/pulls/110 ")" = 3 ] && jq_true "map(select(.number == 110))[0].mergeable == \"unknown\""'
expect "§7.3 cap: a PR that settles leaves the wait (114: one re-read, clean); a settled one never joins it (101)" \
  '[ "$(log_count "GET $R/pulls/114 ")" = 1 ] && jq_true "map(select(.number == 114))[0].mergeable == \"clean\"" && [ "$(log_count "GET $R/pulls/101 ")" = 0 ]'
expect "§7.3 cap: 13 re-reads in all (3+3+3+1+3), every listed PR returned in list order" \
  '[ "$(grep -cE "^GET $R/pulls/[0-9]+ " "$tmp/state/log")" = 13 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[104,112,113,114,110,101]" ]'
expect "§7.3 cap: every re-read of a round follows that round's sleep (rounds are shared, not per PR)" \
  '[ "$(grep -E "^sleep|^GET $R/pulls/[0-9]+ " "$tmp/state/log" | sed -E "s/^GET .*\/pulls\/([0-9]+) .*/\1/" | tr "\n" " ")" = "sleep 2 104 112 113 114 110 sleep 4 104 112 113 110 sleep 6 104 112 113 110 " ]'
reset
run SHIM_OPEN_LIST=open-unsettled -- pr-find --head task/113-wip
expect "§7.3 cap: pr-find waits for the one PR it returns, never for the list it searched (113: 3 re-reads, conflicting)" \
  '[ "$rc" = 0 ] && jq_true ".number == 113 and .mergeable == \"conflicting\"" && [ "$(grep -cE "^GET $R/pulls/[0-9]+ " "$tmp/state/log")" = 3 ] && [ "$(grep -F sleep "$tmp/state/log" | tr "\n" ",")" = "sleep 2,sleep 4,sleep 6," ]'
# §7.3: a re-read that fails is a failed call naming the PR, never a null read
# (which would end as a silent `unknown`). PR 104 reads false on every good
# read; its 2nd GET (the first re-read) fails in each way a read can.
for how in transport http garbage; do
  reset
  echo "$how" > "$tmp/state/view-104.2.fail"
  run -- pr-view 104
  expect "§7.3 re-read failure [$how]: pr-view exits 1 naming pull #104, prints no PR" \
    '[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF "pull #104" <<<"$err"'
  expect "§7.3 re-read failure [$how]: the call stops at the failed read (2 GETs, one sleep)" \
    '[ "$(log_count "GET $R/pulls/104 ")" = 2 ] && [ "$(log_count sleep)" = 1 ]'
  # In a list the listing is read 1, so the first re-read is the 1st GET of the pull.
  reset
  echo "$how" > "$tmp/state/view-104.1.fail"
  run -- pr-list
  expect "§7.3 re-read failure [$how]: pr-list exits 1 naming pull #104, prints no list" \
    '[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF "pull #104" <<<"$err"'
done
expect "§7.3 re-read failure: a transport error is reported as one, with the PR" \
  '{ reset; echo transport > "$tmp/state/view-104.3.fail"; run -- pr-view 104; [ "$rc" = 1 ] && grep -qF "network/TLS error" <<<"$err" && grep -qF "pull #104: the re-read confirming its mergeability failed" <<<"$err"; }'
expect "§7.3 re-read failure: an HTTP error keeps its status code" \
  '{ reset; echo http > "$tmp/state/view-104.3.fail"; run -- pr-view 104; [ "$rc" = 1 ] && grep -qF "GET pull #104 -> HTTP 500" <<<"$err"; }'
reset
echo garbage > "$tmp/state/view-104.1.fail"
run -- pr-view 104
expect "§7.3: a first read that is not a PullRequest object fails too, without re-reading" \
  '[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF "pull #104" <<<"$err" && [ "$(log_count "GET $R/pulls/104 ")" = 1 ] && [ "$(log_count sleep)" = 0 ]'
reset
run LIST_LIMIT=3 -- pr-list
expect "GC32: a list reaching LIST_LIMIT exits 3 naming LIST_LIMIT, prints nothing" '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err" && [ -z "$out" ]'
reset
run LIST_LIMIT=2 -- pr-list
expect "GC32: the ceiling is checked before following the next page" '[ "$rc" = 3 ] && [ "$(log_count "page=2")" = 0 ]'
reset
run LIST_LIMIT=5 -- pr-list --state merged --since 2026-11-08T10:00:00Z
expect "GC32: the --since early stop still applies LIST_LIMIT (6 read >= 5 -> exit 3)" '[ "$rc" = 3 ] && grep -qF LIST_LIMIT <<<"$err" && [ -z "$out" ]'
reset
touch "$tmp/state/rate-limit-once"
run -- pr-list
expect "pr-list: a 429 is retried after a backoff" '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[101,104,105]" ] && [ "$(log_count "sleep 2")" = 2 ]'

# --- GC67 (gitea): merged feed since T ----------------------------------------
reset
T=2026-11-08T10:00:00Z
run -- pr-list --state merged --since "$T"
expect "GC67: only PRs merged at or after T (160, 102); not 161 (closed unmerged), 162/163 (merged before T)" \
  '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[160,102]" ] && jq_true "all(.[]; .state == \"merged\")"'
expect "GC67: pages state=closed sorted by recentupdate" 'log_line "GET $R/pulls?state=closed&sort=recentupdate&limit=2&page=1 token=$TOKEN"'
expect "GC67: stops paging once a page holds updated_at < T (page 3), never page 4" \
  'log_has "sort=recentupdate&limit=2&page=3" && [ "$(log_count "sort=recentupdate&limit=2&page=4")" = 0 ]'
expect "GC67: PRs outside the window are never hydrated" \
  '[ "$(log_count "issues/161/")" = 0 ] && [ "$(log_count "issues/162/")" = 0 ] && [ "$(log_count "issues/163/")" = 0 ]'
reset
run -- pr-list --state merged --since 2026-11-08T11:00:00+01:00
expect "GC67: an offset T compares by instant" '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[160,102]" ]'
reset
run -- pr-list --state merged
expect "pr-list --state merged (no --since): every merged PR over all pages" '[ "$rc" = 0 ] && [ "$(jq -c "map(.number)" <<<"$out")" = "[160,102,162,163,164,165]" ]'
run -- pr-list --since "$T"
expect "pr-list --since without --state merged -> usage exit 2" '[ "$rc" = 2 ]'
run -- pr-list --state merged --since yesterday
expect "pr-list --since with a non-ISO value -> usage exit 2" '[ "$rc" = 2 ]'

# --- GC29: self-review rejected -> comment-form fallback ----------------------
reset
touch "$tmp/state/reject-self-review"
printf '## Review — verdict: APPROVE\n\nLooks right.\n' > "$tmp/verdict.md"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "GC29: fallback -> {posted:true, form:\"comment\"}" '[ "$rc" = 0 ] && jq_true ".posted == true and .form == \"comment\" and (.url | test(\"issuecomment-9001\"))"'
expect "GC29: formal review attempted first, pinned to the head (event, commit_id)" \
  'log_line "POST $R/pulls/101/reviews token=$TOKEN" && body_true POST.pulls_101_reviews ".event == \"APPROVED\" and .commit_id == \"$(sha 101)\""'
expect "GC29: then posted as an issue comment" 'log_line "POST $R/issues/101/comments token=$TOKEN"'
expect "GC29: comment body ends with Reviewed-Head: <sha>" \
  'body_true POST.issues_101_comments "(.body | rtrimstr(\"\n\") | split(\"\n\") | last) == \"Reviewed-Head: $(sha 101)\""'
expect "GC29: comment body keeps the verdict text" 'body_true POST.issues_101_comments ".body | test(\"verdict: APPROVE\")"'
# D4 round trip: the comment-form verdict comes back from pr-reviews, with
# `verdict` from its heading and `commit` from its Reviewed-Head: trailer.
run -- pr-reviews 101
expect "round trip: pr-reviews returns the comment-form approve (422 fallback), commit == head" \
  '[ "$rc" = 0 ] && jq_true "map(select(.author == \"shim-user\")) | length == 1 and .[0].verdict == \"approve\" and .[0].commit == \"$(sha 101)\" and (.[0].body | startswith(\"## Review — verdict: APPROVE\n\"))"'
expect "round trip: the formal reviews are still returned first" \
  '[ "$rc" = 0 ] && jq_true "length == 4 and (.[0:3] | map(.verdict)) == [\"request-changes\", \"dismissed\", \"approve\"]"'
expect "round trip: pr-reviews reads the issue comments" 'log_line "GET $R/issues/101/comments token=$TOKEN"'
expect "round trip: the caller's own heading is kept, not re-headed" \
  'body_true POST.issues_101_comments "[.body | split(\"\n\")[] | select(startswith(\"## \"))] | length == 1"'
# A plain comment and an h1 verdict-looking comment are not verdicts.
printf 'Thanks, will look.\n\nReviewed-Head: %s\n' "$(sha 101)" > "$tmp/plain.md"
printf '# Review — verdict: APPROVE\n\nReviewed-Head: %s\n' "$(sha 101)" > "$tmp/h1.md"
run -- pr-comment 101 --body-file "$tmp/plain.md"
run -- pr-comment 101 --body-file "$tmp/h1.md"
run -- pr-reviews 101
expect "pr-reviews: a plain comment and a '# …' heading are NOT returned" \
  '[ "$rc" = 0 ] && jq_true "length == 4 and ([.[] | select(.body | startswith(\"Thanks\") or startswith(\"# \"))] | length == 0)"'
# A heading-less body, and one whose heading names another verdict, get the
# canonical heading on the comment fallback; pr-reviews reads that verdict.
printf 'Looks right, no heading.\n' > "$tmp/bare.md"
for c in "approve:$tmp/bare.md:APPROVE" "request-changes:$tmp/verdict.md:REQUEST_CHANGES"; do
  v="${c%%:*}"; rest="${c#*:}"; f="${rest%:*}"; V="${rest##*:}"
  reset
  touch "$tmp/state/reject-self-review"
  run -- pr-review 101 "$v" --sha "$(sha 101)" --body-file "$f"
  expect "fallback $v ($(basename "$f")): comment headed '## Adversarial review — verdict: $V'" \
    '[ "$rc" = 0 ] && jq_true ".form == \"comment\"" && body_true POST.issues_101_comments ".body | startswith(\"## Adversarial review — verdict: $V\n\n\")"'
  run -- pr-reviews 101
  expect "fallback $v: pr-reviews returns it as $v, commit == head" \
    '[ "$rc" = 0 ] && jq_true "map(select(.author == \"shim-user\")) | length == 1 and .[0].verdict == \"$v\" and .[0].commit == \"$(sha 101)\""'
done
reset
run GITEA_REVIEW_TOKEN=rev-tok -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/bare.md"
expect "formal review body is sent as given (no heading added)" \
  '[ "$rc" = 0 ] && jq_true ".form == \"formal\"" && body_true POST.pulls_101_reviews ".body | startswith(\"Looks right, no heading.\")"'
reset
touch "$tmp/state/reject-self-review"
run -- pr-review 101 request-changes --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "GC29: request-changes (422 reject your own pull) -> comment fallback" '[ "$rc" = 0 ] && jq_true ".form == \"comment\"" && body_true POST.pulls_101_reviews ".event == \"REQUEST_CHANGES\""'

# A failed fallback comment is never reported as posted.
reset
touch "$tmp/state/reject-self-review" "$tmp/state/fail-comment"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "GC29: fallback comment fails (403) -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF "nothing posted" <<<"$err"'

# The trailer is appended exactly once; another head's trailer is refused.
reset
printf 'verdict: APPROVE\n\nReviewed-Head: %s\n\n' "$(sha 101)" > "$tmp/trailed.md"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/trailed.md"
expect "pr-review: a body already ending in Reviewed-Head: <sha> gets no second one" \
  '[ "$rc" = 0 ] && body_true POST.pulls_101_reviews "[.body | split(\"\n\")[] | select(startswith(\"Reviewed-Head:\"))] | length == 1"'
reset
printf 'verdict: APPROVE\n\nReviewed-Head: %s\n' "$OLD" > "$tmp/trailed.md"
run -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/trailed.md"
expect "pr-review: a body ending in another head's trailer -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count POST)" = 0 ]'

# A formal success: COMMENT is allowed on one's own PR; GITEA_REVIEW_TOKEN posts as the reviewer.
reset
touch "$tmp/state/reject-self-review"
run -- pr-review 101 comment --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "pr-review comment -> formal COMMENT review, no fallback" '[ "$rc" = 0 ] && jq_true ".posted == true and .form == \"formal\"" && [ "$(log_count "issues/101/comments")" = 0 ]'
reset
touch "$tmp/state/reject-self-review"
run GITEA_REVIEW_TOKEN=rev-tok -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "GITEA_REVIEW_TOKEN -> review posted under that token, form formal" \
  '[ "$rc" = 0 ] && jq_true ".form == \"formal\"" && log_line "POST $R/pulls/101/reviews token=rev-tok" && [ "$(log_count "issues/101/comments")" = 0 ]'
reset
run FORGE_DRY_RUN=1 -- pr-review 101 approve --sha "$(sha 101)" --body-file "$tmp/verdict.md"
expect "FORGE_DRY_RUN: pr-review prints POST /api/v1/repos/…/pulls/101/reviews + pinned body, sends nothing" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v1/repos/example/repo/pulls/101/reviews" ] && [ "$(sed -n 2p <<<"$out" | jq -r ".event + \" \" + .commit_id")" = "APPROVED $(sha 101)" ] && [ "$(log_count POST)" = 0 ]'

# A verdict against a moved head is refused before anything is posted.
reset
run -- pr-review 101 approve --sha "$OLD" --body-file "$tmp/verdict.md"
expect "pr-review with a stale --sha -> exit 1, nothing posted" '[ "$rc" = 1 ] && [ "$(log_count POST)" = 0 ]'

# --- GC30: pr-merge with a stale sha ------------------------------------------
reset
run -- pr-merge 141 --method squash --sha "$OLD"
expect "GC30: stale --sha -> exit nonzero, no merge request sent" '[ "$rc" != 0 ] && [ "$(log_count POST)" = 0 ] && grep -qF refusing <<<"$err"'
reset
run FORGE_DRY_RUN=1 -- pr-merge 141 --method squash --sha "$OLD"
expect "GC30: stale --sha under FORGE_DRY_RUN -> exit nonzero, no merge request in the dry-run log" '[ "$rc" != 0 ] && ! grep -q "^POST" <<<"$out"'

# The pinned merge request, as FORGE_DRY_RUN prints it.
reset
run FORGE_DRY_RUN=1 -- pr-merge 141 --method squash --sha "$(sha 141)"
# Build the expected body outside expect's eval: bash 3.2 brace-expands a jq
# object constructor nested as "$(jq "{a, b}")" inside eval'd text.
want=$(jq -cn --arg s "$(sha 141)" '{Do: "squash", delete_branch_after_merge: true, head_commit_id: $s}')
expect "FORGE_DRY_RUN: pr-merge prints POST …/pulls/141/merge + {Do, delete_branch_after_merge, head_commit_id}" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v1/repos/example/repo/pulls/141/merge" ] && [ "$(sed -n 2p <<<"$out" | jq -c .)" = "$want" ] && [ "$(log_count POST)" = 0 ]'
reset
run FORGE_DRY_RUN=1 -- pr-merge 141 --method merge --sha "$(sha 141)"
expect "FORGE_DRY_RUN: --method merge -> Do merge, branch kept" '[ "$rc" = 0 ] && [ "$(sed -n 2p <<<"$out" | jq -r "[.Do, .delete_branch_after_merge] | @tsv")" = "$(printf "merge\tfalse")" ]'

# The happy path: the re-read shows merged -> exit 0.
reset
run -- pr-merge 141 --method squash --sha "$(sha 141)"
expect "pr-merge: re-read merged -> exit 0" '[ "$rc" = 0 ] && jq_true ".number == 141 and .state == \"merged\"" && [ "$(log_count "GET $R/pulls/141 ")" = 2 ]'
expect "pr-merge: request pinned with head_commit_id" 'body_true POST.pulls_141_merge ".head_commit_id == \"$(sha 141)\" and .Do == \"squash\""'
reset
run -- pr-merge 140 --method squash --sha "$(sha 140)"
expect "pr-merge: merge accepted but re-read not merged -> exit 1" '[ "$rc" = 1 ] && grep -qF "not merged" <<<"$err"'
reset
touch "$tmp/state/merge-conflict"
run -- pr-merge 141 --method squash --sha "$(sha 141)"
expect "pr-merge: 409 (head out of date) -> exit 1, one attempt" '[ "$rc" = 1 ] && [ "$(log_count "POST $R/pulls/141/merge")" = 1 ] && grep -qF 409 <<<"$err"'
reset
touch "$tmp/state/merge-later"
run -- pr-merge 141 --method squash --sha "$(sha 141)"
expect "pr-merge: 405 try again later -> re-polled 3 times with backoff, then exit 1" \
  '[ "$rc" = 1 ] && [ "$(log_count "POST $R/pulls/141/merge")" = 4 ] && [ "$(log_count sleep)" = 3 ]'
reset
run -- pr-merge 141 --method rebase --sha "$(sha 141)"
expect "pr-merge --method rebase -> usage exit 2" '[ "$rc" = 2 ]'

# --- every other §7.1 op ------------------------------------------------------
reset
run -- whoami
expect "whoami -> GET /user login" '[ "$rc" = 0 ] && [ "$out" = shim-user ] && log_line "GET $B/user token=$TOKEN"'
printf 'Closes #20\n\nDelivery-Task: 20\n' > "$tmp/body.md"
run -- pr-create --head task/20-x --base release/0.2.0 --title "T (#20)" --body-file "$tmp/body.md"
expect "pr-create -> {number, url} from number/html_url" '[ "$rc" = 0 ] && jq_true ". == {number: 150, url: \"https://gitea.example.com/example/repo/pulls/150\"}"'
expect "pr-create sends head/base/title/body" 'body_true POST.pulls "[.head, .base, .title] == [\"task/20-x\", \"release/0.2.0\", \"T (#20)\"] and (.body | test(\"Delivery-Task: 20\"))"'
run FORGE_DRY_RUN=1 -- pr-create --head task/20-x --base release/0.2.0 --title "T (#20)" --body-file "$tmp/body.md" --draft
expect "FORGE_DRY_RUN: pr-create prints POST …/pulls + body; --draft -> WIP: title" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v1/repos/example/repo/pulls" ] && [ "$(sed -n 2p <<<"$out" | jq -r .title)" = "WIP: T (#20)" ]'
expect "FORGE_DRY_RUN: pr-create without --label sends no labels field" '[ "$(sed -n 2p <<<"$out" | jq -c "has(\"labels\")")" = false ]'

# --- pr-create --label: names -> ids in the create POST, never created --------
reset
run FORGE_DRY_RUN=1 -- pr-create --head task/20-x --base release/0.2.0 --title "T (#20)" --body-file "$tmp/body.md" --label agent-authored --label task
expect "FORGE_DRY_RUN: pr-create --label x2 -> POST …/pulls with labels [12,13] (repo label ids)" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v1/repos/example/repo/pulls" ] && [ "$(sed -n 2p <<<"$out" | jq -c .labels)" = "[12,13]" ]'
expect "pr-create --label: names resolved over the paged repo label list" \
  'log_line "GET $R/labels?limit=2&page=1 token=$TOKEN" && log_line "GET $R/labels?limit=2&page=2 token=$TOKEN"'
expect "pr-create --label: no org lookup when the repo has every name; nothing sent" \
  '[ "$(log_count "/orgs/")" = 0 ] && [ "$(log_count POST)" = 0 ]'
reset
run FORGE_DRY_RUN=1 -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label promote --label agent-authored
expect "pr-create --label: an org label resolves via GET /orgs/{owner}/labels; a repo label wins a name clash" \
  '[ "$rc" = 0 ] && [ "$(sed -n 2p <<<"$out" | jq -c .labels)" = "[12,91]" ] && log_line "GET $B/orgs/example/labels?limit=2&page=1 token=$TOKEN"'
reset
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label agent-authored --label no-such-label
expect "pr-create --label unknown -> exit 1 naming it, before the PR is created" \
  '[ "$rc" = 1 ] && grep -qF "unknown label(s) on example/repo: no-such-label" <<<"$err" && [ "$(log_count POST)" = 0 ] && [ -z "$out" ]'
reset
run FORGE_URL=https://gitea.example.com FORGE_REPO=someone/repo -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label nope
expect "pr-create --label: a user owner (org labels 404) -> unknown label exit 1, nothing sent" \
  'log_has "GET $B/orgs/someone/labels?" && [ "$rc" = 1 ] && grep -qF "unknown label(s) on someone/repo: nope" <<<"$err" && [ "$(log_count POST)" = 0 ]'
reset
run -- pr-create --head task/20-x --base release/0.2.0 --title "T (#20)" --body-file "$tmp/body.md" --label agent-authored
expect "pr-create --label agent-authored -> one create POST carrying labels [12]" \
  '[ "$rc" = 0 ] && jq_true ".number == 150" && body_true POST.pulls ".labels == [12]" && [ "$(log_count POST)" = 1 ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label
expect "pr-create --label without a name -> usage exit 2" '[ "$rc" = 2 ]'
# Each --label value is exactly one label.
reset
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label agent-authored --label $'agent-authored\ntask'
expect "pr-create --label \$'a\\nb' -> exit 1, nothing read or sent (was split into two labels)" \
  '[ "$rc" = 1 ] && grep -qF "newline or CR" <<<"$err" && [ ! -s "$tmp/state/log" ] && [ -z "$out" ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label $'task\r'
expect "pr-create --label with a CR -> exit 1, nothing read or sent" \
  '[ "$rc" = 1 ] && grep -qF "newline or CR" <<<"$err" && [ ! -s "$tmp/state/log" ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label "agent-authored,task"
expect "pr-create --label a,b -> one name, not split (unknown here), nothing sent" \
  '[ "$rc" = 1 ] && grep -qF "unknown label(s) on example/repo: agent-authored,task;" <<<"$err" && [ "$(log_count POST)" = 0 ]'
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label -x
expect "pr-create --label -x -> one name kept exactly (unknown), nothing sent" \
  '[ "$rc" = 1 ] && grep -qF "unknown label(s) on example/repo: -x;" <<<"$err" && [ "$(log_count POST)" = 0 ]'
reset
run FORGE_DRY_RUN=1 -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label task --label agent-authored --label task
expect "pr-create --label task x2 -> sent once (labels [12,13])" \
  '[ "$rc" = 0 ] && [ "$(sed -n 2p <<<"$out" | jq -c .labels)" = "[12,13]" ]'
reset
run -- pr-find --head task/105-none
expect "pr-find --head with no PR -> empty, exit 0" '[ "$rc" = 0 ] && [ -z "$out" ]'
run -- pr-find --head task/plan-lint--rules
expect "pr-find --head -> that open PR (found on page 2)" '[ "$rc" = 0 ] && jq_true ".number == 105 and .task_id == \"plan-lint\""'
expect "pr-find pages the open list with a stable sort=oldest" 'log_line "GET $R/pulls?state=open&sort=oldest&limit=2&page=2 token=$TOKEN"'
run -- pr-reviews 101
expect "pr-reviews -> [{author, verdict, body, at, commit}] across pages" \
  '[ "$rc" = 0 ] && jq_true "map(.verdict) == [\"request-changes\", \"dismissed\", \"approve\"] and .[2].commit == \"$(sha 101)\" and (.[0] | keys) == [\"at\",\"author\",\"body\",\"commit\",\"verdict\"]"'
run -- pr-comment 101 --body-file "$tmp/body.md"
expect "pr-comment -> posted" '[ "$rc" = 0 ] && jq_true ".posted == true and (.url | test(\"issuecomment\"))"'
touch "$tmp/state/fail-comment"
run -- pr-comment 101 --body-file "$tmp/body.md"
expect "pr-comment: the forge refuses (403) -> exit 1, no posted JSON" '[ "$rc" = 1 ] && [ -z "$out" ]'
rm -f "$tmp/state/fail-comment"
reset
run -- pr-comments 101
expect "pr-comments -> 3 comments" '[ "$rc" = 0 ] && jq_true "length == 3 and .[0].author == \"astra\" and (.[0] | keys) == [\"at\",\"author\",\"body\",\"url\"]"'
run -- pr-set-base 101 main
expect "pr-set-base -> PATCH /pulls/{n} {base}" '[ "$rc" = 0 ] && log_line "PATCH $R/pulls/101 token=$TOKEN" && body_true PATCH.pulls_101 ". == {base: \"main\"}"'
run -- pr-files 101
expect "pr-files -> changed paths over both pages" '[ "$rc" = 0 ] && [ "$out" = "$(printf "a.sh\nb/c.jq\nd/e.md")" ]'
run -- pr-diff 101
expect "pr-diff -> GET /pulls/{n}.diff" '[ "$rc" = 0 ] && grep -q "^diff --git" <<<"$out" && log_line "GET $R/pulls/101.diff token=$TOKEN"'
run -- ci-failures 101
expect "ci-failures -> exit 4 (unsupported)" '[ "$rc" = 4 ]'
run -- pr-view 999
expect "pr-view of a missing PR (404) -> exit 1" '[ "$rc" = 1 ] && grep -qF 404 <<<"$err"'
run -- pr-bogus
expect "unknown op -> usage exit 2" '[ "$rc" = 2 ]'

# --- FORGE_URL / FORGE_REPO defaults (§7.2) -----------------------------------
reset
run FORGE_URL=https://code.example.org/ FORGE_REPO=team/proj -- pr-diff 101
expect "FORGE_URL/FORGE_REPO override the origin" 'log_has "GET https://code.example.org/api/v1/repos/team/proj/pulls/101.diff"'
git -C "$tmp" remote set-url origin https://code.example.org/gitea/team/proj.git
run -- pr-diff 101
expect "origin https with a sub-path -> FORGE_URL keeps it" 'log_has "GET https://code.example.org/gitea/api/v1/repos/team/proj/pulls/101.diff"'
run FORGE_DRY_RUN=1 -- pr-set-base 101 main
expect "FORGE_DRY_RUN prints the URL path, sub-path included" '[ "$(sed -n 1p <<<"$out")" = "PATCH /gitea/api/v1/repos/team/proj/pulls/101" ]'
git -C "$tmp" remote set-url origin ssh://git@gitea.example.com:2222/example/repo.git
run -- pr-diff 101
expect "origin ssh:// with a port -> https://host, ssh port dropped" 'log_has "GET $R/pulls/101.diff"'
git -C "$tmp" remote set-url origin git@gitea.example.com:example/repo.git

# --- resolve_labels: the org-label fallback answering 403 / 404 ----------------
# A repo-scoped token gets 403 from GET /orgs/<owner>/labels (no
# read:organization), for a user owner too: that is "no org labels", and the
# error must name the missing label, not the 403.
reset
touch "$tmp/state/org-labels-403"
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label agent-authored --label no-such-label
expect "pr-create --label: org fallback 403 -> exit 1 naming the unknown label, nothing sent" \
  'log_has "GET $B/orgs/example/labels?" && [ "$rc" = 1 ] && grep -qF "unknown label(s) on example/repo: no-such-label;" <<<"$err" && [ "$(log_count POST)" = 0 ] && [ -z "$out" ]'
expect "pr-create --label: … and says the org labels were not readable (HTTP 403)" 'grep -qF "not readable, HTTP 403" <<<"$err"'
reset
touch "$tmp/state/org-labels-403"
run FORGE_URL=https://gitea.example.com FORGE_REPO=someone/repo -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label nope
expect "pr-create --label: a user owner answering 403 -> unknown label exit 1, nothing sent" \
  'log_has "GET $B/orgs/someone/labels?" && [ "$rc" = 1 ] && grep -qF "unknown label(s) on someone/repo: nope;" <<<"$err" && [ "$(log_count POST)" = 0 ]'
reset
touch "$tmp/state/org-labels-403"
run FORGE_DRY_RUN=1 -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label agent-authored --label task
expect "pr-create --label: every name on the repo -> no org lookup, so its 403 never matters" \
  '[ "$rc" = 0 ] && [ "$(sed -n 2p <<<"$out" | jq -c .labels)" = "[12,13]" ] && [ "$(log_count "/orgs/")" = 0 ]'
reset
run FORGE_URL=https://gitea.example.com FORGE_REPO=someone/repo -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label nope
expect "pr-create --label: org fallback 404 -> unknown label, no 403 note" \
  '[ "$rc" = 1 ] && grep -qF "unknown label(s) on someone/repo: nope;" <<<"$err" && ! grep -qF "HTTP 403" <<<"$err"'
reset
touch "$tmp/state/repo-labels-403"
run -- pr-create --head h --base b --title T --body-file "$tmp/body.md" --label agent-authored
expect "pr-create --label: a 403 on the REPO labels still fails loudly (HTTP 403, not 'unknown label')" \
  '[ "$rc" = 1 ] && grep -qF "HTTP 403" <<<"$err" && grep -qF "repos/example/repo/labels" <<<"$err" && ! grep -qF "unknown label" <<<"$err" && [ "$(log_count POST)" = 0 ] && [ "$(log_count "/orgs/")" = 0 ]'

# --- label-ensure: create a missing repo label, leave an existing one ----------
reset
run -- label-ensure agent-authored EDEDED "Produced by an agent"
expect "label-ensure: a repo label that exists -> {created:false}, no POST, no org lookup" \
  '[ "$rc" = 0 ] && jq_true ".name == \"agent-authored\" and .created == false" && [ "$(log_count POST)" = 0 ] && [ "$(log_count "/orgs/")" = 0 ]'
reset
run -- label-ensure promote 0B6E99 "x"
expect "label-ensure: an owner-org label counts as existing (pr-create resolves it) -> no POST" \
  '[ "$rc" = 0 ] && jq_true ".created == false" && [ "$(log_count POST)" = 0 ]'
reset
run -- label-ensure needs-human B60205 "Escalated: a human must intervene"
expect "label-ensure: a missing label -> one POST /labels {name, color #rrggbb, description}, {created:true}" \
  '[ "$rc" = 0 ] && jq_true ".name == \"needs-human\" and .created == true" && log_line "POST $R/labels token=$TOKEN" && [ "$(log_count POST)" = 1 ] && body_true POST.labels ". == {name: \"needs-human\", color: \"#B60205\", description: \"Escalated: a human must intervene\"}"'
reset
touch "$tmp/state/org-labels-403"
run -- label-ensure needs-human B60205 "d"
expect "label-ensure: org fallback 403 -> still creates the repo label" '[ "$rc" = 0 ] && jq_true ".created == true" && [ "$(log_count POST)" = 1 ]'
reset
touch "$tmp/state/repo-labels-403"
run -- label-ensure needs-human B60205 "d"
expect "label-ensure: a 403 on the repo labels -> exit 1, nothing created" '[ "$rc" = 1 ] && grep -qF "HTTP 403" <<<"$err" && [ "$(log_count POST)" = 0 ] && [ -z "$out" ]'
reset
run FORGE_DRY_RUN=1 -- label-ensure needs-human B60205 "d"
expect "FORGE_DRY_RUN: label-ensure prints the POST instead of sending it" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "POST /api/v1/repos/example/repo/labels" ] && [ "$(sed -n 2p <<<"$out" | jq -r .name)" = needs-human ] && [ "$(log_count POST)" = 0 ]'
reset
run -- label-ensure needs-human "#B60205" "d"
expect "label-ensure: a color that is not 6 hex digits -> usage exit 2, no request" '[ "$rc" = 2 ] && [ ! -s "$tmp/state/log" ]'
run -- label-ensure needs-human B60205
expect "label-ensure: a missing argument -> usage exit 2, no request" '[ "$rc" = 2 ] && [ ! -s "$tmp/state/log" ]'
run -- label-ensure $'a\nb' B60205 "d"
expect "label-ensure: a name with a newline -> exit 1, no request" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ]'

# --- forge.sh runs the config check before any I/O ----------------------------
reset
run GITEA_TOKEN= -- pr-view 101
expect "FORGE=gitea without GITEA_TOKEN -> exit 1, no request" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ] && grep -qF GITEA_TOKEN <<<"$err"'
run GRAPH_BACKEND=github -- pr-view 101
expect "GRAPH_BACKEND=github with FORGE=gitea -> exit 1, no request" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ]'

if [ "$fails" -ne 0 ]; then
  echo "forge-gitea tests FAILED" >&2
  exit 1
fi
echo "forge-gitea tests passed"
