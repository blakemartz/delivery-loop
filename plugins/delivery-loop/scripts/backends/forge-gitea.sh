#!/usr/bin/env bash
# forge-gitea.sh <op> [args] — the gitea / forgejo forge adapter (curl + jq),
# behind forge.sh.
#
# Implements every op of docs/delivery_graph_spec.md §7.1 against
# ${FORGE_URL}/api/v1/repos/<owner>/<repo>/… with `Authorization: token
# $GITEA_TOKEN`, normalizing through backends/forge-gitea.jq (§7.3 gitea/forgejo
# column). It translates; it does not decide (§3 rule 2). Invoke it through
# forge.sh, which resolves the config and runs `--check` first (GITEA_TOKEN set,
# GRAPH_BACKEND=local); this file only reads the exported keys.
#
# Exit codes: 0 ok · 1 operation failed / refused · 2 usage · 3 a list reached
# LIST_LIMIT (never a silent truncation) · 4 unsupported.
#
# FORGE_DRY_RUN=1: every write (POST/PATCH/DELETE) prints `METHOD PATH` and its
# JSON body on stdout instead of being sent, and the op stops there (exit 0).
# Reads are still sent: a dry run never mutates, but it does run the pre-reads
# (a stale --sha is still refused before anything is printed, GC30).
#
# Adapter notes (gitea / forgejo divergences from the GitHub-shaped API):
#   - FORGE_URL / FORGE_REPO default from `git remote get-url origin` (https,
#     scp-style ssh and ssh:// forms). An https remote keeps a sub-path install
#     (https://host/gitea/o/r → FORGE_URL https://host/gitea); an ssh remote
#     maps to https://<host>, since the ssh port is not the web port.
#   - the token is passed to curl in a header file (`-H @file`, mode 600 under
#     a private temp dir), never on the command line.
#   - lists page with `limit=<max_response_items>` (GET /settings/api, else 50)
#     and `page=n`. Not every paginated route sends `Link` (src): GET
#     /pulls/{n}/reviews (both forges) and Forgejo's GET /commits/{sha}/status
#     send only `X-Total-Count`. So `paged` follows `Link: rel="next"` when it
#     is there; else it keeps paging while fewer items than `X-Total-Count`
#     have arrived; with neither header, while each page came back full. An
#     empty page always ends it. Only the page number is taken from a link:
#     the request stays on FORGE_URL, so the token never follows a link to
#     another host. Reaching LIST_LIMIT exits 3 whichever way paging goes.
#   - `mergeable` is a plain bool on Gitea: false covers conflicted, still
#     checking, errored and WIP PRs (src: PullRequest.Mergeable). It maps to
#     `conflicting` per §7.3, so a still-checking PR may be offered a rebase,
#     never a merge. absent/null (older servers) is re-polled 3 times with
#     backoff, then stays `unknown`. Only `true` is `clean`.
#   - `checks` is rolled up in the adapter over every `statuses[].status` of
#     GET /commits/{sha}/status, paged in full like any list (LIST_LIMIT exit 3
#     included); `warning` and `skipped` count as success. That endpoint is
#     paginated (src) and its `state`/`total_count` cover only the returned page,
#     so neither is trusted: Gitea Actions posts one status per job, and a failing
#     job past page 1 must still read as failure.
#   - `pr-list` hydrates each listed PR (combined status, issue comments,
#     reviews); it re-reads a PR only while its mergeability is unknown.
#   - `pr-list --state merged` pages `state=closed&sort=recentupdate` and keeps
#     `merged == true`. The swagger has no `since`, so with `--since T` paging
#     stops at the first page holding a PR updated before T (merging updates
#     the PR, so nothing older can have merged at or after T).
#   - `pr-find --head H` pages the open list and matches `head.ref`, because
#     `GET /pulls/{base}/{head}` needs the base, which pr-find does not take.
#     The open list is paged `sort=oldest` (creation order), so PRs updated
#     while paging cannot shift between pages and be missed.
#   - `pr-create --draft` prefixes the title `WIP: ` (Gitea's default WIP
#     prefix; the API has no draft field).
#   - `pr-create --label L` (repeatable) sends `labels` (label ids) in the
#     create POST (CreatePullRequestOption.labels []int64), so the PR is
#     labelled atomically. The create silently drops an id it cannot find
#     (src: GetLabelsInRepoByIDs, no count check), so names are resolved first,
#     by exact name, over GET /repos/{o}/{r}/labels and, only for names still
#     unmatched, GET /orgs/{owner}/labels (a 404 there = a user owner, no org
#     labels); a repo label wins a name clash. An unknown name exits 1
#     before anything is sent, and nothing is ever created. Each --label is
#     exactly one label: a name holding a newline or CR is refused before any
#     request, and a repeated name is sent once.
#   - verdicts and merges pin the head SHA: a pre-read refuses a stale --sha
#     before any write, the review carries `commit_id` and the merge
#     `head_commit_id` (409 when the head moved).
#   - self-review: approve/request-changes on one's own PR is a 422 "… your own
#     pull is not allowed" (src); the verdict is then posted as an issue comment
#     with the same body (form "comment"). GITEA_REVIEW_TOKEN (environment only)
#     posts the review, and any fallback, as that identity. The fallback
#     comment opens with a verdict heading, so `pr-reviews` finds it: a body
#     without one is prefixed `## Adversarial review — verdict: <VERDICT>`; a
#     body whose first non-blank line is already a heading `## … verdict:
#     <VERDICT>` naming this verdict is sent as is (forge-verdict.jq).
#   - `pr-reviews` returns every PullReview (GET /pulls/{n}/reviews, all pages),
#     then every issue comment whose first non-blank line is a verdict heading
#     (`^## .*verdict: (APPROVE|REQUEST_CHANGES|COMMENT)`, any case), with
#     `commit` from its `Reviewed-Head:` trailer (backends/forge-verdict.jq).
#   - a post (`pr-comment`, the comment-form `pr-review`) reports `posted:true`
#     only on a 2xx; anything else exits 1 with no JSON.
#   - the merge field is sent as `Do` (Forgejo's spelling; Gitea decodes it
#     case-insensitively). A squash also sets `delete_branch_after_merge`. A
#     405 "try again later" is retried 3 times with backoff, then exits 1; any
#     other 405 (method disallowed, not mergeable) or 409 exits 1 at once.
#     Gitea also answers a conflicted PR with that 405 (src: ErrNotMergeableState),
#     so a conflicted merge exits 1 only after the 3 backoffs.
#     `pr-merge` then re-reads the PR and exits 0 only if `merged == true`.
#   - a 429 is retried 3 times with backoff (rate limits are unverified).
#   - issue comments are not paginated (src: ListIssueComments takes no
#     ListOptions; the swagger has only since/before): one GET returns them all.
#   - `ci-failures` is unsupported (exit 4): the patcher runs GATE_CMD locally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib"

