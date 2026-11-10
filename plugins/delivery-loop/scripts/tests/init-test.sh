#!/usr/bin/env bash
# Tests for delivery-init.sh (docs/delivery_graph_spec.md §10 `init` row, §11,
# §6.3): golden case GC60, plus idempotency, the per-seam requirement checks
# (jq >= 1.6, not 1.8.2, git >= 2.31 for local, gh >= 2.94 for the github backend), the
# `promote` label on github, seam detection from origin, and the repo-settings
# advice keeping merge commits enabled.
#
# Offline: each case runs in a fresh throwaway git repo under ${TMPDIR:-/tmp}
# with shims first on PATH — gh (fixtures/init/gh-shim.sh: FAILS on any call
# unless GH_SHIM_MODE=ok), curl (fixtures/init/curl-shim.sh: answers the gitea
# whoami), and, per case, version-faking git/jq wrappers. FORGE_DRY_RUN=1 is set
# on the gitea path so no forge write could be sent.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
init="$here/../delivery-init.sh"
fx="$here/fixtures/init"
keys="$(sed -n 's/^_DL_VARS="\(.*\)"$/\1/p' "$here/../lib/config.sh")"
[ -n "$keys" ] || { echo "FAIL - could not read _DL_VARS from lib/config.sh" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-init-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
real_git="$(command -v git)"; real_jq="$(command -v jq)"
mkdir -p "$tmp/bin" "$tmp/oldgit" "$tmp/oldjq"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/gh-shim.sh" > "$tmp/bin/gh"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/curl-shim.sh" > "$tmp/bin/curl"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo "git version 2.30.9"; exit 0; }\nexec "%s" "$@"\n' "$real_git" > "$tmp/oldgit/git"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo "jq-1.5"; exit 0; }\nexec "%s" "$@"\n' "$real_jq" > "$tmp/oldjq/jq"
mkdir -p "$tmp/badjq"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo "jq-1.8.2"; exit 0; }\nexec "%s" "$@"\n' "$real_jq" > "$tmp/badjq/jq"
chmod +x "$tmp/badjq/jq"
chmod +x "$tmp/bin/gh" "$tmp/bin/curl" "$tmp/oldgit/git" "$tmp/oldjq/jq"

# newrepo <name> [origin-url]: a fresh git repo at $tmp/<name>; sets $repo.
newrepo() {
  repo="$tmp/$1"
  "$real_git" init -q "$repo"
  [ -z "${2:-}" ] || "$real_git" -C "$repo" remote add origin "$2"
  mkdir -p "$repo/.shim"; : > "$repo/.shim/gh.log"; : > "$repo/.shim/curl.log"
}

# run [-p extra-path-dir] [VAR=value …] -- [args…]: delivery-init.sh in $repo
# with a scrubbed environment. Sets $rc, $out (stdout+stderr).
run() {
  local pre="" envs=""
  if [ "$1" = -p ]; then pre="$2:"; shift 2; fi
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  local unset_args="" k
  for k in $keys GITLAB_TOKEN GITEA_TOKEN GH_REVIEW_TOKEN GITLAB_REVIEW_TOKEN GITEA_REVIEW_TOKEN \
           LOCK_WAIT_SECONDS FORGE_DRY_RUN GH_TOKEN GITHUB_TOKEN GH_REPO GH_HOST GH_SHIM_MODE GH_SHIM_VERSION; do
    unset_args="$unset_args -u $k"
  done
  # shellcheck disable=SC2086
  (cd "$repo" && env $unset_args PATH="$pre$tmp/bin:$PATH" SHIM_STATE="$repo/.shim" $envs \
     bash "$init" "$@" </dev/null >"$tmp/out" 2>&1) && rc=0 || rc=$?
  out=$(cat "$tmp/out")
}

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; echo "        rc=$rc output:" >&2; printf '%s\n' "$out" | sed 's/^/          /' >&2; fails=1; }
expect() { if eval "$2"; then ok "$1"; else fail "$1 [$2]"; fi; }
conf_val() { sed -n "s/^$1=//p" "$repo/.claude/delivery.conf"; }
all_keys() { local k; for k in $keys; do grep -q "^$k=" "$repo/.claude/delivery.conf" || return 1; done; }
gh_calls() { wc -l < "$repo/.shim/gh.log" | tr -d ' '; }

GITEA=(GRAPH_BACKEND=local FORGE=gitea GITEA_TOKEN=s3cr3t-tok FORGE_DRY_RUN=1)

# --- GC60: local backend + gitea forge ----------------------------------------
newrepo gc60 git@gitea.example.com:example/repo.git
run "${GITEA[@]}" --
st="$repo/.git/delivery"
expect "GC60: exits 0" '[ "$rc" = 0 ]'
expect "GC60: STATE_DIR created at <git-common-dir>/delivery with store.json schema 1" \
  '[ "$(jq -r ".schema" "$st/store.json" 2>/dev/null)" = 1 ] && jq -e ".created_at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$\")" "$st/store.json" >/dev/null'
