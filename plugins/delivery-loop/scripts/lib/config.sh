# config.sh — resolve per-repo delivery-loop configuration.
#
# Sourced (never executed) by the engine scripts, and printable via
# delivery-config.sh. Fills the delivery-loop settings from three layers, each
# winning over the one before it:
#   1. built-in defaults (below)
#   2. the consumer repo's .claude/delivery.conf, if present
#   3. environment variables already set when this file is sourced (for CI)
#
# Do NOT `set -e`/`set -u` here — this file is sourced into scripts that own
# their own shell options, and the expansions below are all guard-quoted.

_DL_VARS="BASE_BRANCH WORKTREE_SETUP_CMD GATE_CMD SPEC_SOURCES STYLEGUIDES_DIR MODULES NOTIFY_APPROVE_CMD NOTIFY_ESCALATE_CMD"

# 1/3 snapshot any env-provided overrides so they can win over the file.
for _v in $_DL_VARS; do eval "_env_$_v=\${$_v:-}"; done

# 2/3 the consumer repo's config file (relative to its git root).
_dl_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_dl_conf="$_dl_root/.claude/delivery.conf"
# shellcheck disable=SC1090
[ -f "$_dl_conf" ] && . "$_dl_conf"

# 3/3 re-apply env overrides (they win over the file). Use `if` (not `&&`) so an
# empty override leaves exit status 0 — a bare `... && ...` returns non-zero when
# the test fails, which would trip `set -e` in the sourcing script.
for _v in $_DL_VARS; do eval "if [ -n \"\$_env_$_v\" ]; then $_v=\"\$_env_$_v\"; fi"; done

# built-in defaults for anything still unset.
: "${BASE_BRANCH:=main}"
: "${WORKTREE_SETUP_CMD:=}"
: "${GATE_CMD:=bash scripts/check.sh}"
: "${SPEC_SOURCES:=docs/*_spec.md}"
: "${STYLEGUIDES_DIR:=styleguides/}"
: "${MODULES:=}"
: "${NOTIFY_APPROVE_CMD:=}"
: "${NOTIFY_ESCALATE_CMD:=}"

export BASE_BRANCH WORKTREE_SETUP_CMD GATE_CMD SPEC_SOURCES \
       STYLEGUIDES_DIR MODULES NOTIFY_APPROVE_CMD NOTIFY_ESCALATE_CMD
