#!/usr/bin/env bash
# curl shim for tests/init-test.sh: records `METHOD URL` in $SHIM_STATE/curl.log
# and answers the gitea adapter's GET /api/v1/user (whoami) with a login; any
# other request is a 404. Honours -X, -o, -D and -w '%{http_code}'.
set -euo pipefail
method=GET out=/dev/null hdr=/dev/null w="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    -H|--data-binary|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$SHIM_STATE/curl.log"
case "$method $url" in
  "GET "*/api/v1/user) code=200; echo '{"login":"gitea-bot","id":7}' > "$out" ;;
  *) code=404; echo '{"message":"not found"}' > "$out" ;;
esac
printf 'HTTP/1.1 %s\r\n\r\n' "$code" > "$hdr"
[ -z "$w" ] || printf '%s' "$code"