: "${LIST_LIMIT:=5000}"
: "${GRAPH_BACKEND:=local}"
: "${FORGE_URL:=}"
: "${FORGE_REPO:=}"
: "${FORGE_DRY_RUN:=}"

POLLS=3          # re-polls / retries of a transient answer (§7.3, GC57)
DEFAULT_PAGE=50  # Gitea's default MAX_RESPONSE_ITEMS

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-forge-gitea.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

die()   { echo "forge-gitea: $*" >&2; exit 1; }
usage() { echo "forge-gitea: usage: $*" >&2; exit 2; }
fjq()   { jq -L "$LIB" -L "$SCRIPT_DIR" "$@"; }
need_n() { case "${1:-}" in ''|*[!0-9]*) usage "$2" ;; esac; }

tok="${GITEA_TOKEN:-}"
[ -n "$tok" ] || die "GITEA_TOKEN is not set (environment only, never in .claude/delivery.conf)"

# --- FORGE_URL / FORGE_REPO (§7.2 defaults) ----------------------------------
derive_origin() {
  local url scheme rest hostpart host path prefix
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
  case "$path" in */*) : ;; *) die "cannot derive owner/repo from origin '$url'; set FORGE_REPO" ;; esac
  prefix=""
  case "$path" in */*/*) prefix="/${path%/*/*}" ;; esac
  case "$url" in http://*|https://*) : ;; *) prefix="" ;; esac
  [ -n "$FORGE_URL" ] || FORGE_URL="$host$prefix"
  [ -n "$FORGE_REPO" ] || FORGE_REPO="${path#"${path%/*/*}"/}"
}
if [ -z "$FORGE_URL" ] || [ -z "$FORGE_REPO" ]; then derive_origin; fi
case "$FORGE_REPO" in
  */*/*|/*|*/) die "FORGE_REPO must be owner/repo (got '$FORGE_REPO')" ;;
  */*) : ;;
  *) die "FORGE_REPO must be owner/repo (got '$FORGE_REPO')" ;;
esac
API="${FORGE_URL%/}/api/v1"
_rest="${API#*://}"
API_PATH="/${_rest#*/}"   # the URL path of API, as dry-run output prints it
RP="/repos/$(jq -rn --arg s "${FORGE_REPO%%/*}" '$s | @uri')/$(jq -rn --arg s "${FORGE_REPO#*/}" '$s | @uri')"

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
  ( umask 077; printf 'Authorization: token %s\n' "$tok" > "$tmp/auth" )
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
err_msg() { jq -r '.message // empty' "$tmp/resp" 2>/dev/null || head -c 300 "$tmp/resp"; }
die_http() { die "$1 -> HTTP $code: $(err_msg)"; }

