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
  *) echo "gh-shim: unhandled call: gh $*" >&2; exit 64 ;;
esac
