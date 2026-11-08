#!/usr/bin/env bash
# forge-gitlab.sh <op> [args] — the gitlab forge adapter (curl + jq), behind forge.sh.
#
# Implements every op of docs/delivery_graph_spec.md §7.1 against
# ${FORGE_URL}/api/v4/projects/<url-encoded FORGE_REPO>/merge_requests… with
# `PRIVATE-TOKEN: $GITLAB_TOKEN`, normalizing through backends/forge-gitlab.jq
# (§7.3 gitlab column). It translates; it does not decide (§3 rule 2). Invoke
# it through forge.sh, which resolves the config and runs `--check` first
# (GITLAB_TOKEN set, GRAPH_BACKEND=local); this file only reads the exported keys.
#
# Exit codes: 0 ok · 1 operation failed / refused · 2 usage · 3 a list reached
# LIST_LIMIT (never a silent truncation) · 4 unsupported.
#
# FORGE_DRY_RUN=1: every write (POST/PUT) prints `METHOD PATH` and its JSON body
# on stdout instead of being sent, and the op stops there (exit 0). Reads are
# still sent: a dry run never mutates, but it does run the pre-reads (a stale
# --sha is still refused before anything is printed, GC30).
#
# Adapter notes (gitlab, REST v4):
#   - `number` is the MR `iid`, never the global `id`; every route takes the iid.
#   - the project is addressed by its URL-encoded full path (`group%2Fsub%2Fproj`).
#     FORGE_URL / FORGE_REPO default from `git remote get-url origin` (https,
#     scp-style ssh and ssh:// forms): FORGE_URL is the scheme and host (an ssh
#     remote maps to https://<host>) and FORGE_REPO the whole path, subgroups
#     included. An instance under a relative URL root needs FORGE_URL set.
#   - the token is passed to curl in a header file (`-H @file`, mode 600 under
#     a private temp dir), never on the command line.
#   - lists page with `per_page=100&page=n`. The next page is `x-next-page`
#     whenever that header is sent (empty on the last page); else the
#     `Link: rel="next"` page; else page+1 while fewer items than `x-total`
#     have arrived; with none of them, page+1 until a page comes back empty
#     (`x-total` is omitted above 10,000 items). Only the page number is taken
#     from a header: the request stays on FORGE_URL, so the token never follows
#     a link to another host. Reaching LIST_LIMIT exits 3 whichever way paging
#     goes. Lists sort `order_by=created_at&sort=asc`, so MRs opened while
#     paging land after the read pages; a duplicate iid is kept once.
#   - `mergeable` maps `detailed_merge_status` (§7.3). The async states
#     (unchecked/checking/preparing/approvals_syncing/ci_still_running) and an
#     absent status (servers before 15.6) are `unknown`: the MR is re-read 3
#     times with backoff, then stays `unknown`. Only `mergeable` is `clean`.
#   - `checks` is `head_pipeline.status`, the pipeline's own roll-up over all of
#     its jobs. `head_pipeline` is sent only by the single-MR GET, so `pr-list`
#     and `pr-find` re-read every MR they return (and re-poll an async
#     merge status: up to ~12 s per such MR). A merged-results or merge-train
#     pipeline (ref `refs/merge-requests/<iid>/merge|train`) runs on a synthetic
#     merge commit, so its status is taken as is; a branch pipeline (the source
#     branch or `…/<iid>/head`) for another commit than the MR head reads
#     `pending`. `head_pipeline` is sent only to users who may read pipelines:
#     a token without that right reads `none`.
#   - `pr-list --state merged --since T` filters server-side with
#     `updated_after=T` (merging updates the MR) and keeps `merged_at >= T`.
#   - `pr-create --draft` prefixes the title `Draft: ` (the create API has no
#     draft field).
#   - verdicts and merges pin the head SHA: a pre-read refuses a stale --sha
#     before any write, the approval carries `sha` and the merge `sha` (409 when
#     the head moved).
#   - `pr-review approve` POSTs `/approve` (sha only: it takes no body), then
#     posts the verdict body as a note, since that note carries `Reviewed-Head:`.
#     The approve route answers 401 when the user may not approve (src:
#     `unauthorized!` when ApprovalService fails), which covers an author
#     blocked from approving their own MR, and also a user who already
#     approved (a re-approval after a new push): the verdict is then the note
#     alone (form "comment"). There is no request-changes endpoint:
#     request-changes and comment are always a note (form "comment").
#     Every verdict note opens with a verdict heading, so `pr-reviews` finds
#     it whichever form landed: a body without one is prefixed
#     `## Adversarial review — verdict: <VERDICT>`; a body whose first line is
#     already a heading `## … verdict: <VERDICT>` is sent as is, and one naming
#     another verdict is refused.
#     GITLAB_REVIEW_TOKEN (environment only) posts the approval and the note as
#     that identity.
#   - a post (`pr-comment`, every `pr-review`) reports `posted:true` only on a
#     2xx; anything else exits 1 with no JSON. An approval whose note then fails
#     also exits 1: the verdict body never landed.
#   - `pr-reviews` lists the approvals (GET …/approvals) as `approve`, then the
#     non-system notes whose first non-blank line is a verdict heading
#     (`^## .*verdict: (APPROVE|REQUEST_CHANGES|COMMENT)`, any case).
#   - notes carry no URL; it is `<web_url>#note_<id>`, the MR page anchor.
#   - `pr-merge` PUTs …/merge `{squash, should_remove_source_branch, sha}` (405
#     cannot merge, 409 sha mismatch, 422 merge failed: each exits 1 at once),
#     then re-reads the MR (3 times with backoff while it still reads opened;
#     without `auto_merge` the merge is synchronous (src: execute_immediate_merge!
#     422s unless merged), so this is belt and braces) and exits 0
#     only if `state == merged`. Whether `squash:false` makes a merge commit is
#     the project's merge method (§7.3).
#   - `pr-diff` rebuilds `diff --git` file headers over GET …/diffs (all
#     pages); a file whose diff GitLab omitted (too large / collapsed) is named
#     on stderr.
#   - `ci-failures` prints the trace of every failed job of the head pipeline
#     (best effort; no head pipeline prints nothing).
#   - a 429 is retried 3 times with backoff (rate-limit headers are unverified).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib"