# Page size: the server's max_response_items (once per run).
PAGE=""
page_size() {
  [ -z "$PAGE" ] || return 0
  api GET "/settings/api"
  if ok2xx; then PAGE=$(jq -r '.max_response_items // empty' "$tmp/resp" 2>/dev/null || true); fi
  case "$PAGE" in ''|0|*[!0-9]*) PAGE=$DEFAULT_PAGE ;; esac
}

# hdr <name>: the value of the last response's header <name> (case-insensitive), or "".
hdr() {
  tr -d '\r' < "$tmp/hdr" | awk -v h="$1" 'BEGIN { h = tolower(h) ":" }
    tolower(substr($0, 1, length(h))) == h { v = substr($0, length(h) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v) }
    END { print v }'
}

# The page number of the `Link: rel="next"` target of the last response, or "".
next_page() {
  tr -d '\r' < "$tmp/hdr" | grep -i '^link:' | tail -n 1 | sed 's/^[Ll][Ii][Nn][Kk]:[[:space:]]*//' \
    | jq -Rr 'split(",")[] | select(test("rel=\"?next\"?")) | capture("<(?<u>[^>]*)>").u
              | capture("[?&]page=(?<p>[0-9]+)").p' 2>/dev/null | head -n 1 || true
}

limit_exit() {
  echo "forge-gitea: $1 returned $2 items = LIST_LIMIT ($LIST_LIMIT), refusing to truncate; raise LIST_LIMIT" >&2
  exit 3
}

