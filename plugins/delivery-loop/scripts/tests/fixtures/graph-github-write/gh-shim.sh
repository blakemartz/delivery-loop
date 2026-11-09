#!/usr/bin/env bash
# gh-shim.sh — an offline, recording, STATEFUL stand-in for `gh`, for the github
# write path (tests/graph-github-write-test.sh). It serves both the new backend
# (backends/graph-github.sh, forge-github.sh) and v0.1.4's task-queue.sh /
# claim-task.sh, so the two can be run against the same board and compared.
#
# Every call is appended to $SHIM_STATE/log as one line: `gh <args…>`.
# State (files in $SHIM_STATE, set up by the test):
#   board.json      issues, in the `gh issue view --json …` shape (plus optional
#                   `_closers: [<pr number>|{number, repo}]`: the PRs whose
#                   closing keyword closed the issue, served as its timeline's
#                   ClosedEvent closers to `api graphql`)
#   prs.json        PRs, in the `gh pr view --json …` shape (plus `mergedAt`)
#   default-branch  the repo default branch (default: main)
#   clock           the last timestamp handed out (epoch seconds)
# Writes (issue comment/edit/close/create) mutate board.json and stamp the
# issue's updatedAt (and a comment's createdAt) from a clock that follows real
# time but strictly increases, so comment order is total and staleness windows
# behave as on GitHub.
# Like real gh: `--json a,b` keeps only those fields; `--jq` filters; `issue list`
# defaults to `--state open --limit 30` and cuts each issue's comments to its
# first 100 (2.96.0); `issue view` returns them all; `pr list` defaults to
# `--state open --limit 30`; `issue close --comment` posts the comment first;
# `issue edit --add-blocked-by|--parent <n>` fails when #n is not an issue.
# Behaviour switches (files in $SHIM_STATE):
#   fail-<group>-<cmd>   that call fails with exit 1 (e.g. fail-issue-comment);
#                        the file's content, when non-empty, is a count of
#                        calls to let through first.
#   touch-before-view    holds an issue number: the next `issue view` of it
#                        first bumps its updatedAt (someone edited it between
#                        a plan and its apply), then the file is removed.
set -euo pipefail

: "${SHIM_STATE:?}"
echo "gh $*" >> "$SHIM_STATE/log"
board="$SHIM_STATE/board.json"
prs="$SHIM_STATE/prs.json"
[ -f "$board" ] || echo '[]' > "$board"
[ -f "$prs" ] || echo '[]' > "$prs"
me=shim-user
repo=example/repo

maybe_fail() {
  local f="$SHIM_STATE/fail-$1-$2" n
  [ -f "$f" ] || return 0
  n=$(cat "$f")
  if [ -n "$n" ] && [ "$n" -gt 0 ]; then echo $((n - 1)) > "$f"; return 0; fi
  echo "gh-shim: injected failure: gh $1 $2" >&2
  exit 1
}

# tick: the next timestamp (ISO-8601 UTC), strictly after the previous one.
tick() {
  local now last
  now=$(date -u +%s)
  last=$(cat "$SHIM_STATE/clock" 2>/dev/null || echo 0)
  [ "$now" -gt "$last" ] || now=$((last + 1))
  echo "$now" > "$SHIM_STATE/clock"
  jq -rn --argjson t "$now" '$t | todate'
}