: "${LIST_LIMIT:=5000}"
: "${GRAPH_BACKEND:=local}"
: "${FORGE_URL:=}"
: "${FORGE_REPO:=}"
: "${FORGE_DRY_RUN:=}"

POLLS=3        # re-polls / retries of a transient answer (§7.3, GC57)
PER_PAGE=100   # GitLab's per_page maximum

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-forge-gitlab.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

die()   { echo "forge-gitlab: $*" >&2; exit 1; }
usage() { echo "forge-gitlab: usage: $*" >&2; exit 2; }
fjq()   { jq -L "$LIB" -L "$SCRIPT_DIR" "$@"; }
need_n() { case "${1:-}" in ''|*[!0-9]*) usage "$2" ;; esac; }
uri()   { jq -rn --arg s "$1" '$s | @uri'; }

tok="${GITLAB_TOKEN:-}"
[ -n "$tok" ] || die "GITLAB_TOKEN is not set (environment only, never in .claude/delivery.conf)"

# --- FORGE_URL / FORGE_REPO (§7.2 defaults) ----------------------------------
derive_origin() {
  local url scheme rest hostpart host path
  url=$(git remote get-url origin 2>/dev/null) \
    || die "FORGE_URL/FORGE_REPO are unset and there is no 'origin' remote to derive them from"
  case "$url" in
    http://*|https://*)
      scheme="${url%%://*}"; rest="${url#*://}"
      hostpart="${rest%%/*}"; hostpart="${hostpart##*@}"
      host="$scheme://$hostpart"; path="${rest#*/}" ;;
    ssh://*)
      rest="${url#ssh://}"; hostpart="${rest%%/*}"; hostpart="${hostpart##*@}"
      host="https://${hostpart%%:*}"; path="${rest#*/}" ;;
    *:*)
      rest="${url#*@}"; host="https://${rest%%:*}"; path="${rest#*:}" ;;
    *) die "cannot derive FORGE_URL from origin '$url'; set FORGE_URL and FORGE_REPO" ;;
  esac
  path="${path%/}"; path="${path%.git}"; path="${path#/}"
  [ -n "$FORGE_URL" ] || FORGE_URL="$host"
  [ -n "$FORGE_REPO" ] || FORGE_REPO="$path"
}
if [ -z "$FORGE_URL" ] || [ -z "$FORGE_REPO" ]; then derive_origin; fi
jq -en --arg r "$FORGE_REPO" '$r | test("^[^/]+(/[^/]+)+$")' >/dev/null \
  || die "FORGE_REPO must be group[/subgroup…]/project (got '$FORGE_REPO')"
