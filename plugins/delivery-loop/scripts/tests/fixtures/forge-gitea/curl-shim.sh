#!/usr/bin/env bash
# curl-shim.sh — an offline, recording stand-in for `curl`, for forge-gitea tests.
#
# The test installs it on PATH as `curl`. It understands the flags the adapter
# sends (-X, -H [@file], --data-binary @file, -D, -o, -w '%{http_code}') and
# answers Gitea/Forgejo REST v1 routes from the fixtures in $SHIM_FX:
#   prs.json       {"<n>": <PullRequest>, "<n>.<k>": <PullRequest for the k-th GET>}
#   lists.json     {"open"|"closed": [<n>, …]}  (closed in sort=recentupdate order)
#   statuses.json  {"<sha>": <CombinedStatus>}  (missing sha → no statuses)
#                  `statuses` holds every status; the route pages it as both
#                  forges do (src: GetCombinedCommitStatusByRef), recomputing
#                  `state` and `total_count` over the returned page only.
#   reviews.json   {"<n>": [<PullReview>]}      comments.json {"<n>": [<Comment>]}
#   files.json     {"<n>": [<ChangedFile>]}
# Lists are sliced by `limit`/`page` like the server (limit clamped to
# max_response_items = 2) and carry the headers the real servers send (src):
#   X-Total-Count on every paged route; `Link: rel="next"` (while a next page
#   exists) on /pulls and /pulls/{n}/files only. /pulls/{n}/reviews never sends
#   Link (ListPullReviews: SetTotalCountHeader only, both forges), nor does
#   /commits/{sha}/status on Forgejo (the default); SHIM_FORGE=gitea gives the
#   status route Link too (Gitea calls SetLinkHeader there).
# Header overrides, to drive each branch of the adapter's paging:
#   SHIM_LINK=all   — Link on every paged route;  SHIM_LINK=none — on none.
#   SHIM_NO_TOTAL=1 — no X-Total-Count on any route.
#
# Every call appends one line to $SHIM_STATE/log:
#   `<METHOD> <url> token=<token>`
# its full argv to $SHIM_STATE/argv, and a request body to
# $SHIM_STATE/<METHOD>.<route>.json (route = the path after /repos/o/r/, with
# `/` → `_`, e.g. POST.pulls_101_merge.json).
# Behaviour switches (files in $SHIM_STATE):
#   reject-self-review — POST reviews with an APPROVED/REQUEST_CHANGES event and
#                        a token other than rev-tok gets Gitea's 422.
#   fail-comment       — POST issue comments gets a 403.
#   merge-later        — POST merge gets 405 "Please try again later".
#   merge-conflict     — POST merge gets 409 (head out of date).
#   rate-limit-once    — the next request gets a 429 (the switch is consumed).
set -euo pipefail

: "${SHIM_FX:?}" "${SHIM_STATE:?}"
printf '%s\n' "$*" >> "$SHIM_STATE/argv"

method=GET auth="" data="" dfile="" ofile="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) h="$2"; case "$h" in @*) h=$(cat "${h#@}") ;; esac
        case "$h" in "Authorization: token "*) auth="${h#Authorization: token }" ;; esac
        shift 2 ;;
    --data-binary) d="$2"; case "$d" in @*) data=$(cat "${d#@}") ;; *) data="$d" ;; esac; shift 2 ;;
    -D) dfile="$2"; shift 2 ;;
    -o) ofile="$2"; shift 2 ;;
    -w|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$method $url token=$auth" >> "$SHIM_STATE/log"

path="${url%%\?*}"; q=""
case "$url" in *\?*) q="${url#*\?}" ;; esac
qp() { printf '&%s&' "$q" | sed -n "s/.*&$1=\([^&]*\)&.*/\1/p"; }
rest="${path#*/api/v1}"                       # /repos/o/r/pulls/101, /user, …
route="$rest"
case "$rest" in /repos/*/*/*) route="${rest#/repos/*/*/}" ;; esac
base="${url%%/api/v1*}"
[ -z "$data" ] || printf '%s\n' "$data" > "$SHIM_STATE/$method.$(printf '%s' "$route" | tr '/' '_').json"

status=200 headers="" body=""
respond() { status="$1"; body="$2"; }
err() { respond "$1" "$(jq -cn --arg m "$2" --arg u "$base" '{message: $m, url: ($u + "/api/swagger")}')"; }
pr_obj() { jq -c --arg k "$1" '.[$k] // empty' "$SHIM_FX/prs.json"; }

# page <json-array> [link]: slice by limit/page, set X-Total-Count and, when the
# route sends it (second arg "link", subject to SHIM_LINK), Link headers.
page() {
  local all="$1" link="${2:-}" lim pg total last
  lim=$(qp limit); pg=$(qp page)
  lim="${lim:-2}"; pg="${pg:-1}"
  [ "$lim" -le 2 ] || lim=2
  total=$(jq 'length' <<<"$all")
  last=$(( (total + lim - 1) / lim )); [ "$last" -ge 1 ] || last=1
  body=$(jq -c --argjson l "$lim" --argjson p "$pg" '.[($p - 1) * $l: $p * $l]' <<<"$all")
  case "${SHIM_LINK:-}" in all) link=link ;; none) link="" ;; esac
  headers=""
  [ "${SHIM_NO_TOTAL:-}" = 1 ] || headers="X-Total-Count: $total"
  if [ -n "$link" ] && [ "$pg" -lt "$last" ]; then
    nq=$(printf '&%s' "$q" | sed "s/&page=[0-9]*//; s/^&//")
    headers="${headers:+$headers
}Link: <$path?$nq&page=$((pg + 1))>; rel=\"next\",<$path?$nq&page=$last>; rel=\"last\""
  fi
}

