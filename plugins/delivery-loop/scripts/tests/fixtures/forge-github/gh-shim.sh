#!/usr/bin/env bash
# gh-shim.sh — an offline, recording stand-in for `gh`, for forge-github tests.
#
# The test installs it on PATH as `gh`. Every call is appended to $SHIM_STATE/log
# as one line: `gh[GH_TOKEN=<t> GH_REPO=<r>] <args…>` (each part only when that
# variable is set). Responses come from the fixtures in $SHIM_FX:
#   prs.json    {"<n>": <gh pr view object>, "<n>.<k>": <object for the k-th view>}
#   lists.json  {"open"|"merged": [[page 1 …], [page 2 …]]}
# A comment posted (`pr comment`) since the last reset is appended to that PR's
# `comments` ($SHIM_STATE/posted-comments-<n>.json), so a comment-form verdict
# can round-trip through pr-reviews.
# Like real gh, `--json a,b` keeps only the requested fields and `pr list`
# concatenates pages up to `--limit`; a `--search` list is further capped at
# 1000 results, as GitHub search is.
# Behaviour switches (files in $SHIM_STATE):
#   reject-self-review — `pr review` without GH_TOKEN fails as GitHub does on
#                        one's own PR.
#   fail-comment       — `pr comment` fails (no URL, exit 1), as on a
#                        permissions or network error.
#   many-merged        — the merged list is 1200 PRs, all merged in the window.
set -euo pipefail

: "${SHIM_FX:?}" "${SHIM_STATE:?}"
tag=""
[ -z "${GH_TOKEN:-}" ] || tag="GH_TOKEN=$GH_TOKEN"
[ -z "${GH_REPO:-}" ] || tag="${tag:+$tag }GH_REPO=$GH_REPO"
echo "gh${tag:+[$tag]} $*" >> "$SHIM_STATE/log"

# opt <flag> <args…>: the value following <flag>, or empty.
opt() {
  local f="$1"; shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "$f" ]; then echo "${2:-}"; return; fi
    shift
  done
}

# pick <fields>: keep only the requested `--json` fields (absent → null).
pick() { jq --arg f "$1" '. as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k])'; }

case "${1:-} ${2:-}" in
  "api user") echo '{"login":"shim-user","id":1}' ;;
  "api -X")   echo '{}' ;;
  "pr view")
    n="$3"; fields=$(opt --json "$@")
    count_file="$SHIM_STATE/view-$n.count"
    k=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$count_file"
    obj=$(jq -c --arg a "$n.$k" --arg b "$n" '.[$a] // .[$b] // empty' "$SHIM_FX/prs.json")
    [ -n "$obj" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $n." >&2; exit 1; }
    posted="$SHIM_STATE/posted-comments-$n.json"; [ -f "$posted" ] || posted=/dev/null
    jq -c --slurpfile p "$posted" '.comments = ((.comments // []) + $p)' <<<"$obj" | pick "$fields" ;;
  "pr list")
    state=$(opt --state "$@"); limit=$(opt --limit "$@"); head=$(opt --head "$@"); fields=$(opt --json "$@")
    lim="${limit:-30}"
    if [ -n "$(opt --search "$@")" ] && [ "$lim" -gt 1000 ]; then lim=1000; fi
    many=false; [ ! -f "$SHIM_STATE/many-merged" ] || many=true
    jq -c --arg s "${state:-open}" --arg h "$head" --argjson lim "$lim" --argjson many "$many" \
      'if $many then .merged = [[range(1200) | {number: (2000 + .), headRefName: "task/bulk-\(.)", mergedAt: "2026-11-08T12:00:00Z"}]] else . end
       | [(.[$s] // [])[][] | select($h == "" or .headRefName == $h)] | .[0:$lim]' "$SHIM_FX/lists.json" \
      | jq -c --arg f "$fields" 'map(. as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k]))' ;;
  "pr create") echo "https://github.com/example/repo/pull/150" ;;
  "pr review")
    cp "$(opt --body-file "$@")" "$SHIM_STATE/review-body"
    if [ -f "$SHIM_STATE/reject-self-review" ] && [ -z "${GH_TOKEN:-}" ]; then
      echo "failed to create review: GraphQL: Review Can not approve your own pull request (addPullRequestReview)" >&2
      exit 1
    fi ;;
  "pr comment")
    if [ -f "$SHIM_STATE/fail-comment" ]; then
      echo "GraphQL: Resource not accessible by integration (addComment)" >&2
      exit 1
    fi
    cp "$(opt --body-file "$@")" "$SHIM_STATE/comment-body"
    jq -cn --rawfile b "$SHIM_STATE/comment-body" --arg n "$3" \
      '{id: "IC_posted", author: {login: "shim-user"}, authorAssociation: "OWNER", body: $b,
        createdAt: "2026-11-08T15:00:00Z", url: "https://github.com/example/repo/pull/\($n)#issuecomment-9001"}' \
      >> "$SHIM_STATE/posted-comments-$3.json"
    echo "https://github.com/example/repo/pull/$3#issuecomment-9001" ;;
  "pr merge") : ;;
  "pr edit")  echo "https://github.com/example/repo/pull/$3" ;;
  "pr diff")
    if [ "${4:-}" = --name-only ]; then printf 'a.sh\nb/c.jq\n'
    else printf 'diff --git a/a.sh b/a.sh\n'; fi ;;
  "run list") echo '[{"databaseId":77}]' ;;
  "run view") echo "job-failure  step  error: boom" ;;
  *) echo "gh-shim: unhandled call: gh $*" >&2; exit 64 ;;
esac
