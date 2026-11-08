#!/usr/bin/env bash
# curl-shim.sh — an offline, recording stand-in for `curl`, for forge-gitlab tests.
#
# The test installs it on PATH as `curl`. It understands the flags the adapter
# sends (-X, -H [@file], --data-binary @file, -D, -o, -w '%{http_code}') and
# answers GitLab REST v4 routes under /projects/<url-encoded path>/ from the
# fixtures in $SHIM_FX, shaped after the docs.gitlab.com examples:
#   mrs.json       {"<iid>": <single-MR GET>, "<iid>.<k>": <MR for the k-th GET>}
#                  List routes return the same objects without the single-GET-only
#                  fields (head_pipeline, diff_refs, merge_error, user, …).
#   lists.json     {"opened"|"merged"|"closed": [<iid>, …]}  (created_at asc)
#   notes.json     {"<iid>": [<Note>]}       approvals.json {"<iid>": <approvals>}
#                  A note POSTed since the last reset is appended to the GET of
#                  that MR's notes ($SHIM_STATE/posted-notes-<iid>.json), so a
#                  verdict can round-trip through pr-reviews.
#   diffs.json     {"<iid>": [<MR diff>]}    jobs.json {"<pipeline id>": [<Job>]}
# Lists filter `state`, `source_branch` and `updated_after` (updated_at >= T)
# like the server, are sliced by `per_page`/`page` (per_page clamped to 2, so
# every fixture list spans pages) and carry pagination headers per SHIM_PAGING:
#   gitlab (default) — x-next-page (empty on the last page), x-page, x-per-page,
#                      x-prev-page, x-total, x-total-pages, Link (next/first/last)
#   big    — as above minus x-total, x-total-pages and rel="last" (above 10,000)
#   link   — Link only;   total — x-total only;   none — no pagination headers.
#
# Every call appends one line to $SHIM_STATE/log:
#   `<METHOD> <url> token=<PRIVATE-TOKEN>`
# its full argv to $SHIM_STATE/argv, and a request body to
# $SHIM_STATE/<METHOD>.<route>.json (route = the path after /projects/<id>/,
# with `/` → `_`, e.g. PUT.merge_requests_241_merge.json).
# Behaviour switches (files in $SHIM_STATE):
#   reject-self-approval — POST approve with a token other than rev-tok gets 401.
#   approve-conflict     — POST approve gets 409 (SHA does not match HEAD).
#   fail-note            — POST notes gets a 403.
#   merge-405 / merge-409 / merge-422 — PUT merge gets that error.
#   rate-limit-once      — the next request gets a 429 (the switch is consumed).
set -euo pipefail

: "${SHIM_FX:?}" "${SHIM_STATE:?}"
printf '%s\n' "$*" >> "$SHIM_STATE/argv"
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../backends" && pwd)"

method=GET auth="" data="" dfile="" ofile="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) h="$2"; case "$h" in @*) h=$(cat "${h#@}") ;; esac
        case "$h" in "PRIVATE-TOKEN: "*) auth="${h#PRIVATE-TOKEN: }" ;; esac
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
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; }
rest="${path#*/api/v4}"                       # /projects/<enc>/merge_requests/201, /user
route="$rest"
case "$rest" in /projects/*/*) route="${rest#/projects/*/}" ;; esac
[ -z "$data" ] || printf '%s\n' "$data" > "$SHIM_STATE/$method.$(printf '%s' "$route" | tr '/' '_').json"

status=200 headers="" body=""
respond() { status="$1"; body="$2"; }
err() { respond "$1" "$(jq -cn --arg m "$2" '{message: $m}')"; }
mr_obj() { jq -c --arg k "$1" '.[$k] // empty' "$SHIM_FX/mrs.json"; }
hdr() { headers="${headers:+$headers
}$1"; }

