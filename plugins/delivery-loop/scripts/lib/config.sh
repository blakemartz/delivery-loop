# config.sh — resolve per-repo delivery-loop configuration.
#
# Sourced (never executed) by the engine scripts, and printable via
# delivery-config.sh. Fills the delivery-loop settings from three layers, each
# winning over the one before it:
#   1. built-in defaults (below)
#   2. the consumer repo's .claude/delivery.conf, if present
#   3. environment variables already set when this file is sourced (for CI)
#
# Secrets and a few runtime knobs are ENVIRONMENT ONLY (_DL_ENV_ONLY): they are
# never read from .claude/delivery.conf (a checked-in file). Any value the file
# assigns to one of them is discarded and the environment's value restored.
#
# Also defines dl_config_check, the validator behind `delivery-config.sh --check`
# that every entry point runs once at start-up before doing any I/O.
#
# Do NOT `set -e`/`set -u` here — this file is sourced into scripts that own
# their own shell options, and the expansions below are all guard-quoted.

_DL_VARS="BASE_BRANCH WORKTREE_SETUP_CMD GATE_CMD SPEC_SOURCES STYLEGUIDES_DIR MODULES NOTIFY_APPROVE_CMD NOTIFY_ESCALATE_CMD GRAPH_BACKEND STATE_DIR LOCK_STALE_SECONDS LIST_LIMIT FORGE FORGE_URL FORGE_REPO PLANS_DIR TASK_MERGE_METHOD PROMOTE_MERGE_METHOD PROMOTE_GATE_CMD"
_DL_ENV_ONLY="GITLAB_TOKEN GITEA_TOKEN GH_REVIEW_TOKEN GITLAB_REVIEW_TOKEN GITEA_REVIEW_TOKEN LOCK_WAIT_SECONDS"

# 1/3 snapshot any env-provided overrides so they can win over the file, and
# the env-only keys (set-ness included) so the file cannot supply them.
for _v in $_DL_VARS; do eval "_env_$_v=\${$_v:-}"; done
for _v in $_DL_ENV_ONLY; do
  eval "_envset_$_v=\${$_v+x}; _env_$_v=\${$_v:-}"
done

# 2/3 the consumer repo's config file (relative to its git root).
_dl_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_dl_conf="$_dl_root/.claude/delivery.conf"
# shellcheck disable=SC1090
[ -f "$_dl_conf" ] && . "$_dl_conf"

# 3/3 re-apply env overrides (they win over the file). Use `if` (not `&&`) so an
# empty override leaves exit status 0 — a bare `... && ...` returns non-zero when
# the test fails, which would trip `set -e` in the sourcing script.
for _v in $_DL_VARS; do eval "if [ -n \"\$_env_$_v\" ]; then $_v=\"\$_env_$_v\"; fi"; done
# env-only keys: restore exactly what the environment had (unset stays unset).
for _v in $_DL_ENV_ONLY; do
  eval "if [ -n \"\$_envset_$_v\" ]; then $_v=\"\$_env_$_v\"; else unset $_v; fi"
done

# built-in defaults for anything still unset.
: "${BASE_BRANCH:=main}"
: "${WORKTREE_SETUP_CMD:=}"
: "${GATE_CMD:=bash scripts/check.sh}"
: "${SPEC_SOURCES:=docs/*_spec.md}"
: "${STYLEGUIDES_DIR:=styleguides/}"
: "${MODULES:=}"
: "${NOTIFY_APPROVE_CMD:=}"
: "${NOTIFY_ESCALATE_CMD:=}"
: "${GRAPH_BACKEND:=github}"
: "${STATE_DIR:=}"              # empty -> <git-common-dir>/delivery (local backend)
: "${LOCK_STALE_SECONDS:=120}"
: "${LIST_LIMIT:=5000}"
: "${FORGE:=github}"
: "${FORGE_URL:=}"              # empty -> derived from origin by the forge adapter
: "${FORGE_REPO:=}"             # empty -> derived from origin by the forge adapter
: "${PLANS_DIR:=docs/plans/}"
: "${TASK_MERGE_METHOD:=squash}"
: "${PROMOTE_MERGE_METHOD:=merge}"
: "${PROMOTE_GATE_CMD:=}"       # empty -> GATE_CMD

export BASE_BRANCH WORKTREE_SETUP_CMD GATE_CMD SPEC_SOURCES \
       STYLEGUIDES_DIR MODULES NOTIFY_APPROVE_CMD NOTIFY_ESCALATE_CMD \
       GRAPH_BACKEND STATE_DIR LOCK_STALE_SECONDS LIST_LIMIT \
       FORGE FORGE_URL FORGE_REPO PLANS_DIR \
       TASK_MERGE_METHOD PROMOTE_MERGE_METHOD PROMOTE_GATE_CMD