# paged <path[?query]> <out-file> [since] [items] [missing-ok]: GET every page
# into one JSON array. `items` (a jq path, default `.`) selects each page's
# array, for an endpoint that wraps it in an object. The next page is, in
# order: the `Link: rel="next"` target; else page+1 while the items so far are
# fewer than `X-Total-Count`; else, with no `Link` and no `X-Total-Count`,
# page+1 while the page was full (length == limit). An empty page ends paging.
# With `since`, stop after the first page holding a PR updated before it.
# Whichever way paging ends, a result reaching LIST_LIMIT exits 3 (checked
# before every further page, too). With `missing-ok`, a 404 on page 1 is an
# empty list instead of an error.
paged() {
  local path="$1" out="$2" since="${3:-}" items="${4:-.}" missing_ok="${5:-}" page=1 next n len total sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  page_size
  echo '[]' > "$out"
  while :; do
    api GET "$path${sep}limit=$PAGE&page=$page"
    if [ "$code" = 404 ] && [ "$page" = 1 ] && [ -n "$missing_ok" ]; then return 0; fi
    ok2xx || die_http "GET $API_PATH$path"
    jq -e "$items | type == \"array\"" "$tmp/resp" >/dev/null 2>&1 \
      || die "GET $API_PATH$path: expected a JSON array at '$items'"
    jq "$items" "$tmp/resp" > "$tmp/page.json"
    jq -s '.[0] + .[1]' "$out" "$tmp/page.json" > "$out.n" && mv "$out.n" "$out"
    if [ -n "$since" ] \
       && [ "$(fjq -r --arg t "$since" 'include "forge-gitea"; gt_older_than($t)' "$tmp/page.json")" = true ]; then
      break
    fi
    len=$(jq 'length' "$tmp/page.json")
    [ "$len" -gt 0 ] || break
    n=$(jq 'length' "$out")
    next=$(next_page)
    case "$next" in ''|*[!0-9]*) next="" ;; esac
    if [ -n "$next" ] && [ "$next" -gt "$page" ]; then
      :                                        # Link rel="next"
    else
      next=""
      total=$(hdr X-Total-Count)
      case "$total" in *[!0-9]*) total="" ;; esac
      if [ -n "$total" ]; then
        [ "$n" -ge "$total" ] || next=$((page + 1))   # X-Total-Count: more to come
      elif [ -z "$(hdr Link)" ]; then
        [ "$len" -lt "$PAGE" ] || next=$((page + 1))  # no headers: a full page
      fi
    fi
    [ -n "$next" ] || break
    [ "$n" -lt "$LIST_LIMIT" ] || limit_exit "GET $API_PATH$path" "$n"
    page="$next"
  done
  n=$(jq 'length' "$out")
  [ "$n" -lt "$LIST_LIMIT" ] || limit_exit "GET $API_PATH$path" "$n"
}

# --- PR reads -----------------------------------------------------------------
# get_pr <n> <out-file>: GET /pulls/<n>.
get_pr() {
  api GET "$RP/pulls/$1"
  ok2xx || die_http "GET pull #$1"
  cp "$tmp/resp" "$2"
}

# repoll <file>: while the PR in <file> is open with mergeability unknown,
# re-read it up to $POLLS times with backoff (it then stays `unknown`).
repoll() {
  local f="$1" i=0 n
  n=$(jq -r .number "$f")
  while [ "$i" -lt "$POLLS" ] \
        && [ "$(fjq -r 'include "forge-gitea"; gt_mergeable_computing' "$f")" = true ]; do
    i=$((i + 1))
    sleep $((i * 2))
    get_pr "$n" "$f"
  done
}

# hydrate <pr-file>: print the §4.2 PR for the PullRequest in <pr-file>.
hydrate() {
  local f="$1" n sha
  n=$(jq -r .number "$f"); sha=$(jq -r '.head.sha // empty' "$f")
  [ -n "$sha" ] || die "pull #$n has no head.sha"
  # Every status of the head, all pages: checks are rolled up over all of them.
  # A closed PR's head commit may be gone (404 -> no statuses); an open PR's
  # never is, so there a 404 fails like any other error.
  if [ "$(jq -r .state "$f")" = open ]; then
    paged "$RP/commits/$sha/status" "$tmp/h-statuses.json" "" '.statuses // []'
  else
    paged "$RP/commits/$sha/status" "$tmp/h-statuses.json" "" '.statuses // []' missing-ok
  fi
  api GET "$RP/issues/$n/comments"
  ok2xx || die_http "GET comments of pull #$n"
  cp "$tmp/resp" "$tmp/h-comments.json"
  paged "$RP/pulls/$n/reviews" "$tmp/h-reviews.json"
  jq -n --slurpfile pr "$f" --slurpfile st "$tmp/h-statuses.json" \
        --slurpfile cm "$tmp/h-comments.json" --slurpfile rv "$tmp/h-reviews.json" \
        '{pr: $pr[0], statuses: $st[0], comments: $cm[0], reviews: $rv[0]}' \
    | fjq -c --arg gb "$GRAPH_BACKEND" 'include "forge-gitea"; gt_pr($gb)'
}