# filter <json> <fields> <jq>: --json selection, then --jq.
filter() {
  local out="$1"
  if [ -n "$2" ]; then
    out=$(jq -c --arg f "$2" 'def pick1: . as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k]);
                               if type == "array" then map(pick1) else pick1 end' <<<"$out")
  fi
  if [ -n "$3" ]; then jq -r "$3" <<<"$out"; else printf '%s\n' "$out"; fi
}

save() { mv "$board.next" "$board"; }

group="${1:-}" cmd="${2:-}"
[ "$group" = --version ] && { echo "gh version ${SHIM_GH_VERSION:-2.96.0} (2026-07-02)"; exit 0; }
shift 2 || true
maybe_fail "$group" "$cmd"

# Parse the remaining flags. Repeatable ones accumulate (one JSON array each).
pos="" json="" jqf="" state="" limit="" label="" search="" base="" head="" body="" bodyfile=""
title="" reason="" comment="" parent="" graphq_n=""
adds='[]' removes='[]' add_as='[]' rm_as='[]' blocked='[]' labels='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json="$2"; shift 2 ;;
    --jq|-q) jqf="$2"; shift 2 ;;
    --state|-s) state="$2"; shift 2 ;;
    --limit|-L) limit="$2"; shift 2 ;;
    --label|-l) label="$2"; labels=$(jq -c --arg v "$2" '. + [$v]' <<<"$labels"); shift 2 ;;
    --search|-S) search="$2"; shift 2 ;;
    --base|-B) base="$2"; shift 2 ;;
    --head|-H) head="$2"; shift 2 ;;
    --body|-b) body="$2"; bodyfile=""; shift 2 ;;
    --body-file|-F)
      if [ "$group $cmd" = "api graphql" ]; then
        case "$2" in n=*) graphq_n="${2#n=}" ;; esac
      else
        bodyfile="$2"
      fi
      shift 2 ;;
    -f) shift 2 ;;
    --title|-t) title="$2"; shift 2 ;;
    --reason|-r) reason="$2"; shift 2 ;;
    --comment|-c) comment="$2"; shift 2 ;;
    --parent) parent="$2"; shift 2 ;;
    --add-label) adds=$(jq -c --arg v "$2" '. + [$v]' <<<"$adds"); shift 2 ;;
    --remove-label) removes=$(jq -c --arg v "$2" '. + [$v]' <<<"$removes"); shift 2 ;;
    --add-assignee|-a) add_as=$(jq -c --arg v "${2/#@me/$me}" '. + [$v]' <<<"$add_as"); shift 2 ;;
    --remove-assignee) rm_as=$(jq -c --arg v "${2/#@me/$me}" '. + [$v]' <<<"$rm_as"); shift 2 ;;
    --add-blocked-by|--blocked-by) blocked=$(jq -c --arg v "$2" '. + [$v | tonumber]' <<<"$blocked"); shift 2 ;;
    -R|--repo) shift 2 ;;
    *) [ -n "$pos" ] || pos="$1"; shift ;;
  esac
done
if [ -n "$bodyfile" ]; then
  if [ "$bodyfile" = - ]; then body=$(cat); else body=$(cat "$bodyfile"); fi
  bodyset=1
elif [ -n "$body" ]; then bodyset=1; else bodyset=0; fi

issue_exists() { jq -e --argjson n "$1" 'any(.[]; .number == $n)' "$board" > /dev/null; }
no_issue() { echo "GraphQL: Could not resolve to an issue or pull request with the number of $1. (repository.issue)" >&2; exit 1; }

# add_comment <n> <body>: append a comment and stamp updatedAt.
add_comment() {
  local ts; ts=$(tick)
  jq --argjson n "$1" --arg b "$2" --arg ts "$ts" --arg me "$me" \
    'map(if .number == $n then .comments += [{author: {login: $me}, authorAssociation: "OWNER", body: $b, createdAt: $ts}] | .updatedAt = $ts else . end)' \
    "$board" > "$board.next" && save
}