API="${FORGE_URL%/}/api/v4"
_rest="${API#*://}"
API_PATH="/${_rest#*/}"   # the URL path of API, as dry-run output prints it
P="/projects/$(uri "$FORGE_REPO")"
WEB="${FORGE_URL%/}/$FORGE_REPO"

# --- HTTP ---------------------------------------------------------------------
# api METHOD PATH [JSON]: one request. Sets $code; the body is in $tmp/resp and
# the headers in $tmp/hdr. Never call it inside $(…): a dry-run write exits the
# adapter, and $code must reach the caller.
code=""
api() {
  local method="$1" path="$2" data="${3-}" try=0
  if [ "$method" != GET ] && [ "$FORGE_DRY_RUN" = 1 ]; then
    printf '%s %s\n' "$method" "$API_PATH$path"
    [ -z "$data" ] || printf '%s\n' "$data"
    exit 0
  fi
  ( umask 077; printf 'PRIVATE-TOKEN: %s\n' "$tok" > "$tmp/auth" )
  set -- -sS -X "$method" -H "@$tmp/auth" -H 'Accept: application/json' \
         -D "$tmp/hdr" -o "$tmp/resp" -w '%{http_code}' --connect-timeout 10 --max-time 120
  if [ -n "$data" ]; then
    printf '%s' "$data" > "$tmp/req.json"
    set -- "$@" -H 'Content-Type: application/json' --data-binary "@$tmp/req.json"
  fi
  while :; do
    : > "$tmp/resp"; : > "$tmp/hdr"
    code=$(curl "$@" "$API$path") || die "curl $method $API_PATH$path failed (network/TLS error)"
    [ "$code" = 429 ] && [ "$try" -lt "$POLLS" ] || break
    try=$((try + 1))
    sleep $((try * 2))
  done
}

ok2xx() { case "$code" in 2??) return 0 ;; *) return 1 ;; esac; }
err_msg() {
  jq -r '(.message // .error // empty) | if type == "string" then . else tojson end' "$tmp/resp" 2>/dev/null \
    || head -c 300 "$tmp/resp"
}
die_http() { die "$1 -> HTTP $code: $(err_msg)"; }

# has_hdr <name>: the last response sent header <name> (case-insensitive), even empty.
has_hdr() { tr -d '\r' < "$tmp/hdr" | grep -qi "^$1:"; }

# hdr <name>: the value of the last response's header <name>, or "".
hdr() {
  tr -d '\r' < "$tmp/hdr" | awk -v h="$1" 'BEGIN { h = tolower(h) ":" }
    tolower(substr($0, 1, length(h))) == h { v = substr($0, length(h) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v) }
    END { print v }'
}

# The page number of the `Link: rel="next"` target of the last response, or "".
next_link_page() {
  tr -d '\r' < "$tmp/hdr" | grep -i '^link:' | tail -n 1 | sed 's/^[Ll][Ii][Nn][Kk]:[[:space:]]*//' \
    | jq -Rr 'split(",")[] | select(test("rel=\"?next\"?")) | capture("<(?<u>[^>]*)>").u
              | capture("[?&]page=(?<p>[0-9]+)").p' 2>/dev/null | head -n 1 || true
}

limit_exit() {
  echo "forge-gitlab: $1 returned $2 items = LIST_LIMIT ($LIST_LIMIT), refusing to truncate; raise LIST_LIMIT" >&2
  exit 3
}

