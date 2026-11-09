#!/usr/bin/env bash
# Tests for delivery-config.sh and lib/config.sh: every config key resolves with
# its default, and `--check` validates the backend/forge combination (golden
# cases GC40, GC41 and the `--check` part of GC59 of the delivery graph spec).
#
# Runs in a throwaway git repo under ${TMPDIR:-/tmp} so the host repo's own
# .claude/delivery.conf never leaks in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="$here/../delivery-config.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-config-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
mkdir -p "$tmp/.claude"

# Run delivery-config.sh in the temp repo with a clean slate: every config key
# and env-only key unset, then the given VAR=value assignments applied.
# Sets $rc and $out (stdout+stderr).
run() {
  out=$(cd "$tmp" && env -u GRAPH_BACKEND -u FORGE -u GITLAB_TOKEN -u GITEA_TOKEN \
    -u STATE_DIR -u LIST_LIMIT -u FORGE_URL -u FORGE_REPO -u PLANS_DIR \
    -u TASK_MERGE_METHOD -u PROMOTE_MERGE_METHOD -u PROMOTE_GATE_CMD \
    -u LOCK_STALE_SECONDS -u GH_REVIEW_TOKEN -u GITLAB_REVIEW_TOKEN \
    -u GITEA_REVIEW_TOKEN -u LOCK_WAIT_SECONDS \
    "$@" bash "$cfg" ${ARGS:-} 2>&1) && rc=0 || rc=$?
}

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; echo "        rc=$rc output: $out" >&2; fails=1; }
expect_rc() { # name expected-rc [needle-in-output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s' "$out" | grep -qF -- "$3"; }; then
    ok "$1"
  else
    fail "$1 (want rc=$2${3:+, output containing '$3'})"
  fi
}

conf() { printf '%s\n' "$@" > "$tmp/.claude/delivery.conf"; }
noconf() { rm -f "$tmp/.claude/delivery.conf"; }

# --- printing: every key resolves to its §11 default --------------------------
noconf; ARGS=; run
for kv in GRAPH_BACKEND=github STATE_DIR= LOCK_STALE_SECONDS=120 LIST_LIMIT=5000 \
          FORGE=github FORGE_URL= FORGE_REPO= PLANS_DIR=docs/plans/ \
          TASK_MERGE_METHOD=squash PROMOTE_MERGE_METHOD=merge PROMOTE_GATE_CMD=; do
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qxF -- "$kv"; then ok "default $kv"; else fail "default $kv"; fi
done

ARGS=--bogus; run
expect_rc "unknown argument -> usage, exit 2" 2 "usage"

# --- --check -------------------------------------------------------------------
ARGS=--check

noconf; run
expect_rc "defaults (github/github) are valid" 0

run GRAPH_BACKEND=github FORGE=gitlab GITLAB_TOKEN=x
expect_rc "GC40: GRAPH_BACKEND=github FORGE=gitlab -> exit 1" 1 "GRAPH_BACKEND=github requires FORGE=github"

run GRAPH_BACKEND=sqlite
expect_rc "GC41: GRAPH_BACKEND=sqlite -> exit 1, lists valid backends" 1 "github local"

run GRAPH_BACKEND=local FORGE=bitbucket
expect_rc "unknown FORGE -> exit 1, lists valid forges" 1 "github gitlab gitea"

run GRAPH_BACKEND=local FORGE=gitlab
expect_rc "GC59: FORGE=gitlab, GITLAB_TOKEN unset -> exit 1" 1 "GITLAB_TOKEN"

run GRAPH_BACKEND=local FORGE=gitea
expect_rc "GC59: FORGE=gitea, GITEA_TOKEN unset -> exit 1" 1 "GITEA_TOKEN"

run GRAPH_BACKEND=local FORGE=gitlab GITLAB_TOKEN=x
expect_rc "local + gitlab with token -> valid" 0

run GRAPH_BACKEND=local FORGE=gitea GITEA_TOKEN=x
expect_rc "local + gitea with token -> valid" 0

run GRAPH_BACKEND=local
expect_rc "local + github -> valid" 0

# The combination may come from the conf file; tokens may not (env only).
conf 'GRAPH_BACKEND=local' 'FORGE=gitlab' 'GITLAB_TOKEN=from-file'
run
expect_rc "GC59: token set only in delivery.conf is ignored -> exit 1" 1 "GITLAB_TOKEN"

run GITLAB_TOKEN=x
expect_rc "conf combination + env token -> valid" 0

conf 'GRAPH_BACKEND=sqlite'
run
expect_rc "GC41 via delivery.conf -> exit 1" 1 "github local"
noconf

# --- --check: the jq on PATH (dl_jq_check) ---------------------------------------
# A shim jq first on PATH reports $DL_FAKE_JQ_VERSION for --version and hands
# every other call to the real jq, so only the version check sees the fake.
real_jq="$(command -v jq)"
mkdir "$tmp/shim"
cat > "$tmp/shim/jq" <<EOF
#!/bin/sh
if [ "\$1" = --version ]; then echo "\$DL_FAKE_JQ_VERSION"; exit 0; fi
exec "$real_jq" "\$@"
EOF
chmod +x "$tmp/shim/jq"
shim_path="$tmp/shim:$PATH"

run PATH="$shim_path" DL_FAKE_JQ_VERSION=jq-1.8.2
expect_rc "jq 1.8.2 -> exit 1, names jqlang/jq#3597" 1 "jqlang/jq#3597"
expect_rc "jq 1.8.2 -> message names the remedy" 1 "install jq 1.8.1, or 1.8.3 or later"

run PATH="$shim_path" DL_FAKE_JQ_VERSION=jq-1.5
expect_rc "jq 1.5 (< 1.6) -> exit 1" 1 "needs jq >= 1.6"

for v in jq-1.6 jq-1.7.1 jq-1.8.1 jq-1.8.3; do
  run PATH="$shim_path" DL_FAKE_JQ_VERSION=$v
  expect_rc "$v -> valid" 0
done

# The refusal is part of --check, so it adds to (not replaces) config problems.
run PATH="$shim_path" DL_FAKE_JQ_VERSION=jq-1.8.2 GRAPH_BACKEND=sqlite
expect_rc "jq 1.8.2 + bad backend -> both reported" 1 "jqlang/jq#3597"
expect_rc "jq 1.8.2 + bad backend -> backend still reported" 1 "github local"

[ "$fails" = 0 ] || { echo "config-check-test: FAILED" >&2; exit 1; }
echo "config-check-test: all passed"