expect "GC60: STATE_DIR has epics/ and events.jsonl (§6.3 layout)" '[ -d "$st/epics" ] && [ -f "$st/events.jsonl" ] && [ ! -e "$st/lock" ]'
expect "GC60: zero gh calls" '[ "$(gh_calls)" = 0 ]'
expect "GC60: conf scaffold contains every §11 key" 'all_keys'
expect "GC60: conf records GRAPH_BACKEND=local FORGE=gitea" '[ "$(conf_val GRAPH_BACKEND)" = local ] && [ "$(conf_val FORGE)" = gitea ]'
expect "GC60: no token in the checked-in conf" '! grep -q s3cr3t-tok "$repo/.claude/delivery.conf"'
expect "GC60: printed advice has no --enable-merge-commit=false" '! grep -qF -- "--enable-merge-commit=false" "$tmp/out"'
expect "GC60: advice keeps merge commits enabled (gitea)" 'grep -qF "Create merge commit" "$tmp/out" && grep -qF "Keep merge commits ENABLED" "$tmp/out"'
expect "GC60: forge auth checked via forge.sh whoami" 'grep -qxF "GET https://gitea.example.com/api/v1/user" "$repo/.shim/curl.log" && grep -qF "authenticated as gitea-bot" "$tmp/out"'
expect "GC60: labels skipped on the local backend" 'grep -qF "labels: skipped" "$tmp/out"'

# --- idempotent re-run ---------------------------------------------------------
cp "$st/store.json" "$tmp/store.before"; cp "$repo/.claude/delivery.conf" "$tmp/conf.before"
cp "$repo/scripts/check.sh" "$tmp/check.before"; cp "$repo/.gitignore" "$tmp/gitignore.before"
run "${GITEA[@]}" --
expect "re-run: exits 0" '[ "$rc" = 0 ]'
expect "re-run: store.json, conf, check.sh and .gitignore unchanged" \
  'cmp -s "$st/store.json" "$tmp/store.before" && cmp -s "$repo/.claude/delivery.conf" "$tmp/conf.before" && cmp -s "$repo/scripts/check.sh" "$tmp/check.before" && cmp -s "$repo/.gitignore" "$tmp/gitignore.before"'
expect "re-run: reports the store as already initialized; still zero gh calls" 'grep -qF "already initialized" "$tmp/out" && [ "$(gh_calls)" = 0 ]'

# --- re-run resolves seams from the existing conf (no env) ---------------------
run GITEA_TOKEN=s3cr3t-tok FORGE_DRY_RUN=1 --
expect "existing conf: seams read from it (local/gitea), exits 0, zero gh calls" \
  '[ "$rc" = 0 ] && grep -qF "GRAPH_BACKEND=local FORGE=gitea (from .claude/delivery.conf)" "$tmp/out" && [ "$(gh_calls)" = 0 ]'

# --- a lost store.json is refused, never recreated -----------------------------
echo '{"schema":1,"epic":null,"nodes":[]}' > "$st/epics/inbox.json"
rm "$st/store.json"
run "${GITEA[@]}" --
expect "orphan epics: exits 1 and does not recreate store.json" '[ "$rc" = 1 ] && [ ! -e "$st/store.json" ] && grep -qF "restore store.json" "$tmp/out"'
echo '{"schema":2}' > "$st/store.json"
run "${GITEA[@]}" --
expect "schema mismatch: exits 1, store untouched" '[ "$rc" = 1 ] && [ "$(jq -c . "$st/store.json")" = "{\"schema\":2}" ] && grep -qF "schema mismatch" "$tmp/out"'

# --- explicit STATE_DIR ---------------------------------------------------------
newrepo statedir git@gitea.example.com:example/repo.git
run "${GITEA[@]}" STATE_DIR="$tmp/explicit-state" --
expect "STATE_DIR set: the store is created there" '[ "$rc" = 0 ] && [ -f "$tmp/explicit-state/store.json" ] && [ ! -e "$repo/.git/delivery" ]'

# --- requirement checks (fail before anything is written) ----------------------
newrepo oldgit git@gitea.example.com:example/repo.git
run -p "$tmp/oldgit" "${GITEA[@]}" --
expect "local backend on git 2.30: exits 1 naming git >= 2.31, nothing written" \
  '[ "$rc" = 1 ] && grep -qF "git >= 2.31" "$tmp/out" && [ ! -e "$repo/.claude/delivery.conf" ] && [ ! -e "$repo/.git/delivery" ]'

newrepo oldjq git@gitea.example.com:example/repo.git
run -p "$tmp/oldjq" "${GITEA[@]}" --
expect "jq 1.5: exits 1 naming jq >= 1.6, nothing written" '[ "$rc" = 1 ] && grep -qF "jq >= 1.6" "$tmp/out" && [ ! -e "$repo/.claude/delivery.conf" ]'