# paged <path[?query]> <out-file>: GET every page into one JSON array. The next
# page is, in order: `x-next-page` when the header is sent (empty = last page);
# else the `Link: rel="next"` page; else page+1 while the items so far are
# fewer than `x-total`; else page+1. An empty page always ends paging, and a
# next page that does not advance is an error, never a silent stop. A result
# reaching LIST_LIMIT exits 3 (checked before every further page, too).
paged() {
  local path="$1" out="$2" page=1 next n len total sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  echo '[]' > "$out"
  while :; do
    api GET "$path${sep}per_page=$PER_PAGE&page=$page"
    ok2xx || die_http "GET $API_PATH$path"
    jq -e 'type == "array"' "$tmp/resp" >/dev/null 2>&1 || die "GET $API_PATH$path: expected a JSON array"
    jq -s '.[0] + .[1]' "$out" "$tmp/resp" > "$out.n" && mv "$out.n" "$out"
    len=$(jq 'length' "$tmp/resp")
    [ "$len" -gt 0 ] || break
    n=$(jq 'length' "$out")
    next=""
    if has_hdr x-next-page; then
      next=$(hdr x-next-page)
    elif has_hdr link; then
      next=$(next_link_page)
    else
      total=$(hdr x-total)
      case "$total" in
        '') next=$((page + 1)) ;;
        *[!0-9]*) die "GET $API_PATH$path: bad x-total '$total'" ;;
        *) [ "$n" -ge "$total" ] || next=$((page + 1)) ;;
      esac
    fi
    [ -n "$next" ] || break
    case "$next" in *[!0-9]*) die "GET $API_PATH$path: bad next page '$next'" ;; esac
    [ "$next" -gt "$page" ] || die "GET $API_PATH$path: next page $next does not advance past $page"
    [ "$n" -lt "$LIST_LIMIT" ] || limit_exit "GET $API_PATH$path" "$n"
    page="$next"
  done
  n=$(jq 'length' "$out")
  [ "$n" -lt "$LIST_LIMIT" ] || limit_exit "GET $API_PATH$path" "$n"
}

# --- MR reads -----------------------------------------------------------------
# get_mr <iid> <out-file>: the single-MR GET (the only one with head_pipeline).
get_mr() {
  api GET "$P/merge_requests/$1"
  ok2xx || die_http "GET merge request !$1"
  cp "$tmp/resp" "$2"
}

# repoll <file>: while the MR in <file> is open with mergeability still being
# computed, re-read it up to $POLLS times with backoff (it then stays `unknown`).
repoll() {
  local f="$1" i=0 n
  n=$(jq -r .iid "$f")
  while [ "$i" -lt "$POLLS" ] \
        && [ "$(fjq -r 'include "forge-gitlab"; gl_mergeable_computing' "$f")" = true ]; do
    i=$((i + 1))
    sleep $((i * 2))
    get_mr "$n" "$f"
  done
}

# view <iid>: print the §4.2 PR for MR <iid> (single GET, re-poll, every note).
view() {
  get_mr "$1" "$tmp/mr.json"
  repoll "$tmp/mr.json"
  [ -n "$(jq -r '.sha // empty' "$tmp/mr.json")" ] || die "merge request !$1 has no sha"
  paged "$P/merge_requests/$1/notes?sort=asc&order_by=created_at" "$tmp/notes.json"
  jq -n --slurpfile mr "$tmp/mr.json" --slurpfile nt "$tmp/notes.json" '{mr: $mr[0], notes: $nt[0]}' \
    | fjq -c --arg gb "$GRAPH_BACKEND" 'include "forge-gitlab"; gl_pr($gb)'
}

# Refuse a write against a head that has moved (GC30): no request is sent.
require_head() {
  local n="$1" sha="$2" cur
  get_mr "$n" "$tmp/head.json"
  cur=$(jq -r '.sha // ""' "$tmp/head.json")
  [ "$cur" = "$sha" ] || die "merge request !$n head is $cur, not $sha; refusing (re-read and retry)"
}

# post_note <iid> <body-file>: posts an MR note and sets $posted_url.
# Exits 1 unless the forge answered 2xx: nothing was posted.
posted_url=""
post_note() {
  api POST "$P/merge_requests/$1/notes" "$(jq -cn --rawfile b "$2" '{body: $b}')"
  ok2xx || { echo "forge-gitlab: POST note on !$1 -> HTTP $code: $(err_msg)" >&2; die "note on !$1 failed; nothing posted"; }
  posted_url=$(jq -r --arg w "$WEB/-/merge_requests/$1" 'if .id then "\($w)#note_\(.id)" else "" end' "$tmp/resp")
}

# --- ops ------------------------------------------------------------------------
op_whoami() {
  api GET "/user"
  ok2xx || die_http "GET /user"
  jq -r '.username' "$tmp/resp"
}

