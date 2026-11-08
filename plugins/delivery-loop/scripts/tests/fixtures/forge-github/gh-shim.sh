#!/usr/bin/env bash
# gh-shim.sh — an offline, recording stand-in for `gh`, for forge-github tests.
#
# The test installs it on PATH as `gh`. Every call is appended to $SHIM_STATE/log
# as one line: `gh[GH_TOKEN=<t> GH_REPO=<r>] <args…>` (each part only when that
# variable is set). Responses come from the fixtures in $SHIM_FX:
#   prs.json    {"<n>": <gh pr view object>, "<n>.<k>": <object for the k-th view>}
#   lists.json  {"open"|"merged": [[page 1 …], [page 2 …]]}
# Like real gh, `--json a,b` keeps only the requested fields and `pr list`
# concatenates pages up to `--limit`.
# Behaviour switches (files in $SHIM_STATE): reject-self-review — `pr review`
# without GH_TOKEN fails as GitHub does on one's own PR.
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
    pick "$fields" <<<"$obj" ;;
  "pr list")
    state=$(opt --state "$@"); limit=$(opt --limit "$@"); head=$(opt --head "$@"); fields=$(opt --json "$@")
    jq -c --arg s "${state:-open}" --arg h "$head" --argjson lim "${limit:-30}" \
      '[(.[$s] // [])[][] | select($h == "" or .headRefName == $h)] | .[0:$lim]' "$SHIM_FX/lists.json" \
      | jq -c --arg f "$fields" 'map(. as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k]))' ;;
  "pr create") echo "https://github.com/example/repo/pull/150" ;;
  "pr review")
    cp "$(opt --body-file "$@")" "$SHIM_STATE/review-body"
    if [ -f "$SHIM_STATE/reject-self-review" ] && [ -z "${GH_TOKEN:-}" ]; then
      echo "failed to create review: GraphQL: Review Can not approve your own pull request (addPullRequestReview)" >&2
      exit 1
    fi ;;
  "pr comment")
    cp "$(opt --body-file "$@")" "$SHIM_STATE/comment-body"
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
