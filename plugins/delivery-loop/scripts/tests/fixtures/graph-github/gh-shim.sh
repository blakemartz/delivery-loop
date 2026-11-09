#!/usr/bin/env bash
# gh-shim.sh — an offline, recording stand-in for `gh`, for graph-github tests.
#
# The test installs it on PATH as `gh`. Every call is appended to $SHIM_STATE/log
# as one line: `gh <args…>`. Responses come from $SHIM_FX/$SHIM_BOARD, an array
# of issues in the `gh issue list --json …` shape:
#   - `issue list --json F --limit L` returns the first L issues (gh pages
#     internally up to --limit; default 30), keeping only the fields in F, as
#     real gh does. Any `_view` key is stripped. As real gh does (2.96.0), each
#     issue's `comments` is cut to its first 100, with no total (GC74).
#   - `issue view N --json F` returns issue N with its optional `_view` object
#     merged over it (e.g. a complete `blockedBy` connection where the list
#     returned a truncated one, GC64), keeping only the fields in F. Its
#     `comments` are complete.
#   - `api [--paginate] repos/{owner}/{repo}/issues/N/comments?per_page=P`
#     returns issue N's complete `comments` in the REST shape ({id, user:
#     {login} | null, body, created_at}), cut into pages of P (default 30, at
#     most 100, as the API does). Like real gh, `--paginate` prints every page
#     as its own JSON array, one after the other; without it, only the first.
#     An issue with no comments is one empty page.
#   - `--version` prints `gh version $SHIM_GH_VERSION` (default 2.96.0).
set -euo pipefail

: "${SHIM_FX:?}" "${SHIM_STATE:?}"
echo "gh $*" >> "$SHIM_STATE/log"
board="$SHIM_FX/${SHIM_BOARD:-cases-issues.json}"

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
  "--version ")
    echo "gh version ${SHIM_GH_VERSION:-2.96.0} (2026-07-02)"
    echo "https://github.com/cli/cli/releases/tag/v${SHIM_GH_VERSION:-2.96.0}" ;;
  "issue list")
    fields=$(opt --json "$@"); limit=$(opt --limit "$@")
    jq -c --argjson lim "${limit:-30}" '.[0:$lim] | map(del(._view) | if (.comments | type) == "array" then .comments |= .[0:100] else . end)' "$board" \
      | jq -c --arg f "$fields" 'map(. as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k]))' ;;
  "issue view")
    n="$3"; fields=$(opt --json "$@")
    obj=$(jq -c --argjson n "$n" '.[] | select(.number == $n) | (. + (._view // {})) | del(._view)' "$board")
    [ -n "$obj" ] || { echo "GraphQL: Could not resolve to an issue or pull request with the number of $n. (repository.issue)" >&2; exit 1; }
    pick "$fields" <<<"$obj" ;;
  "api "*)
    paginate=""; path=""
    shift
    for a in "$@"; do case "$a" in --paginate) paginate=1 ;; -*) echo "gh-shim: unhandled api flag: $a" >&2; exit 64 ;; *) path="$a" ;; esac; done
    case "$path" in
      'repos/{owner}/{repo}/issues/'*/comments*) : ;;
      *) echo "gh-shim: unhandled call: gh api $*" >&2; exit 64 ;;
    esac
    n="${path#repos/\{owner\}/\{repo\}/issues/}"; n="${n%%/*}"
    per=$(sed -n 's/.*[?&]per_page=\([0-9][0-9]*\).*/\1/p' <<<"$path"); per="${per:-30}"
    [ "$per" -le 100 ] || per=100
    jq -e --argjson n "$n" 'any(.[]; .number == $n)' "$board" > /dev/null \
      || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -c --argjson n "$n" --argjson per "$per" --arg all "$paginate" '
      [ .[] | select(.number == $n) | (. + (._view // {})) | (.comments // [])[]
        | {id: .id, user: (if .author == null then null else {login: .author.login} end),
           body: .body, created_at: .createdAt} ] as $c
      | if $c == [] then [] else
          [ range(0; $c | length; $per) as $i | $c[$i:$i + $per] ]
          | if $all == "" then .[0] else .[] end
        end' "$board" ;;
  *) echo "gh-shim: unhandled call: gh $*" >&2; exit 64 ;;
esac