# dl_jq_check — refuse a jq the engine cannot run on. Supported: jq >= 1.6,
# except exactly 1.8.2, which mis-links nested module includes (upstream
# jqlang/jq#3597) and crashes most of scripts/lib/. A version string that does
# not parse as a release (a git snapshot, or a dev build past a tag such as
# "jq-1.8.2-12-gabc") is accepted with no error: it cannot be placed in the
# range, and refusing it would block working installs. (Alpine's jq 1.6 build,
# e.g. v3.14 "jq-1.6-r1", reports such a string, "jq-master-v20210212-…"; it
# is accepted, as 1.6 is.)
# Prints one line to stderr and returns 1 if refused; returns 0 (silent) if ok.
dl_jq_check() {
  local _dl_v _dl_core _dl_major _dl_minor _dl_patch
  if ! _dl_v="$(jq --version 2>/dev/null)"; then
    echo "config: jq not found (or not runnable); the delivery loop needs jq >= 1.6 (not 1.8.2)" >&2
    return 1
  fi
  _dl_core="${_dl_v#jq-}"
  case "$_dl_core" in
    [0-9]*.[0-9]*) : ;;
    *) return 0 ;;                                        # unparseable: accept
  esac
  case "$_dl_core" in
    *-[0-9]*-g*) return 0 ;;                              # dev build past a tag
  esac
  _dl_core="${_dl_core%%[!0-9.]*}"                        # drop -dirty, rc1, ...
  _dl_major="${_dl_core%%.*}"; _dl_core="${_dl_core#*.}"
  _dl_minor="${_dl_core%%.*}"
  case "$_dl_core" in *.*) _dl_patch="${_dl_core#*.}"; _dl_patch="${_dl_patch%%.*}" ;; *) _dl_patch=0 ;; esac
  case "$_dl_major" in ''|*[!0-9]*) return 0 ;; esac
  case "$_dl_minor" in ''|*[!0-9]*) return 0 ;; esac
  case "$_dl_patch" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_dl_major" -lt 1 ] || { [ "$_dl_major" -eq 1 ] && [ "$_dl_minor" -lt 6 ]; }; then
    echo "config: $_dl_v is too old; the delivery loop needs jq >= 1.6 (not 1.8.2)" >&2
    return 1
  fi
  if [ "$_dl_major" -eq 1 ] && [ "$_dl_minor" -eq 8 ] && [ "$_dl_patch" -eq 2 ]; then
    echo "config: $_dl_v is unsupported: it mis-links nested module includes and crashes the engine (upstream bug jqlang/jq#3597); install jq 1.8.1, or 1.8.3 or later once released" >&2
    return 1
  fi
  return 0
}

# dl_config_check — validate the resolved combination (and the jq on PATH, via
# dl_jq_check). Prints one line per problem to stderr and returns 1 if any;
# returns 0 (silent) if valid.
dl_config_check() {
  local _dl_bad=0
  dl_jq_check || _dl_bad=1
  case "$GRAPH_BACKEND" in
    github|local) : ;;
    *) echo "config: unknown GRAPH_BACKEND='$GRAPH_BACKEND' (valid: github local)" >&2; _dl_bad=1 ;;
  esac
  case "$FORGE" in
    github|gitlab|gitea) : ;;
    *) echo "config: unknown FORGE='$FORGE' (valid: github gitlab gitea)" >&2; _dl_bad=1 ;;
  esac
  if [ "$GRAPH_BACKEND" = github ] && [ "$FORGE" != github ]; then
    echo "config: GRAPH_BACKEND=github requires FORGE=github (got FORGE='$FORGE'); use GRAPH_BACKEND=local with a non-github forge" >&2
    _dl_bad=1
  fi
  case "$FORGE" in
    gitlab) if [ -z "${GITLAB_TOKEN:-}" ]; then
              echo "config: FORGE=gitlab requires GITLAB_TOKEN in the environment (never in .claude/delivery.conf)" >&2; _dl_bad=1
            fi ;;
    gitea)  if [ -z "${GITEA_TOKEN:-}" ]; then
              echo "config: FORGE=gitea requires GITEA_TOKEN in the environment (never in .claude/delivery.conf)" >&2; _dl_bad=1
            fi ;;
  esac
  return "$_dl_bad"
}