# Refuse a write against a head that has moved (GC30): no request is sent.
require_head() {
  local n="$1" sha="$2" cur
  get_pr "$n" "$tmp/head.json"
  cur=$(jq -r '.head.sha // ""' "$tmp/head.json")
  [ "$cur" = "$sha" ] || die "pull #$n head is $cur, not $sha; refusing (re-read and retry)"
}

# post_comment <n> <body-file>: posts an issue comment and sets $posted_url.
# Exits 1 unless the forge answered 2xx: nothing was posted.
posted_url=""
post_comment() {
  api POST "$RP/issues/$1/comments" "$(jq -cn --rawfile b "$2" '{body: $b}')"
  ok2xx || { echo "forge-gitea: POST comment on #$1 -> HTTP $code: $(err_msg)" >&2; die "comment on #$1 failed; nothing posted"; }
  posted_url=$(jq -r '.html_url // ""' "$tmp/resp")
}

# --- ops ------------------------------------------------------------------------
op_whoami() {
  api GET "/user"
  ok2xx || die_http "GET /user"
  jq -r '.login' "$tmp/resp"
}

# check_label_names <name>…: refuse, before any request, a name holding a line
# break (each --label is exactly one label).
check_label_names() {
  local n
  for n in "$@"; do
    case "$n" in
      *$'\n'*|*$'\r'*) die "label names cannot contain a newline or CR: $(printf '%q' "$n"); nothing created" ;;
    esac
  done
}

# resolve_labels <out-file> <name>…: write the ids of the named labels (repo
# labels first, then the owner org's) as a JSON array. An unknown name exits 1
# before anything is sent; nothing is created.
resolve_labels() {
  local out="$1" org
  shift
  jq -n '$ARGS.positional | unique' --args -- "$@" > "$tmp/want.json"   # argv kept exactly
  paged "$RP/labels" "$tmp/labels.json"
  if [ -n "$(missing_labels)" ]; then
    org=$(jq -rn --arg s "${FORGE_REPO%%/*}" '$s | @uri')
    paged "/orgs/$org/labels" "$tmp/org-labels.json" "" . missing-ok
    jq -s '.[0] + .[1]' "$tmp/labels.json" "$tmp/org-labels.json" > "$tmp/labels.n" && mv "$tmp/labels.n" "$tmp/labels.json"
  fi
  [ -z "$(missing_labels)" ] \
    || die "unknown label(s) on $FORGE_REPO: $(missing_labels); nothing created (pr-create never creates labels)"
  jq -c --slurpfile have "$tmp/labels.json" \
     'map(. as $w | first($have[0][] | select(.name == $w) | .id))' "$tmp/want.json" > "$out"
}

# The wanted names ($tmp/want.json) absent from $tmp/labels.json, comma-joined.
missing_labels() {
  jq -r --slurpfile have "$tmp/labels.json" \
     '($have[0] | map(.name)) as $h | map(select(. as $w | $h | index([$w]) | not)) | join(", ")' "$tmp/want.json"
}

