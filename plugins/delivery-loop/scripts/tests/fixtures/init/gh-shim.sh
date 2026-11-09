#!/usr/bin/env bash
# gh shim for tests/init-test.sh. Every call is appended to $SHIM_STATE/gh.log.
#   GH_SHIM_MODE=fail (default): exit 1 on any call — the local+gitea path must
#                                never reach gh (GC60).
#   GH_SHIM_MODE=ok:             answer --version ($GH_SHIM_VERSION, default
#                                2.96.0), auth status, repo view, label create
#                                and api user.
set -euo pipefail
printf '%s\n' "$*" >> "$SHIM_STATE/gh.log"
[ "${GH_SHIM_MODE:-fail}" = ok ] || { echo "gh shim: gh must not be called on this path: gh $*" >&2; exit 1; }
case "$1 ${2:-}" in
  "--version ") echo "gh version ${GH_SHIM_VERSION:-2.96.0} (2026-01-01)" ;;
  "auth status") : ;;
  "repo view") echo '{"nameWithOwner":"example/repo","hasIssuesEnabled":true}' ;;
  "label create") : ;;
  "api user") echo '{"login":"gh-bot"}' ;;
  *) echo "gh shim: unexpected call: gh $*" >&2; exit 1 ;;
esac
