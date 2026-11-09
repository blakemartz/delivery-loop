#!/usr/bin/env bash
# gh-shim.sh — an offline, recording, stateful stand-in for `gh`, for
# promote-test.sh (promote.sh and tick-merge.sh through forge-github.sh).
#
# The test installs it on PATH as `gh`. Every call is appended to
# $SHIM_STATE/log as `gh <args…>`. The PRs live in $SHIM_STATE/prs.json,
# {"<n>": <gh pr view object>}, which the test writes per case:
#   pr view <n> --json F    the object, only the requested fields. While
#                           $SHIM_STATE/unknown-<n> holds a count > 0, each view
#                           decrements it and reports mergeStateStatus UNKNOWN.
#   pr list --state S [--head H] --json F
#                           every PR in state S (OPEN | MERGED), by number.
#   pr create …             copies --body-file to $SHIM_STATE/create-body,
#                           records PR #150 (OPEN, the --head/--base/--title,
#                           the body, one label per --label) in prs.json, and
#                           prints its URL.
#   pr merge <n> …          sets PR n MERGED (mergedAt now), unless
#                           $SHIM_STATE/merge-noop exists (the merge silently
#                           did not happen).
#   api -X DELETE …         the head-branch delete after a squash: ok.
# Anything else exits 64, so an unexpected call fails the test loudly.
set -euo pipefail

: "${SHIM_STATE:?}"
echo "gh $*" >> "$SHIM_STATE/log"
prs="$SHIM_STATE/prs.json"
[ -f "$prs" ] || echo '{}' > "$prs"

opt() {
  local f="$1"; shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "$f" ]; then echo "${2:-}"; return; fi
    shift
  done
}
pick() { jq -c --arg f "$1" '. as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k])'; }

case "${1:-} ${2:-}" in
  "pr view")
    n="$3"; fields=$(opt --json "$@")
    obj=$(jq -c --arg n "$n" '.[$n] // empty' "$prs")
    [ -n "$obj" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $n." >&2; exit 1; }
    u="$SHIM_STATE/unknown-$n"
    if [ -f "$u" ] && [ "$(cat "$u")" -gt 0 ]; then
      echo $(( $(cat "$u") - 1 )) > "$u"
      obj=$(jq -c '.mergeStateStatus = "UNKNOWN" | .mergeable = "UNKNOWN"' <<<"$obj")
    fi
    pick "$fields" <<<"$obj" ;;
  "pr list")
    state=$(opt --state "$@"); head=$(opt --head "$@"); fields=$(opt --json "$@")
    jq -c --arg s "$(printf '%s' "${state:-open}" | tr '[:lower:]' '[:upper:]')" --arg h "$head" --arg f "$fields" '
      [.[] | select(.state == $s and ($h == "" or .headRefName == $h))] | sort_by(.number)
      | map(. as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k]))' "$prs" ;;
  "pr create")
    cp "$(opt --body-file "$@")" "$SHIM_STATE/create-body"
    head=$(opt --head "$@"); base=$(opt --base "$@"); labels="[]"
    while [ $# -gt 0 ]; do
      if [ "$1" = --label ]; then labels=$(jq -c --arg l "${2:-}" '. + [{name: $l}]' <<<"$labels"); fi
      shift
    done
    jq --arg head "$head" --arg base "$base" --argjson labels "$labels" \
       --rawfile body "$SHIM_STATE/create-body" '
      .["150"] = {number: 150, url: "https://github.com/example/repo/pull/150", state: "OPEN",
        headRefName: $head, baseRefName: $base, headRefOid: "0000000", mergeable: "MERGEABLE",
        mergeStateStatus: "CLEAN", statusCheckRollup: [], body: $body, labels: $labels,
        comments: [], reviews: [], author: {login: "agent"}, closingIssuesReferences: [], mergedAt: null}' \
      "$prs" > "$prs.new"
    mv "$prs.new" "$prs"
    echo "https://github.com/example/repo/pull/150" ;;
  "pr merge")
    if [ ! -f "$SHIM_STATE/merge-noop" ]; then
      jq --arg n "$3" '.[$n].state = "MERGED" | .[$n].mergedAt = (now | todate)' "$prs" > "$prs.new"
      mv "$prs.new" "$prs"
    fi ;;
  "api -X") echo '{}' ;;
  *) echo "gh-shim: unhandled call: gh $*" >&2; exit 64 ;;
esac