case "$group $cmd" in
  "repo view")
    filter "$(jq -cn --arg d "$(cat "$SHIM_STATE/default-branch" 2>/dev/null || echo main)" --arg r "$repo" \
      '{defaultBranchRef: {name: $d}, nameWithOwner: $r}')" "$json" "$jqf" ;;
  "api user")
    filter "$(jq -cn --arg me "$me" '{login: $me, id: 1}')" "" "$jqf" ;;
  "api graphql")
    [ -n "$graphq_n" ] || { echo "gh-shim: api graphql without -F n=<issue>" >&2; exit 64; }
    jq -c --argjson n "$graphq_n" --arg r "$repo" '
      (map(select(.number == $n)) | first) as $i
      | {data: {repository: {nameWithOwner: $r, issue: (if $i == null then null else
          {timelineItems: {nodes: ([ ($i._closers // [])[]
             | (if type == "object" then . else {number: ., repo: $r} end) as $c
             | {closer: {__typename: "PullRequest", number: $c.number, repository: {nameWithOwner: ($c.repo // $r)}}} ]
             + [ {closer: null} ]) }} end)}}}' "$board" ;;
  "issue list")
    out=$(jq -c --arg s "${state:-open}" --argjson lab "$labels" --argjson lim "${limit:-30}" '
      [ .[] | select($s == "all" or ($s == "open" and .state == "OPEN") or ($s == "closed" and .state == "CLOSED"))
        | select(. as $i | all($lab[]; . as $l | any($i.labels[]; .name == $l))) ]
      | sort_by(-.number) | .[0:$lim]
      | map(with_entries(select(.key | startswith("_") | not))
            | if (.comments | type) == "array" then .comments |= .[0:100] else . end)' "$board")
    filter "$out" "$json" "$jqf" ;;
  "issue view")
    issue_exists "$pos" || no_issue "$pos"
    if [ "$(cat "$SHIM_STATE/touch-before-view" 2>/dev/null || true)" = "$pos" ]; then
      rm -f "$SHIM_STATE/touch-before-view"
      ts=$(tick)
      jq --argjson n "$pos" --arg ts "$ts" 'map(if .number == $n then .updatedAt = $ts else . end)' "$board" > "$board.next" && save
    fi
    out=$(jq -c --argjson n "$pos" '.[] | select(.number == $n) | with_entries(select(.key | startswith("_") | not))' "$board")
    filter "$out" "$json" "$jqf" ;;
  "issue comment")
    issue_exists "$pos" || no_issue "$pos"
    [ "$bodyset" = 1 ] || { echo "gh-shim: issue comment needs a body" >&2; exit 64; }
    add_comment "$pos" "$body"
    echo "https://github.com/$repo/issues/$pos#issuecomment-1" ;;
  "issue edit")
    issue_exists "$pos" || no_issue "$pos"
    # Like GitHub: a blocked-by or parent target must be an issue of the repo.
    for t in $(jq -r '.[]' <<<"$blocked") $parent; do issue_exists "$t" || no_issue "$t"; done
    ts=$(tick)
    jq --argjson n "$pos" --arg ts "$ts" --argjson add "$adds" --argjson rm "$removes" \
       --argjson aa "$add_as" --argjson ra "$rm_as" --argjson bl "$blocked" \
       --arg title "$title" --arg body "$body" --argjson bodyset "$bodyset" --arg parent "$parent" '
      map(if .number != $n then . else
        .labels = ([.labels[] | select(.name as $l | ($rm | index($l)) == null)]
                   + [$add[] | . as $l | {id: "LA_\($l)", name: $l, description: "", color: "EDEDED"}]
                   | unique_by(.name))
        | .assignees = ([.assignees[] | select(.login as $l | ($ra | index($l)) == null)]
                        + [$aa[] | {id: "U_\(.)", login: ., name: .}] | unique_by(.login))
        | (if $bl != [] then .blockedBy = ((.blockedBy // {nodes: [], totalCount: 0})
             | .nodes = (.nodes + [$bl[] | {number: ., state: "OPEN"}] | unique_by(.number))
             | .totalCount = (.nodes | length)) else . end)
        | (if $title != "" then .title = $title else . end)
        | (if $bodyset == 1 then .body = $body else . end)
        | (if $parent != "" then .parent = {number: ($parent | tonumber)} else . end)
        | .updatedAt = $ts end)' "$board" > "$board.next" && save
    echo "https://github.com/$repo/issues/$pos" ;;
  "issue close")
    issue_exists "$pos" || no_issue "$pos"
    [ -z "$comment" ] || add_comment "$pos" "$comment"
    ts=$(tick)
    jq --argjson n "$pos" --arg ts "$ts" --arg r "${reason:-completed}" '
      map(if .number == $n then .state = "CLOSED"
          | .stateReason = ({"completed": "COMPLETED", "not planned": "NOT_PLANNED", "duplicate": "DUPLICATE"}[$r] // "COMPLETED")
          | .updatedAt = $ts else . end)' "$board" > "$board.next" && save
    echo "✓ Closed issue #$pos" ;;
  "issue create")
    ts=$(tick)
    n=$(jq '(map(.number) | max // 0) + 1' "$board")
    jq --argjson n "$n" --arg ts "$ts" --arg title "$title" --arg body "$body" --argjson labs "$labels" \
       --argjson bl "$blocked" --arg parent "$parent" '
      . + [{number: $n, title: $title, state: "OPEN", stateReason: "", body: $body,
            labels: [$labs[] | {id: "LA_\(.)", name: ., description: "", color: "EDEDED"}],
            assignees: [], comments: [], createdAt: $ts, updatedAt: $ts,
            blockedBy: {nodes: [$bl[] | {number: ., state: "OPEN"}], totalCount: ($bl | length)},
            parent: (if $parent == "" then null else {number: ($parent | tonumber)} end),
            closedByPullRequestsReferences: []}]' "$board" > "$board.next" && save
    echo "https://github.com/$repo/issues/$n" ;;
  "pr list")
    out=$(jq -c --arg s "${state:-open}" --arg b "$base" --arg h "$head" --arg q "$search" --argjson lim "${limit:-30}" '
      ([$q | capture("merged:>=(?<t>[^ ]+)") | .t] | first // null) as $since
      | [ .[] | select($s == "all" or .state == ($s | ascii_upcase))
          | select($b == "" or .baseRefName == $b) | select($h == "" or .headRefName == $h)
          | select($since == null or ((.mergedAt // "") >= $since)) ]
      | sort_by(-.number) | .[0:$lim]' "$prs")
    filter "$out" "$json" "$jqf" ;;
  "pr view")
    out=$(jq -c --argjson n "$pos" '.[] | select(.number == $n)' "$prs")
    [ -n "$out" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $pos." >&2; exit 1; }
    filter "$out" "$json" "$jqf" ;;
  *) echo "gh-shim: unhandled call: gh $group $cmd $*" >&2; exit 64 ;;
esac
