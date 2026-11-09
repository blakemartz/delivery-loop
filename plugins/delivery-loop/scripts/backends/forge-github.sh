#!/usr/bin/env bash
# forge-github.sh <op> [args] — the github forge adapter (`gh`), behind forge.sh.
#
# Implements every op of docs/delivery_graph_spec.md §7.1 by translating to `gh`
# and normalizing through backends/forge-github.jq (§7.3 github column). It
# translates; it does not decide (§3 rule 2). Invoke it through forge.sh, which
# resolves the config and runs `--check` first; this file only reads the
# exported keys (LIST_LIMIT, GRAPH_BACKEND, FORGE_URL, FORGE_REPO, …).
#
# Exit codes: 0 ok · 1 operation failed / refused · 2 usage · 3 a list reached
# LIST_LIMIT (never a silent truncation) · 4 unsupported.
#
# Adapter notes (github):
#   - every list passes an explicit `--limit $LIST_LIMIT`; gh pages internally.
#   - `pr-list --state merged --since T` goes through GitHub search, which never
#     returns more than 1000 results whatever `--limit` says. Its ceiling is
#     therefore min(LIST_LIMIT, 1000): reaching it exits 3 (§11), since a capped
#     search is indistinguishable from a complete one.
#   - a post (`pr-comment`, the comment-form `pr-review`) reports `posted:true`
#     only when gh succeeded; a failed post exits 1 with no JSON. gh's exit
#     status is authoritative: a successful post that printed no URL keeps
#     `url: ""`.
#   - `pr-list` hydrates each listed PR through the `pr-view` path, because the
#     list's `comments`/`reviews` are what `patch_iteration`/`reviewed_at_head`
#     come from and mergeability may still be computing.
#   - verdicts and merges pin the head SHA: a pre-read refuses a stale --sha
#     before any write, and `pr-merge` also sends `--match-head-commit`.
#   - `pr-merge` re-reads the PR; gh may silently enable auto-merge instead of
#     merging, which the adapter disables again (`--disable-auto`) and exits 1.
#   - the source branch of a squash merge is deleted through the API rather than
#     `gh pr merge --delete-branch`, which also touches local branches/worktrees.
#   - the comment-form verdict opens with a verdict heading, so `pr-reviews`
#     finds it: a body without one is prefixed `## Adversarial review —
#     verdict: <VERDICT>` unless its first non-blank line is already a heading
#     `## … verdict: <VERDICT>` naming this verdict (forge-verdict.jq).
#   - `pr-reviews` returns every formal review (`reviews`), then every comment
#     whose first non-blank line is a verdict heading
#     (`^## .*verdict: (APPROVE|REQUEST_CHANGES|COMMENT)`, any case), with
#     `commit` from its `Reviewed-Head:` trailer (backends/forge-verdict.jq).
#   - GH_REVIEW_TOKEN (environment only) posts `pr-review` as that identity.
#   - `pr-create --label L` (repeatable) passes `gh pr create --label L`. gh
#     resolves every name to a label id before creating, so an unknown label
#     fails with nothing created; it then applies the labels in a second request
#     once the PR exists (createPullRequest takes no labels). When that second
#     request fails, gh prints the new PR's URL and exits non-zero: the adapter
#     exits 1 naming that URL rather than reporting either success or "no PR".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib"

: "${LIST_LIMIT:=5000}"
: "${GRAPH_BACKEND:=github}"
: "${FORGE_URL:=}"
: "${FORGE_REPO:=}"

# FORGE_URL / FORGE_REPO override what gh derives from `origin` (§7.2 defaults).
if [ -n "$FORGE_URL" ]; then
  _host="${FORGE_URL#*://}"; _host="${_host%%/*}"
  [ -n "$_host" ] && export GH_HOST="$_host"
fi
if [ -n "$FORGE_REPO" ]; then
  export GH_REPO="${GH_HOST:+$GH_HOST/}$FORGE_REPO"
fi