op_pr_create() {
  local u="pr-create --head H --base B --title T --body-file F [--draft] [--label L]…"
  local head="" base="" title="" body="" draft="" ids="[]"
  local names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --body-file) body="${2:-}"; shift 2 ;;
      --draft) draft=1; shift ;;
      --label) [ -n "${2:-}" ] || usage "$u"; names+=("$2"); shift 2 ;;
      *) usage "$u" ;;
    esac
  done
  [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] && [ -f "$body" ] || usage "$u"
  [ -z "$draft" ] || title="WIP: $title"
  if [ "${#names[@]}" -gt 0 ]; then
    check_label_names "${names[@]}"
    resolve_labels "$tmp/label-ids.json" "${names[@]}"
    ids=$(cat "$tmp/label-ids.json")
  fi
  api POST "$RP/pulls" "$(jq -cn --arg h "$head" --arg b "$base" --arg t "$title" --rawfile body "$body" \
                          --argjson l "$ids" \
                          '{head: $h, base: $b, title: $t, body: $body}
                           + (if $l == [] then {} else {labels: $l} end)')"
  ok2xx || die_http "POST pull ($head -> $base)"
  jq -ce '{number: .number, url: .html_url} | select((.number | type) == "number" and (.url | type) == "string")' \
    "$tmp/resp" || die "POST pull: response has no number/html_url"
}

op_pr_view() {
  need_n "${1:-}" "pr-view <n>"
  get_pr "$1" "$tmp/pr.json"
  repoll "$tmp/pr.json"
  hydrate "$tmp/pr.json"
}

op_pr_list() {
  local u="pr-list [--state open|merged] [--since ISO]"
  local state=open since="" count i
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
    paged "$RP/pulls?state=closed&sort=recentupdate" "$tmp/list.json" "$since"
    fjq --arg t "$since" 'include "forge-gitea"; gt_merged_since($t)' "$tmp/list.json" > "$tmp/sel.json"
  elif [ "$state" = merged ]; then
    paged "$RP/pulls?state=closed&sort=recentupdate" "$tmp/list.json"
    fjq 'include "forge-gitea"; gt_merged' "$tmp/list.json" > "$tmp/sel.json"
  else
    paged "$RP/pulls?state=open&sort=oldest" "$tmp/list.json"
    cp "$tmp/list.json" "$tmp/sel.json"
  fi
  : > "$tmp/prs.jsonl"
  count=$(jq 'length' "$tmp/sel.json"); i=0
  while [ "$i" -lt "$count" ]; do
    jq --argjson i "$i" '.[$i]' "$tmp/sel.json" > "$tmp/item.json"
    repoll "$tmp/item.json"
    hydrate "$tmp/item.json" >> "$tmp/prs.jsonl"
    i=$((i + 1))
  done
  # A PR may change state between the list and its hydration: keep the asked-for state.
  jq -sc --arg s "$state" 'map(select(.state == $s))' "$tmp/prs.jsonl"
}

op_pr_find() {
  [ "${1:-}" = --head ] && [ -n "${2:-}" ] || usage "pr-find --head H"
  paged "$RP/pulls?state=open&sort=oldest" "$tmp/find.json"
  jq --arg h "$2" 'first(.[] | select(.head.ref == $h)) // empty' "$tmp/find.json" > "$tmp/found.json"
  [ -s "$tmp/found.json" ] || return 0
  repoll "$tmp/found.json"
  hydrate "$tmp/found.json"
}

op_pr_review() {
  local u="pr-review <n> approve|request-changes|comment --sha S --body-file F"
  local n="${1:-}" verdict="${2:-}" sha="" body="" event form url last
  need_n "$n" "$u"; shift 2 || usage "$u"
  case "$verdict" in
    approve) event=APPROVED ;; request-changes) event=REQUEST_CHANGES ;;
    comment) event=COMMENT ;; *) usage "$u" ;;
  esac
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
  # A comment-form verdict must read as one to `pr-reviews` (§7.3): the fallback
  # comment is the same body, opening with a heading that names this verdict
  # (forge-verdict.jq ensure_verdict_heading: the body's own when it does, else
  # the canonical one prefixed).
  fjq -jRs --arg v "$verdict" 'include "forge-verdict"; ensure_verdict_heading($v)' "$tmp/verdict.md" \
    > "$tmp/verdict-comment.md"
  [ -z "${GITEA_REVIEW_TOKEN:-}" ] || tok="$GITEA_REVIEW_TOKEN"
  api POST "$RP/pulls/$n/reviews" \
    "$(jq -cn --arg e "$event" --arg c "$sha" --rawfile b "$tmp/verdict.md" '{event: $e, body: $b, commit_id: $c}')"
  if ok2xx; then
    form=formal
    url=$(jq -r '.html_url // ""' "$tmp/resp")
  elif [ "$code" = 422 ] && err_msg | grep -qi 'your own pull'; then
    # Gitea rejects approve/reject on one's own PR (GC29): post the same body
    # as a comment; the graph status is the verdict of record.
    form=comment
    post_comment "$n" "$tmp/verdict-comment.md"
    url="$posted_url"
  else
    die_http "POST review on #$n"
  fi
  jq -cn --arg form "$form" --arg url "$url" '{posted: true, form: $form, url: $url}'
}

