#!/usr/bin/env bash
# config-test.sh — the cost-control keys resolve defaults < delivery.conf < env,
# an invalid REREVIEW_SCOPE falls back to the thorough choice, and every key is
# exported to child processes. Targets bash 3.2.
set -euo pipefail

CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/config.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
mkdir -p "$tmp/.claude"
fail=0

# resolve <VAR> [env assignments...] -> prints the value config.sh yields, read
# from a CHILD process so a missing export would show as empty.
resolve() {
  local var="$1"; shift
  ( cd "$tmp" && env "$@" bash -c '. "$0"; bash -c "printf %s \"\${'"$var"':-}\""' "$CFG" )
}
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then return 0; fi
  echo "FAIL $1: expected '$2' got '$3'"; fail=1
}

# 1. defaults with no conf file: models inherit (empty), re-review is narrow.
for k in MODEL_IMPLEMENT_S MODEL_IMPLEMENT_M MODEL_IMPLEMENT_L MODEL_REVIEW MODEL_REREVIEW MODEL_PATCH AGENT_RULES_FILE; do
  check "default $k" "" "$(resolve "$k")"
done
check "default REREVIEW_SCOPE" narrow "$(resolve REREVIEW_SCOPE)"

# 2. the repo's delivery.conf overrides defaults.
cat > "$tmp/.claude/delivery.conf" <<'CONF'
MODEL_IMPLEMENT_S="sonnet"
MODEL_IMPLEMENT_L="opus"
MODEL_REREVIEW="sonnet"
REREVIEW_SCOPE="full"
AGENT_RULES_FILE="docs/RULES.md"
CONF
check "conf MODEL_IMPLEMENT_S" sonnet "$(resolve MODEL_IMPLEMENT_S)"
check "conf MODEL_IMPLEMENT_M left default" "" "$(resolve MODEL_IMPLEMENT_M)"
check "conf MODEL_IMPLEMENT_L" opus "$(resolve MODEL_IMPLEMENT_L)"
check "conf MODEL_REREVIEW" sonnet "$(resolve MODEL_REREVIEW)"
check "conf REREVIEW_SCOPE" full "$(resolve REREVIEW_SCOPE)"
check "conf AGENT_RULES_FILE" docs/RULES.md "$(resolve AGENT_RULES_FILE)"

# 3. environment beats the conf file.
check "env beats conf (model)" haiku "$(resolve MODEL_IMPLEMENT_S MODEL_IMPLEMENT_S=haiku)"
check "env beats conf (scope)" narrow "$(resolve REREVIEW_SCOPE REREVIEW_SCOPE=narrow)"

# 4. an unrecognised scope must fall back to full, never to the cheap path.
check "invalid scope in conf -> full" full "$(printf 'REREVIEW_SCOPE="nrrow"\n' > "$tmp/.claude/delivery.conf"; resolve REREVIEW_SCOPE)"
check "invalid scope in env -> full" full "$(rm -f "$tmp/.claude/delivery.conf"; resolve REREVIEW_SCOPE REREVIEW_SCOPE=cheap)"

# 5. delivery-config.sh (the "what will the engine use" printer) lists every key.
printed="$(cd "$tmp" && MODEL_REVIEW=opus bash "$(dirname "$CFG")/../delivery-config.sh")"
for k in MODEL_IMPLEMENT_S MODEL_IMPLEMENT_M MODEL_IMPLEMENT_L MODEL_REVIEW MODEL_REREVIEW MODEL_PATCH REREVIEW_SCOPE AGENT_RULES_FILE; do
  case "$printed" in *"$k="*) ;; *) echo "FAIL delivery-config.sh omits $k"; fail=1 ;; esac
done
check "delivery-config.sh shows env value" "MODEL_REVIEW=opus" "$(printf '%s\n' "$printed" | grep '^MODEL_REVIEW=')"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "config tests passed"