# The `gh pr view --json` field set of §7.2.
PR_FIELDS="number,url,state,headRefName,baseRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup,body,labels,comments,reviews,author,closingIssuesReferences"
POLLS=3   # re-polls of a still-computing mergeability (§7.3, GC57)
SEARCH_CAP=1000   # GitHub search's hard result cap (`gh pr list --search`)

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-forge-github.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

die()   { echo "forge-github: $*" >&2; exit 1; }
usage() { echo "forge-github: usage: $*" >&2; exit 2; }
fjq()   { jq -L "$LIB" -L "$SCRIPT_DIR" "$@"; }
need_n() { case "${1:-}" in ''|*[!0-9]*) usage "$2" ;; esac; }

# Raw `gh pr view` JSON for PR $1, re-polled with backoff while GitHub is still
# computing mergeability; a PR still computing after $POLLS re-polls stays
# `unknown` (never eligible to merge).
raw_view() {
  local n="$1" raw i=0
  raw=$(gh pr view "$n" --json "$PR_FIELDS")
  while [ "$i" -lt "$POLLS" ] \
        && [ "$(fjq -r 'include "forge-github"; gh_mergeable_computing' <<<"$raw")" = true ]; do
    i=$((i + 1))
    sleep $((i * 2))
    raw=$(gh pr view "$n" --json "$PR_FIELDS")
  done
  printf '%s\n' "$raw"
}

normalize() { fjq -c --arg gb "$GRAPH_BACKEND" 'include "forge-github"; gh_pr($gb)'; }

# Refuse a write against a head that has moved (GC30): no request is sent.
# Prints the PR's head branch name on success.
require_head() {
  local n="$1" sha="$2" cur
  cur=$(gh pr view "$n" --json headRefOid,headRefName)
  [ "$(jq -r '.headRefOid' <<<"$cur")" = "$sha" ] \
    || die "PR #$n head is $(jq -r '.headRefOid' <<<"$cur"), not $sha; refusing (re-read and retry)"
  jq -r '.headRefName' <<<"$cur"
}

# check_limit <file> <what> [ceiling]: fail (exit 3) when a list came back at
# the ceiling (default LIST_LIMIT): it may be truncated.
check_limit() {
  local got cap="${3:-$LIST_LIMIT}" why
  got=$(jq 'length' "$1")
  [ "$got" -lt "$cap" ] && return 0
  if [ "$cap" -lt "$LIST_LIMIT" ]; then
    why="GitHub search's $SEARCH_CAP-result cap (< LIST_LIMIT $LIST_LIMIT); narrow the window"
  else
    why="LIST_LIMIT ($LIST_LIMIT); raise LIST_LIMIT"
  fi
  echo "forge-github: $2 returned $got items = $why, refusing to truncate" >&2
  exit 3
}

# post_comment <n> <body-file> [gh-runner]: posts a PR comment and prints its
# URL ("" if gh printed none). Exits 1 if gh failed: nothing was posted.
post_comment() {
  local runner="${3:-gh}"
  "$runner" pr comment "$1" --body-file "$2" > "$tmp/comment.out" 2> "$tmp/comment.err" || {
    cat "$tmp/comment.err" >&2
    die "gh pr comment #$1 failed; nothing posted"
  }
  grep -E '^https?://' "$tmp/comment.out" | tail -n 1 || true
}

op_whoami() { gh api user | jq -r .login; }

op_pr_create() {
  local u="pr-create --head H --base B --title T --body-file F [--draft] [--label L]…"
  local head="" base="" title="" body="" draft="" out rc url
  local labels=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --body-file) body="${2:-}"; shift 2 ;;
      --draft) draft=1; shift ;;
      --label) [ -n "${2:-}" ] || usage "$u"; labels+=(--label "$2"); shift 2 ;;
      *) usage "$u" ;;
    esac
  done
  [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] && [ -f "$body" ] || usage "$u"
  set -- --head "$head" --base "$base" --title "$title" --body-file "$body"
  [ -z "$draft" ] || set -- "$@" --draft
  # ${labels[@]+…}: an empty array under `set -u` on bash 3.2.
  out=$(gh pr create "$@" ${labels[@]+"${labels[@]}"}) && rc=0 || rc=$?
  url=$(printf '%s\n' "$out" | grep -E '^https?://' | tail -n 1) || url=""
  if [ "$rc" != 0 ]; then
    # gh resolves label names before creating (an unknown one: nothing is
    # created), but applies them in a second request after the PR exists; if
    # that fails it still prints the new PR's URL, then exits non-zero.
    [ -z "$url" ] || die "gh pr create opened $url but failed to apply its labels (gh exit $rc); nothing retried (add them with gh pr edit --add-label, or pr-find --head $head)"
    die "gh pr create failed (exit $rc); no PR created"
  fi
  [ -n "$url" ] || die "gh pr create printed no PR URL"
  jq -cn --arg url "$url" '{number: ($url | capture("/pull/(?<n>[0-9]+)").n | tonumber), url: $url}'
}

