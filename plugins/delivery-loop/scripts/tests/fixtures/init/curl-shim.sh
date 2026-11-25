#!/usr/bin/env bash
# curl shim for tests/init-test.sh: records `METHOD URL` in $SHIM_STATE/curl.log
# and plays a small stateful forge for the gitea and gitlab adapters:
#   GET  …/api/v1/user, …/api/v4/user     whoami (gitea-bot / gitlab-bot)
#   GET  <repo>/labels                     the labels created so far
#                                          ($SHIM_STATE/labels.json), all on page 1
#   POST <repo>/labels                     appends the label, 201
#   GET  …/api/v1/orgs/example/labels      403, as Gitea answers a repo-scoped
#                                          token (no read:organization)
# with <repo> = /api/v1/repos/example/repo (gitea) or
# /api/v4/projects/example%2Frepo (gitlab). Any other request is a 404.
# Honours -X, --data-binary @file, -o, -D and -w '%{http_code}'.
set -euo pipefail
method=GET out=/dev/null hdr=/dev/null w="" url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    --data-binary) data="$(cat "${2#@}")"; shift 2 ;;
    -H|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$SHIM_STATE/curl.log"
labels="$SHIM_STATE/labels.json"
[ -f "$labels" ] || echo '[]' > "$labels"
page="$(printf '%s' "$url" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p')"
case "$method ${url%%\?*}" in
  "GET "*/api/v1/user) code=200; echo '{"login":"gitea-bot","id":7}' > "$out" ;;
  "GET "*/api/v4/user) code=200; echo '{"username":"gitlab-bot","id":7}' > "$out" ;;
  "GET "*/api/v1/repos/example/repo/labels|"GET "*/api/v4/projects/example%2Frepo/labels)
    code=200
    if [ "${page:-1}" = 1 ]; then cat "$labels" > "$out"; else echo '[]' > "$out"; fi ;;
  "POST "*/api/v1/repos/example/repo/labels|"POST "*/api/v4/projects/example%2Frepo/labels)
    code=201
    jq -c --argjson d "$data" '. + [{id: (length + 1), name: $d.name, color: $d.color, description: $d.description}]' \
      "$labels" > "$labels.n" && mv "$labels.n" "$labels"
    jq -c '.[-1]' "$labels" > "$out" ;;
  "GET "*/api/v1/orgs/example/labels)
    code=403; echo '{"message":"token does not have at least one of required scope(s): [read:organization]"}' > "$out" ;;
  *) code=404; echo '{"message":"not found"}' > "$out" ;;
esac
printf 'HTTP/1.1 %s\r\n\r\n' "$code" > "$hdr"
[ -z "$w" ] || printf '%s' "$code"
