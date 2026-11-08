#!/usr/bin/env bash
# graph-github.sh <primitive> [args] — the github graph backend (GitHub Issues
# via `gh`), behind graph.sh (docs/delivery_graph_spec.md §6.1, §6.2).
#
# Read primitives (task B1):
#   list        every issue (open and closed) that is a delivery node, as one
#               JSON array of §4.1 nodes.
#   show <id>   one node (the issue number), as one JSON object.
#
# It stores; it does not decide (§3 rule 1): normalization lives in
# backends/graph-github.jq, and graph.sh validates the output (validate_node) and
# applies lib/*.jq. Invoke it through graph.sh, which resolves the config and runs
# the `--check` validation first; this file only reads the exported keys
# (LIST_LIMIT, BASE_BRANCH, FORGE_URL, FORGE_REPO).
#
# Exit codes: 0 ok · 1 failed · 2 usage · 3 the list reached LIST_LIMIT (never
# a silent truncation, GC10).
#
# Notes (§6.2):
#   - one `gh issue list --state all` with an explicit `--limit $LIST_LIMIT`;
#     gh pages internally. A result count equal to LIST_LIMIT exits 3.
#   - native relations (`blockedBy`, `parent`) need gh >= 2.94.0. On an older gh
#     the fields are not requested, only `Depends-on:` text edges are read, and
#     one warning is printed per invocation (GC56).
#   - a `blockedBy` connection whose `totalCount` exceeds its returned `nodes`
#     is re-read with `gh issue view <n> --json blockedBy` (GC64).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib"

: "${LIST_LIMIT:=5000}"
: "${BASE_BRANCH:=main}"
: "${FORGE_URL:=}"
: "${FORGE_REPO:=}"

# FORGE_URL / FORGE_REPO override what gh derives from `origin`, as in
# forge-github.sh: issues and PRs share one host (§3 rule 5).
if [ -n "$FORGE_URL" ]; then
  _host="${FORGE_URL#*://}"; _host="${_host%%/*}"
  [ -n "$_host" ] && export GH_HOST="$_host"
fi
if [ -n "$FORGE_REPO" ]; then
  export GH_REPO="${GH_HOST:+$GH_HOST/}$FORGE_REPO"
fi

BASE_FIELDS="number,title,state,stateReason,labels,assignees,body,createdAt,updatedAt,comments"
REL_FIELDS="blockedBy,parent"
MIN_GH="2.94.0"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-github.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

die()   { echo "graph-github: $*" >&2; exit 1; }
usage() { echo "graph-github: usage: $*" >&2; exit 2; }
gjq()   { jq -L "$LIB" -L "$SCRIPT_DIR" "$@"; }

case "$LIST_LIMIT" in
  ''|*[!0-9]*|0) die "LIST_LIMIT must be a positive integer (got '$LIST_LIMIT')" ;;
esac

# native: 1 when the installed gh supports `blockedBy`/`parent` (>= MIN_GH), else
# 0 with the one warning. An unparseable version is assumed current.
native=1
_ver=$(gh --version 2>/dev/null | sed -n '1s/^gh version \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' || true)
if [ -n "$_ver" ]; then
  _maj=${_ver%%.*}; _rest=${_ver#*.}; _min=${_rest%%.*}
  if [ "$_maj" -lt 2 ] || { [ "$_maj" -eq 2 ] && [ "$_min" -lt 94 ]; }; then
    native=0
    echo "graph-github: warning: gh < $MIN_GH: native relations ignored (gh $_ver; Depends-on: text edges only)" >&2
  fi
fi
if [ "$native" = 1 ]; then FIELDS="$BASE_FIELDS,$REL_FIELDS"; else FIELDS="$BASE_FIELDS"; fi

# warn_short <issues-file>: name every issue whose blockedBy is still short.
warn_short() {
  gjq -r 'include "graph-github"; .[] | select(gh_short_blocked)
          | "graph-github: warning: #\(.number) blockedBy has \(.blockedBy.nodes | length) of \(.blockedBy.totalCount) nodes after re-read; deps may be incomplete"' \
    "$1" >&2
}

op_list() {
  [ $# -eq 0 ] || usage "list"
  gh issue list --state all --json "$FIELDS" --limit "$LIST_LIMIT" > "$tmp/issues.json" \
    || die "gh issue list failed"
  local got
  got=$(jq 'length' "$tmp/issues.json")
  if [ "$got" -ge "$LIST_LIMIT" ]; then
    echo "graph-github: gh issue list returned $got issues = LIST_LIMIT ($LIST_LIMIT); refusing to truncate (raise LIST_LIMIT)" >&2
    exit 3
  fi
  if [ "$native" = 1 ]; then
    # GC64: re-read each overflowing blockedBy connection, then patch them in.
    echo '{}' > "$tmp/patch.json"
    local n
    for n in $(gjq -r 'include "graph-github"; .[] | select(gh_short_blocked) | .number' "$tmp/issues.json"); do
      gh issue view "$n" --json blockedBy > "$tmp/bb.json" || die "gh issue view $n --json blockedBy failed"
      jq --arg n "$n" --slurpfile bb "$tmp/bb.json" '.[$n] = $bb[0].blockedBy' \
        "$tmp/patch.json" > "$tmp/patch.next" && mv "$tmp/patch.next" "$tmp/patch.json"
    done
    jq --slurpfile p "$tmp/patch.json" \
      'map(($p[0][.number | tostring]) as $bb | if $bb != null then .blockedBy = $bb else . end)' \
      "$tmp/issues.json" > "$tmp/issues.next" && mv "$tmp/issues.next" "$tmp/issues.json"
    warn_short "$tmp/issues.json"
  fi
  gjq -c --arg base "$BASE_BRANCH" 'include "graph-github"; gh_nodes($base)' "$tmp/issues.json"
}

op_show() {
  [ $# -eq 1 ] || usage "show <id>"
  case "$1" in ''|*[!0-9]*) usage "show <id> (github ids are issue numbers)" ;; esac
  gh issue view "$1" --json "$FIELDS" > "$tmp/issue.json" || die "gh issue view $1 failed"
  jq '[.]' "$tmp/issue.json" > "$tmp/issues.json"
  [ "$native" = 0 ] || warn_short "$tmp/issues.json"
  gjq -c --arg base "$BASE_BRANCH" --arg id "$1" 'include "graph-github";
      gh_nodes($base) | first
      // error("issue #\($id) is not a delivery node (no task/epic/promote label)")' \
    "$tmp/issues.json" 2> "$tmp/err" || { sed 's/^jq: error (at [^)]*): //' "$tmp/err" >&2; exit 1; }
}

op="${1:-}"
[ $# -eq 0 ] || shift
case "$op" in
  list) op_list "$@" ;;
  show) op_show "$@" ;;
  *) usage "graph-github.sh list | show <id> (docs/delivery_graph_spec.md §6.1)" ;;
esac