newrepo badjq git@gitea.example.com:example/repo.git
run -p "$tmp/badjq" "${GITEA[@]}" --
expect "jq 1.8.2: exits 1 naming the upstream bug, nothing written" '[ "$rc" = 1 ] && grep -qF "jqlang/jq#3597" "$tmp/out" && [ ! -e "$repo/.claude/delivery.conf" ]'

newrepo badcombo git@gitea.example.com:example/repo.git
run GRAPH_BACKEND=github FORGE=gitea GITEA_TOKEN=x --
expect "GRAPH_BACKEND=github FORGE=gitea: exits 1, nothing written, zero gh calls" \
  '[ "$rc" = 1 ] && grep -qF "requires FORGE=github" "$tmp/out" && [ ! -e "$repo/.claude/delivery.conf" ] && [ "$(gh_calls)" = 0 ]'

newrepo notoken git@gitea.example.com:example/repo.git
run GRAPH_BACKEND=local FORGE=gitea --
expect "FORGE=gitea without GITEA_TOKEN: exits 1, nothing written" '[ "$rc" = 1 ] && grep -qF "GITEA_TOKEN" "$tmp/out" && [ ! -e "$repo/.claude/delivery.conf" ]'

# --- github backend + github forge ----------------------------------------------
newrepo github https://github.com/example/repo.git
run GH_SHIM_MODE=ok --  extra
expect "github: exits 0" '[ "$rc" = 0 ]'
expect "github: seams detected from origin (github/github) and scaffolded" \
  'grep -qF "detected from origin (github.com)" "$tmp/out" && [ "$(conf_val GRAPH_BACKEND)" = github ] && [ "$(conf_val FORGE)" = github ]'
expect "github: creates the promote label" 'grep -q "^label create promote " "$repo/.shim/gh.log"'
expect "github: creates the task/status/module labels (incl. CLI arg module)" \
  'grep -q "^label create task " "$repo/.shim/gh.log" && grep -q "^label create status:ready " "$repo/.shim/gh.log" && grep -q "^label create module:extra " "$repo/.shim/gh.log"'
expect "github: forge auth via forge.sh whoami (gh api user)" 'grep -qxF "api user" "$repo/.shim/gh.log" && grep -qF "authenticated as gh-bot" "$tmp/out"'
expect "github: advice enables merge commits, never --enable-merge-commit=false" \
  'grep -qF -- "--enable-merge-commit " "$tmp/out" && ! grep -qF -- "--enable-merge-commit=false" "$tmp/out"'
expect "github: no local store created" '[ ! -e "$repo/.git/delivery" ]'

newrepo oldgh https://github.com/example/repo.git
run GH_SHIM_MODE=ok GH_SHIM_VERSION=2.93.1 --
expect "github backend on gh 2.93: exits 1 naming gh >= 2.94, nothing written" \
  '[ "$rc" = 1 ] && grep -qF "gh >= 2.94" "$tmp/out" && [ ! -e "$repo/.claude/delivery.conf" ]'

newrepo localgh https://github.com/example/repo.git
run GH_SHIM_MODE=ok GH_SHIM_VERSION=2.80.0 GRAPH_BACKEND=local --
expect "local backend + github forge on gh 2.80: exits 0 (gh >= 2.94 not needed), no labels" \
  '[ "$rc" = 0 ] && ! grep -q "^label create" "$repo/.shim/gh.log" && grep -qxF "api user" "$repo/.shim/gh.log" && [ -f "$repo/.git/delivery/store.json" ]'

# --- detection: a gitea host defaults to the local backend ----------------------
newrepo detect https://gitea.example.com/example/repo.git
run GITEA_TOKEN=s3cr3t-tok FORGE_DRY_RUN=1 --
expect "detect: gitea origin -> FORGE=gitea GRAPH_BACKEND=local, zero gh calls" \
  '[ "$rc" = 0 ] && [ "$(conf_val FORGE)" = gitea ] && [ "$(conf_val GRAPH_BACKEND)" = local ] && [ "$(gh_calls)" = 0 ]'

# --- no remote: local scaffolding done, exit 2 ----------------------------------
newrepo noremote
run "${GITEA[@]}" --
expect "no remote: exits 2 after scaffolding conf + store, zero gh calls, no forge call" \
  '[ "$rc" = 2 ] && [ -f "$repo/.claude/delivery.conf" ] && [ -f "$repo/.git/delivery/store.json" ] && [ "$(gh_calls)" = 0 ] && [ ! -s "$repo/.shim/curl.log" ]'

if [ "$fails" = 0 ]; then echo "init-test: all passed"; else echo "init-test: FAILURES" >&2; exit 1; fi