# page <json-array>: slice by per_page/page and set the SHIM_PAGING headers.
page() {
  local all="$1" lim pg total last mode="${SHIM_PAGING:-gitlab}" nq nextp prevp links
  lim=$(qp per_page); pg=$(qp page)
  lim="${lim:-20}"; pg="${pg:-1}"
  [ "$lim" -le 2 ] || lim=2
  total=$(jq 'length' <<<"$all")
  last=$(( (total + lim - 1) / lim )); [ "$last" -ge 1 ] || last=1
  body=$(jq -c --argjson l "$lim" --argjson p "$pg" '.[($p - 1) * $l: $p * $l]' <<<"$all")
  nextp=""; [ "$pg" -ge "$last" ] || nextp=$((pg + 1))
  prevp=""; [ "$pg" -le 1 ] || prevp=$((pg - 1))
  nq=$(printf '&%s' "$q" | sed "s/&page=[0-9]*//; s/^&//")
  links="<$path?$nq&page=1>; rel=\"first\""
  [ -z "$nextp" ] || links="<$path?$nq&page=$nextp>; rel=\"next\", $links"
  [ "$mode" = big ] || links="$links, <$path?$nq&page=$last>; rel=\"last\""
  headers=""
  case "$mode" in
    gitlab|big)
      hdr "x-next-page: $nextp"; hdr "x-page: $pg"; hdr "x-per-page: $lim"; hdr "x-prev-page: $prevp"
      if [ "$mode" = gitlab ]; then hdr "x-total: $total"; hdr "x-total-pages: $last"; fi
      hdr "Link: $links" ;;
    link) hdr "Link: $links" ;;
    total) hdr "x-total: $total" ;;
    none) : ;;
  esac
}

# The list-endpoint view of an MR: no single-GET-only fields.
list_view='del(.head_pipeline, .diff_refs, .merge_error, .user, .pipeline, .changes_count,
               .first_contribution, .latest_build_started_at, .latest_build_finished_at,
               .first_deployed_to_production_at, .subscribed, .diverged_commits_count)'

if [ -f "$SHIM_STATE/rate-limit-once" ]; then
  rm -f "$SHIM_STATE/rate-limit-once"
  err 429 "429 Too Many Requests"