op_pr_view() {
  need_n "${1:-}" "pr-view <n>"
  raw_view "$1" | normalize
}

op_pr_list() {
  local state=open since="" n
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="${2:-}"; shift 2 ;;
      --since) since="${2:-}"; shift 2 ;;
      *) usage "pr-list [--state open|merged] [--since ISO]" ;;
    esac
  done
  case "$state" in open|merged) : ;; *) usage "pr-list [--state open|merged] [--since ISO]" ;; esac
  if [ -n "$since" ]; then
    [ "$state" = merged ] || usage "pr-list --since requires --state merged"
    jq -en --arg t "$since" -L "$LIB" 'include "shape"; $t | is_iso8601' >/dev/null \
      || usage "pr-list --since wants an ISO-8601 timestamp (got '$since')"
    # gh has no --since: search narrows server-side, the jq filter is exact.
    gh pr list --state merged --search "merged:>=$since" --limit "$LIST_LIMIT" \
      --json number,mergedAt > "$tmp/list.json"
    local cap="$LIST_LIMIT"
    [ "$cap" -le "$SEARCH_CAP" ] || cap="$SEARCH_CAP"
    check_limit "$tmp/list.json" "pr-list --state merged --since" "$cap"
    fjq --arg t "$since" 'include "forge-github"; gh_merged_since($t)' "$tmp/list.json" > "$tmp/sel.json"
  else
    gh pr list --state "$state" --limit "$LIST_LIMIT" --json number,mergedAt > "$tmp/list.json"
    check_limit "$tmp/list.json" "pr-list"
    cp "$tmp/list.json" "$tmp/sel.json"
  fi
  : > "$tmp/prs.jsonl"
  for n in $(jq -r '.[].number' "$tmp/sel.json"); do
    raw_view "$n" | normalize >> "$tmp/prs.jsonl"
  done
  # A PR may change state between the list and its hydration: keep the asked-for state.
  jq -sc --arg s "$state" 'map(select(.state == $s))' "$tmp/prs.jsonl"
}

op_pr_find() {
  [ "${1:-}" = --head ] && [ -n "${2:-}" ] || usage "pr-find --head H"
  local n
  gh pr list --state open --head "$2" --limit "$LIST_LIMIT" --json number > "$tmp/find.json"
  n=$(jq -r 'first(.[].number) // empty' "$tmp/find.json")
  [ -z "$n" ] || raw_view "$n" | normalize
}

op_pr_review() {
  local u="pr-review <n> approve|request-changes|comment --sha S --body-file F"
  local n="${1:-}" verdict="${2:-}" sha="" body="" flag form out
  need_n "$n" "$u"; shift 2 || usage "$u"
  case "$verdict" in
    approve) flag=--approve ;; request-changes) flag=--request-changes ;;
    comment) flag=--comment ;; *) usage "$u" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) sha="${2:-}"; shift 2 ;;
      --body-file) body="${2:-}"; shift 2 ;;
      *) usage "$u" ;;
    esac
  done
  [ -n "$sha" ] && [ -f "$body" ] || usage "$u"
  require_head "$n" "$sha" >/dev/null
  # Every verdict body ends with the trailer that ties it to the head (§4.2),
  # exactly once: a body already ending in it is sent as is, and one ending in
  # another head's trailer is refused rather than sent with two.
  local last
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

  if [ -n "${GH_REVIEW_TOKEN:-}" ]; then
    rv() { GH_TOKEN="$GH_REVIEW_TOKEN" gh "$@"; }
  else
    rv() { gh "$@"; }
  fi
  if rv pr review "$n" "$flag" --body-file "$tmp/verdict.md" 2> "$tmp/review.err"; then
    form=formal
    out=$(gh pr view "$n" --json url | jq -r .url)
  elif grep -qi 'own pull request' "$tmp/review.err"; then
    # GitHub rejects approve/request-changes on one's own PR (GC29): post the
    # same body as a comment; the graph status is the verdict of record.
    form=comment
    out=$(post_comment "$n" "$tmp/verdict-comment.md" rv) || exit 1
  else
    cat "$tmp/review.err" >&2
    die "gh pr review #$n failed"
  fi
  jq -cn --arg form "$form" --arg url "$out" '{posted: true, form: $form, url: $url}'
}