if [ -f "$SHIM_STATE/rate-limit-once" ]; then
  rm -f "$SHIM_STATE/rate-limit-once"
  err 429 "rate limit exceeded"
else
  case "$method $route" in
    "GET /user") respond 200 '{"id":2,"login":"shim-user","full_name":"","email":"shim-user@noreply.gitea.example.com"}' ;;
    "GET /settings/api")
      respond 200 '{"max_response_items":2,"default_paging_num":2,"default_git_trees_per_page":1000,"default_max_blob_size":10485760}' ;;
    "GET pulls")
      st=$(qp state)
      page "$(jq -c --arg s "${st:-open}" --slurpfile prs "$SHIM_FX/prs.json" \
                '(.[$s] // []) | map(. as $n | $prs[0][$n | tostring])' "$SHIM_FX/lists.json")" link ;;
    "POST pulls")
      respond 201 "$(jq -c --arg u "$base" '{id: 1150, number: 150, title: .title, body: .body, state: "open",
                       html_url: "\($u)/example/repo/pulls/150", head: {ref: .head}, base: {ref: .base}}' <<<"$data")" ;;
    GET\ pulls/*.diff) respond 200 'diff --git a/a.sh b/a.sh' ;;
    GET\ pulls/*/files)
      n="${route#pulls/}"; n="${n%/files}"
      page "$(jq -c --arg n "$n" '.[$n] // []' "$SHIM_FX/files.json")" link ;;
    GET\ pulls/*/reviews)
      n="${route#pulls/}"; n="${n%/reviews}"
      page "$(jq -c --arg n "$n" '.[$n] // []' "$SHIM_FX/reviews.json")" ;;
    POST\ pulls/*/reviews)
      n="${route#pulls/}"; n="${n%/reviews}"
      ev=$(jq -r .event <<<"$data")
      if [ -f "$SHIM_STATE/reject-self-review" ] && [ "$auth" != rev-tok ] && [ "$ev" != COMMENT ]; then
        if [ "$ev" = APPROVED ]; then err 422 "approve your own pull is not allowed"
        else err 422 "reject your own pull is not allowed"; fi
      else
        respond 200 "$(jq -c --arg u "$base" --arg n "$n" '{id: 55, state: .event, body: .body, commit_id: .commit_id,
                         html_url: "\($u)/example/repo/pulls/\($n)#issuecomment-55"}' <<<"$data")"
      fi ;;
    POST\ pulls/*/merge)
      if [ -f "$SHIM_STATE/merge-later" ]; then err 405 "Please try again later"
      elif [ -f "$SHIM_STATE/merge-conflict" ]; then err 409 "head out of date"
      else respond 200 ''; fi ;;
    GET\ pulls/*)
      n="${route#pulls/}"
      cf="$SHIM_STATE/view-$n.count"
      k=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$cf"
      obj=$(pr_obj "$n.$k"); [ -n "$obj" ] || obj=$(pr_obj "$n")
      if [ -n "$obj" ]; then respond 200 "$obj"; else err 404 "The target couldn't be found."; fi ;;
    PATCH\ pulls/*)
      n="${route#pulls/}"; obj=$(pr_obj "$n")
      respond 201 "$(jq -c --argjson d "$data" '.base.ref = $d.base' <<<"$obj")" ;;
    GET\ issues/*/comments)
      n="${route#issues/}"; n="${n%/comments}"
      respond 200 "$(jq -c --arg n "$n" '.[$n] // []' "$SHIM_FX/comments.json")" ;;
    POST\ issues/*/comments)
      n="${route#issues/}"; n="${n%/comments}"
      if [ -f "$SHIM_STATE/fail-comment" ]; then
        err 403 "token does not have at least one of required scope(s): [write:issue]"
      else
        respond 201 "$(jq -c --arg u "$base" --arg n "$n" '{id: 9001, body: .body,
                         html_url: "\($u)/example/repo/pulls/\($n)#issuecomment-9001"}' <<<"$data")"
      fi ;;
    GET\ commits/*/status)
      sha="${route#commits/}"; sha="${sha%/status}"
      cs=$(jq -c --arg s "$sha" '.[$s] // {state: "", sha: $s, total_count: 0, statuses: []}' "$SHIM_FX/statuses.json")
      if [ "${SHIM_FORGE:-forgejo}" = gitea ]; then page "$(jq -c '.statuses' <<<"$cs")" link
      else page "$(jq -c '.statuses' <<<"$cs")"; fi
      # Gitea's CalcCommitStatus over this page: the worst state wins.
      body=$(jq -c --argjson pg "$body" '.statuses = $pg | .total_count = ($pg | length)
        | .state = ([$pg[].status] as $s
                    | if ($s | length) == 0 then ""
                      else first(("error", "failure", "pending", "warning", "success", "skipped") as $w
                                 | select(any($s[]; . == $w)) | $w) end)' <<<"$cs") ;;
    *) echo "curl-shim: unhandled request: $method $url" >&2; exit 64 ;;
  esac
fi

if [ -n "$dfile" ]; then
  { printf 'HTTP/1.1 %s\r\nContent-Type: application/json;charset=utf-8\r\n' "$status"
    [ -z "$headers" ] || printf '%s\n' "$headers" | sed 's/$/\r/'
    printf '\r\n'; } > "$dfile"
fi
if [ -n "$ofile" ]; then printf '%s' "$body" > "$ofile"; else printf '%s' "$body"; fi
printf '%s' "$status"