op_pr_create() {
  local u="pr-create --head H --base B --title T --body-file F [--draft]"
  local head="" base="" title="" body="" draft=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --body-file) body="${2:-}"; shift 2 ;;
      --draft) draft=1; shift ;;
      *) usage "$u" ;;
    esac
  done
  [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] && [ -f "$body" ] || usage "$u"
  [ -z "$draft" ] || title="Draft: $title"
  api POST "$P/merge_requests" "$(jq -cn --arg h "$head" --arg b "$base" --arg t "$title" --rawfile d "$body" \
                                 '{source_branch: $h, target_branch: $b, title: $t, description: $d}')"
  ok2xx || die_http "POST merge request ($head -> $base)"
  jq -ce '{number: .iid, url: .web_url} | select((.number | type) == "number" and (.url | type) == "string")' \
    "$tmp/resp" || die "POST merge request: response has no iid/web_url"
}

op_pr_view() {
  need_n "${1:-}" "pr-view <n>"
  view "$1"
}

# A list, in order, with each iid kept once (MRs can shift between pages).
dedupe() {
  jq 'reduce .[] as $m ({seen: {}, out: []};
        ($m.iid | tostring) as $k
        | if .seen[$k] then . else .seen[$k] = true | .out += [$m] end) | .out' "$1" > "$1.n" \
    && mv "$1.n" "$1"
}

op_pr_list() {
  local u="pr-list [--state open|merged] [--since ISO]"
  local state=open since="" n
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="${2:-}"; shift 2 ;;
      --since) since="${2:-}"; shift 2 ;;
      *) usage "$u" ;;
    esac
  done
  case "$state" in open|merged) : ;; *) usage "$u" ;; esac
  if [ -n "$since" ]; then
    [ "$state" = merged ] || usage "pr-list --since requires --state merged"
    jq -en --arg t "$since" -L "$LIB" 'include "shape"; $t | is_iso8601' >/dev/null \
      || usage "pr-list --since wants an ISO-8601 timestamp (got '$since')"
    paged "$P/merge_requests?state=merged&updated_after=$(uri "$since")&order_by=created_at&sort=asc" "$tmp/list.json"
    dedupe "$tmp/list.json"
    fjq --arg t "$since" 'include "forge-gitlab"; gl_merged_since($t)' "$tmp/list.json" > "$tmp/sel.json"
  else
    if [ "$state" = merged ]; then
      paged "$P/merge_requests?state=merged&order_by=created_at&sort=asc" "$tmp/list.json"
    else
      paged "$P/merge_requests?state=opened&order_by=created_at&sort=asc" "$tmp/list.json"
    fi
    dedupe "$tmp/list.json"
    cp "$tmp/list.json" "$tmp/sel.json"
  fi
  : > "$tmp/prs.jsonl"
  # head_pipeline is only on the single-MR GET: hydrate every listed MR.
  for n in $(jq -r '.[].iid' "$tmp/sel.json"); do
    view "$n" >> "$tmp/prs.jsonl"
  done
  # An MR may change state between the list and its hydration: keep the asked-for state.
  jq -sc --arg s "$state" 'map(select(.state == $s))' "$tmp/prs.jsonl"
}

op_pr_find() {
  [ "${1:-}" = --head ] && [ -n "${2:-}" ] || usage "pr-find --head H"
  local n
  paged "$P/merge_requests?state=opened&source_branch=$(uri "$2")&order_by=created_at&sort=asc" "$tmp/find.json"
  n=$(jq -r --arg h "$2" 'first(.[] | select(.source_branch == $h) | .iid) // empty' "$tmp/find.json")
  [ -z "$n" ] || view "$n"
}