op_pr_reviews() {
  need_n "${1:-}" "pr-reviews <n>"
  paged "$RP/pulls/$1/reviews" "$tmp/reviews.json"
  api GET "$RP/issues/$1/comments"
  ok2xx || die_http "GET comments of #$1"
  cp "$tmp/resp" "$tmp/comments.json"
  fjq -c --slurpfile c "$tmp/comments.json" 'include "forge-gitea"; gt_reviews($c[0])' "$tmp/reviews.json"
}

op_pr_comment() {
  need_n "${1:-}" "pr-comment <n> --body-file F"
  [ "${2:-}" = --body-file ] && [ -f "${3:-}" ] || usage "pr-comment <n> --body-file F"
  post_comment "$1" "$3"
  jq -cn --arg url "$posted_url" '{posted: true, url: $url}'
}

op_pr_comments() {
  need_n "${1:-}" "pr-comments <n>"
  api GET "$RP/issues/$1/comments"
  ok2xx || die_http "GET comments of #$1"
  fjq -c 'include "forge-gitea"; gt_comments' "$tmp/resp"
}

op_pr_merge() {
  local u="pr-merge <n> --method squash|merge --sha S"
  local n="${1:-}" method="" sha="" data i=0
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
  data=$(jq -cn --arg m "$method" --arg s "$sha" \
           '{Do: $m, delete_branch_after_merge: ($m == "squash"), head_commit_id: $s}')
  while :; do
    api POST "$RP/pulls/$n/merge" "$data"
    ok2xx && break
    if [ "$code" = 405 ] && err_msg | grep -qi 'try again later' && [ "$i" -lt "$POLLS" ]; then
      i=$((i + 1))
      sleep $((i * 2))
      require_head "$n" "$sha"
      continue
    fi
    die_http "POST merge of #$n (Do=$method, head $sha)"
  done
  # Only a re-read that shows merged counts.
  get_pr "$n" "$tmp/after.json"
  [ "$(jq -r '.merged == true' "$tmp/after.json")" = true ] \
    || die "pull #$n is $(jq -r .state "$tmp/after.json") and not merged after the merge request"
  jq -cn --argjson n "$n" '{number: $n, state: "merged"}'
}

op_pr_set_base() {
  need_n "${1:-}" "pr-set-base <n> <branch>"
  [ -n "${2:-}" ] || usage "pr-set-base <n> <branch>"
  api PATCH "$RP/pulls/$1" "$(jq -cn --arg b "$2" '{base: $b}')"
  ok2xx || die_http "PATCH base of #$1"
}

op_pr_files() {
  need_n "${1:-}" "pr-files <n>"
  paged "$RP/pulls/$1/files" "$tmp/files.json"
  jq -r '.[].filename' "$tmp/files.json"
}

op_pr_diff() {
  need_n "${1:-}" "pr-diff <n>"
  api GET "$RP/pulls/$1.diff"
  ok2xx || die_http "GET diff of #$1"
  cat "$tmp/resp"
}

op_ci_failures() {
  need_n "${1:-}" "ci-failures <n>"
  echo "forge-gitea: ci-failures is unsupported on gitea/forgejo; reproduce with GATE_CMD locally" >&2
  exit 4
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
  *) usage "forge-gitea.sh <op> [args] (see docs/delivery_graph_spec.md §7.1)" ;;
esac