op_pr_reviews() {
  need_n "${1:-}" "pr-reviews <n>"
  gh pr view "$1" --json reviews,comments | fjq -c 'include "forge-github"; gh_reviews'
}

op_pr_comment() {
  need_n "${1:-}" "pr-comment <n> --body-file F"
  [ "${2:-}" = --body-file ] && [ -f "${3:-}" ] || usage "pr-comment <n> --body-file F"
  local url
  url=$(post_comment "$1" "$3") || exit 1
  jq -cn --arg url "$url" '{posted: true, url: $url}'
}

op_pr_comments() {
  need_n "${1:-}" "pr-comments <n>"
  gh pr view "$1" --json comments | fjq -c 'include "forge-github"; gh_comments'
}

op_pr_merge() {
  local u="pr-merge <n> --method squash|merge --sha S"
  local n="${1:-}" method="" sha="" head after
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
  head=$(require_head "$n" "$sha")
  gh pr merge "$n" "--$method" --match-head-commit "$sha" || die "gh pr merge #$n failed"
  # Without --auto, gh can still enable auto-merge when requirements are
  # pending. Only a re-read that shows MERGED counts (GC63).
  after=$(gh pr view "$n" --json state,autoMergeRequest)
  if [ "$(jq -r '.state' <<<"$after")" != MERGED ]; then
    if [ "$(jq -r '.autoMergeRequest != null' <<<"$after")" = true ]; then
      gh pr merge "$n" --disable-auto || echo "forge-github: could not disable auto-merge on #$n" >&2
      die "PR #$n was not merged (gh enabled auto-merge instead; disabled it)"
    fi
    die "PR #$n is $(jq -r '.state' <<<"$after") after merge, not MERGED"
  fi
  if [ "$method" = squash ]; then
    # Best effort: the repo may already auto-delete head branches.
    gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$head" >/dev/null 2>&1 \
      || echo "forge-github: note: head branch '$head' not deleted (already gone?)" >&2
  fi
  jq -cn --argjson n "$n" '{number: $n, state: "merged"}'
}

op_pr_set_base() {
  need_n "${1:-}" "pr-set-base <n> <branch>"
  [ -n "${2:-}" ] || usage "pr-set-base <n> <branch>"
  gh pr edit "$1" --base "$2" >/dev/null
}

op_pr_files() { need_n "${1:-}" "pr-files <n>"; gh pr diff "$1" --name-only; }
op_pr_diff()  { need_n "${1:-}" "pr-diff <n>";  gh pr diff "$1"; }

# Best effort: the failed-job logs of the head commit's failed Actions runs.
op_ci_failures() {
  need_n "${1:-}" "ci-failures <n>"
  local sha id
  sha=$(gh pr view "$1" --json headRefOid | jq -r .headRefOid)
  gh run list --commit "$sha" --status failure --limit "$LIST_LIMIT" --json databaseId > "$tmp/runs.json"
  for id in $(jq -r '.[].databaseId' "$tmp/runs.json"); do
    gh run view "$id" --log-failed || echo "forge-github: no failed-job log for run $id" >&2
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
  *) usage "forge-github.sh <op> [args] (see docs/delivery_graph_spec.md §7.1)" ;;
esac