op_pr_review() {
  local u="pr-review <n> approve|request-changes|comment --sha S --body-file F"
  local n="${1:-}" verdict="${2:-}" sha="" body="" form=comment last first hv heading
  need_n "$n" "$u"; shift 2 || usage "$u"
  case "$verdict" in approve|request-changes|comment) : ;; *) usage "$u" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) sha="${2:-}"; shift 2 ;;
      --body-file) body="${2:-}"; shift 2 ;;
      *) usage "$u" ;;
    esac
  done
  [ -n "$sha" ] && [ -f "$body" ] || usage "$u"
  require_head "$n" "$sha"
  # Every verdict body ends with the trailer that ties it to the head (§4.2),
  # exactly once: a body already ending in it is sent as is, and one ending in
  # another head's trailer is refused rather than sent with two.
  last=$(awk 'NF { l = $0 } END { print l }' "$body")
  case "$last" in
    "Reviewed-Head: $sha") cp "$body" "$tmp/verdict.md" ;;
    Reviewed-Head:*) die "body ends with '$last', not head $sha; refusing" ;;
    *) { cat "$body"; printf '\n\nReviewed-Head: %s\n' "$sha"; } > "$tmp/verdict.md" ;;
  esac
  # The note is the verdict whenever no formal one lands (request-changes and
  # comment always; approve when /approve is refused), so it must read as one
  # to `pr-reviews` (§7.3): a body whose first line is a verdict heading
  # (gl_heading_verdict) keeps it if it names this verdict and is refused if it
  # names another; a body with none gets the canonical heading.
  first=$(awk 'NF { sub(/\r$/, ""); print; exit }' "$tmp/verdict.md")
  hv=$(fjq -rn --arg l "$first" 'include "forge-gitlab"; $l | gl_heading_verdict // ""')
  if [ -z "$hv" ]; then
    heading="$(fjq -rn 'include "forge-gitlab"; gl_verdict_heading')$(printf '%s' "$verdict" | tr 'a-z-' 'A-Z_')"
    { printf '%s\n\n' "$heading"; cat "$tmp/verdict.md"; } > "$tmp/verdict.n" && mv "$tmp/verdict.n" "$tmp/verdict.md"
  elif [ "$hv" != "$verdict" ]; then
    die "body opens '$first', a $hv verdict, not $verdict; refusing"
  fi
  [ -z "${GITLAB_REVIEW_TOKEN:-}" ] || tok="$GITLAB_REVIEW_TOKEN"
  if [ "$verdict" = approve ]; then
    api POST "$P/merge_requests/$n/approve" "$(jq -cn --arg s "$sha" '{sha: $s}')"
    if ok2xx; then
      form=formal
    elif [ "$code" = 401 ] || [ "$code" = 403 ]; then
      # This user may not approve (an author's own MR, by default, GC29): the
      # note alone is the verdict; the graph status is the verdict of record.
      echo "forge-gitlab: approval of !$n refused (HTTP $code: $(err_msg)); posting the verdict as a note" >&2
    elif [ "$code" = 409 ]; then
      die_http "POST approve on !$n (head moved past $sha)"
    else
      die_http "POST approve on !$n"
    fi
  fi
  # The approval takes no body: the verdict text (and its trailer) is the note.
  api POST "$P/merge_requests/$n/notes" "$(jq -cn --rawfile b "$tmp/verdict.md" '{body: $b}')"
  if ! ok2xx; then
    echo "forge-gitlab: POST note on !$n -> HTTP $code: $(err_msg)" >&2
    [ "$form" = formal ] && die "!$n was approved but its verdict note failed; the verdict body was not posted"
    die "note on !$n failed; nothing posted"
  fi
  posted_url=$(jq -r --arg w "$WEB/-/merge_requests/$n" 'if .id then "\($w)#note_\(.id)" else "" end' "$tmp/resp")
  jq -cn --arg form "$form" --arg url "$posted_url" '{posted: true, form: $form, url: $url}'
}

op_pr_reviews() {
  need_n "${1:-}" "pr-reviews <n>"
  api GET "$P/merge_requests/$1/approvals"
  ok2xx || die_http "GET approvals of !$1"
  cp "$tmp/resp" "$tmp/approvals.json"
  paged "$P/merge_requests/$1/notes?sort=asc&order_by=created_at" "$tmp/notes.json"
  fjq -c --slurpfile a "$tmp/approvals.json" 'include "forge-gitlab"; gl_reviews($a[0])' "$tmp/notes.json"
}

op_pr_comment() {
  need_n "${1:-}" "pr-comment <n> --body-file F"
  [ "${2:-}" = --body-file ] && [ -f "${3:-}" ] || usage "pr-comment <n> --body-file F"
  post_note "$1" "$3"
  jq -cn --arg url "$posted_url" '{posted: true, url: $url}'
}

op_pr_comments() {
  need_n "${1:-}" "pr-comments <n>"
  paged "$P/merge_requests/$1/notes?sort=asc&order_by=created_at" "$tmp/notes.json"
  fjq -c --arg w "$WEB/-/merge_requests/$1" 'include "forge-gitlab"; gl_comments($w)' "$tmp/notes.json"
}