else
  case "$method $route" in
    "GET /user") respond 200 '{"id":7,"username":"shim-user","name":"Shim User","state":"active","web_url":"https://gitlab.example.com/shim-user"}' ;;
    "GET merge_requests")
      st=$(qp state); src=$(urldecode "$(qp source_branch)"); ua=$(urldecode "$(qp updated_after)")
      page "$(jq -c --arg s "${st:-all}" --arg src "$src" --arg ua "$ua" --slurpfile mrs "$SHIM_FX/mrs.json" -L "$lib" -L "$lib/../lib" '
                include "forge-github";
                (if $s == "all" then [.[][]] else (.[$s] // []) end)
                | map(. as $n | $mrs[0][$n | tostring] | '"$list_view"')
                | map(select($src == "" or .source_branch == $src))
                | map(select($ua == "" or ((.updated_at | iso_epoch) >= ($ua | iso_epoch))))' "$SHIM_FX/lists.json")" ;;
    "POST merge_requests")
      respond 201 "$(jq -c '{id: 84250, iid: 250, project_id: 278964, title: .title, description: .description,
                       state: "opened", source_branch: .source_branch, target_branch: .target_branch,
                       web_url: "https://gitlab.example.com/example/sub/repo/-/merge_requests/250"}' <<<"$data")" ;;
    GET\ merge_requests/*/notes)
      n="${route#merge_requests/}"; n="${n%/notes}"
      posted="$SHIM_STATE/posted-notes-$n.json"; [ -f "$posted" ] || posted=/dev/null
      page "$(jq -c --arg n "$n" --slurpfile p "$posted" '(.[$n] // []) + $p' "$SHIM_FX/notes.json")" ;;
    POST\ merge_requests/*/notes)
      n="${route#merge_requests/}"; n="${n%/notes}"
      if [ -f "$SHIM_STATE/fail-note" ]; then err 403 "403 Forbidden"
      else
        respond 201 "$(jq -c --argjson n "$n" '{id: 9001, type: null, body: .body, author: {id: 7, username: "shim-user"},
                         created_at: "2026-11-08T15:00:00.000Z", system: false, noteable_iid: $n, noteable_type: "MergeRequest"}' <<<"$data")"
        printf '%s\n' "$body" >> "$SHIM_STATE/posted-notes-$n.json"
      fi ;;
    GET\ merge_requests/*/approvals)
      n="${route#merge_requests/}"; n="${n%/approvals}"
      respond 200 "$(jq -c --arg n "$n" '.[$n] // {approved: false, approved_by: []}' "$SHIM_FX/approvals.json")" ;;
    POST\ merge_requests/*/approve)
      n="${route#merge_requests/}"; n="${n%/approve}"
      if [ -f "$SHIM_STATE/approve-conflict" ]; then err 409 "SHA does not match HEAD of source branch"
      elif [ -f "$SHIM_STATE/reject-self-approval" ] && [ "$auth" != rev-tok ]; then err 401 "401 Unauthorized"
      else respond 201 "$(jq -c --arg n "$n" '.[$n] // {approved: true, approved_by: []}' "$SHIM_FX/approvals.json")"; fi ;;
    GET\ merge_requests/*/diffs)
      n="${route#merge_requests/}"; n="${n%/diffs}"
      page "$(jq -c --arg n "$n" '.[$n] // []' "$SHIM_FX/diffs.json")" ;;
    PUT\ merge_requests/*/merge)
      n="${route#merge_requests/}"; n="${n%/merge}"
      if [ -f "$SHIM_STATE/merge-405" ]; then err 405 "405 Method Not Allowed"
      elif [ -f "$SHIM_STATE/merge-409" ]; then err 409 "SHA does not match HEAD of source branch"
      elif [ -f "$SHIM_STATE/merge-422" ]; then err 422 "Branch cannot be merged"
      else respond 200 "$(mr_obj "$n")"; fi ;;
    GET\ merge_requests/*)
      n="${route#merge_requests/}"
      cf="$SHIM_STATE/view-$n.count"
      k=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$cf"
      obj=$(mr_obj "$n.$k"); [ -n "$obj" ] || obj=$(mr_obj "$n")
      if [ -n "$obj" ]; then respond 200 "$obj"; else err 404 "404 Not found"; fi ;;
    PUT\ merge_requests/*)
      n="${route#merge_requests/}"; obj=$(mr_obj "$n")
      respond 200 "$(jq -c --argjson d "$data" '.target_branch = $d.target_branch' <<<"$obj")" ;;
    GET\ pipelines/*/jobs)
      p="${route#pipelines/}"; p="${p%/jobs}"
      page "$(jq -c --arg p "$p" --arg sc "$(urldecode "$q")" '(.[$p] // [])
               | if ($sc | test("scope\\[\\]=failed")) then map(select(.status == "failed")) else . end' "$SHIM_FX/jobs.json")" ;;
    GET\ jobs/*/trace)
      j="${route#jobs/}"; j="${j%/trace}"
      respond 200 "$(printf 'Running job %s\n$ make test\nFAIL: case %s\nERROR: Job failed: exit code 1' "$j" "$j")" ;;
    *) echo "curl-shim: unhandled request: $method $url" >&2; exit 64 ;;
  esac
fi

if [ -n "$dfile" ]; then
  { printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n' "$status"
    [ -z "$headers" ] || printf '%s\n' "$headers" | sed 's/$/\r/'
    printf '\r\n'; } > "$dfile"
fi
if [ -n "$ofile" ]; then printf '%s' "$body" > "$ofile"; else printf '%s' "$body"; fi
printf '%s' "$status"