op_pr_merge() {
  local u="pr-merge <n> --method squash|merge --sha S"
  local n="${1:-}" method="" sha="" i=0
  need_n "$n" "$u"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --method) method="${2:-}"; shift 2 ;;
      --sha) sha="${2:-}"; shift 2 ;;
      *) usage "$u" ;;
    esac
  done
  case "$method" in squash|merge) : ;; *) usage "$u" ;; esac
  [ -n "$sha" ] || usage "$u"
  require_head "$n" "$sha"
  api PUT "$P/merge_requests/$n/merge" "$(jq -cn --arg m "$method" --arg s "$sha" \
           '{squash: ($m == "squash"), should_remove_source_branch: ($m == "squash"), sha: $s}')"
  ok2xx || die_http "PUT merge of !$n (squash=$([ "$method" = squash ] && echo true || echo false), head $sha)"
  # Only a re-read that shows merged counts.
  get_mr "$n" "$tmp/after.json"
  while [ "$i" -lt "$POLLS" ] && [ "$(jq -r .state "$tmp/after.json")" = opened ]; do
    i=$((i + 1))
    sleep $((i * 2))
    get_mr "$n" "$tmp/after.json"
  done
  [ "$(jq -r .state "$tmp/after.json")" = merged ] \
    || die "merge request !$n is $(jq -r .state "$tmp/after.json") and not merged after the merge request"
  jq -cn --argjson n "$n" '{number: $n, state: "merged"}'
}

op_pr_set_base() {
  need_n "${1:-}" "pr-set-base <n> <branch>"
  [ -n "${2:-}" ] || usage "pr-set-base <n> <branch>"
  api PUT "$P/merge_requests/$1" "$(jq -cn --arg b "$2" '{target_branch: $b}')"
  ok2xx || die_http "PUT target_branch of !$1"
}

op_pr_files() {
  need_n "${1:-}" "pr-files <n>"
  paged "$P/merge_requests/$1/diffs" "$tmp/diffs.json"
  jq -r '.[].new_path' "$tmp/diffs.json"
}

op_pr_diff() {
  need_n "${1:-}" "pr-diff <n>"
  paged "$P/merge_requests/$1/diffs" "$tmp/diffs.json"
  jq -r '.[] | select((.diff // "") == "" and (.too_large == true or .collapsed == true))
         | "forge-gitlab: note: diff of \(.new_path) omitted by GitLab (too large / collapsed)"' \
    "$tmp/diffs.json" >&2
  fjq -j 'include "forge-gitlab"; gl_unified_diff' "$tmp/diffs.json"
}

# Best effort: the trace of every failed job of the head pipeline.
op_ci_failures() {
  need_n "${1:-}" "ci-failures <n>"
  local pid id
  get_mr "$1" "$tmp/mr.json"
  pid=$(jq -r '.head_pipeline.id // empty' "$tmp/mr.json")
  if [ -z "$pid" ]; then
    echo "forge-gitlab: merge request !$1 has no head pipeline" >&2
    return 0
  fi
  paged "$P/pipelines/$pid/jobs?scope%5B%5D=failed" "$tmp/jobs.json"
  for id in $(jq -r '.[].id' "$tmp/jobs.json"); do
    printf '=== job %s (%s) ===\n' "$id" "$(jq -r --argjson i "$id" '.[] | select(.id == $i) | .name' "$tmp/jobs.json")"
    api GET "$P/jobs/$id/trace"
    if ok2xx; then cat "$tmp/resp"; echo; else echo "forge-gitlab: no log for job $id (HTTP $code)" >&2; fi
  done
}

op="${1:-}"
[ $# -gt 0 ] && shift
case "$op" in
  whoami)      op_whoami "$@" ;;
  pr-create)   op_pr_create "$@" ;;
  pr-view)     op_pr_view "$@" ;;
  pr-list)     op_pr_list "$@" ;;
  pr-find)     op_pr_find "$@" ;;
  pr-review)   op_pr_review "$@" ;;
  pr-reviews)  op_pr_reviews "$@" ;;
  pr-comment)  op_pr_comment "$@" ;;
  pr-comments) op_pr_comments "$@" ;;
  pr-merge)    op_pr_merge "$@" ;;
  pr-set-base) op_pr_set_base "$@" ;;
  pr-files)    op_pr_files "$@" ;;
  pr-diff)     op_pr_diff "$@" ;;
  ci-failures) op_ci_failures "$@" ;;
  *) usage "forge-gitlab.sh <op> [args] (see docs/delivery_graph_spec.md §7.1)" ;;
esac
