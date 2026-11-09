#!/usr/bin/env bash
# Tests for backends/graph-local.sh (store, lock, journal, list/show/create/
# update/link/flag) and graph.sh list/show/ready over it (docs/delivery_graph_spec.md
# §4.1, §6.1, §6.3): golden cases GC22 (a-d), GC23, GC27, GC66 and GC44
# (`pinged_at` derivation) — §17 row C1.
#
# Runs in a throwaway git repo under ${TMPDIR:-/tmp}, so the host repo's
# .claude/delivery.conf and git dir never leak in. Lock waits are shortened with
# LOCK_WAIT_SECONDS; the GC22(c) race is forced with marker files
# (fixtures/graph-local/lock-race.sh), not timing. Every node read back is checked
# with validate_node (lib/node.jq), directly and via graph.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backend="$here/../backends/graph-local.sh"
graph="$here/../graph.sh"
lib="$here/../lib"
fx="$here/fixtures/graph-local"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-local-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# Every config key this file controls is cleared first; STATE_DIR is set per case.
ENV_CLEAR="-u STATE_DIR -u GRAPH_BACKEND -u FORGE -u BASE_BRANCH -u LOCK_STALE_SECONDS -u LOCK_WAIT_SECONDS -u GITLAB_TOKEN -u GITEA_TOKEN"

# gl <cwd> [VAR=value …] -- <backend args…>: sets $rc, $out, $err.
# g  <cwd> [VAR=value …] -- <graph.sh args…>: the same through graph.sh.
_run() {
  local script="$1" cwd="$2" envs=""; shift 2
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  # shellcheck disable=SC2086
  (cd "$cwd" && env $ENV_CLEAR GRAPH_BACKEND=local $envs bash "$script" "$@" \
     >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
gl() { _run "$backend" "$@"; }
g()  { _run "$graph" "$@"; }

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
# node <id> <jq>: a field of node <id> in the last list output.
node() { jq -c --arg id "$1" ".[] | select(.id == \$id) | $2" <<<"$out"; }
valid() { jq -e -L "$lib" 'include "node"; (if type == "array" then . else [.] end) | map(validate_node) | length > 0' <<<"$out" >/dev/null 2>&1; }
events() { # <state-dir> <jq-select>: count of matching journal events
  jq -s "map(select($2)) | length" "$1/events.jsonl"
}
host=$(uname -n)
dead_pid() { sh -c 'exit 0' & local p=$!; wait "$p" || true; echo "$p"; }
now() { date +%s; }

S="$repo/.git/delivery"   # the default STATE_DIR for $repo

# --- empty store; STATE_DIR default -------------------------------------------
gl "$repo" -- list
eq "empty store: list prints []" '[]' "$out"
expect "readers create nothing (no STATE_DIR yet)" '[ "$rc" = 0 ] && [ ! -e "$S" ]'

gl "$repo" -- create '{"id":"auth","kind":"epic","title":"Auth","body":"## Context\nlogin"}'
eq "create epic prints its id" 'auth' "$out"
expect "STATE_DIR defaults to <git-common-dir>/delivery with store.json schema 1" \
  '[ "$(jq -c "{schema}" "$S/store.json")" = "{\"schema\":1}" ] && [ -f "$S/epics/auth.json" ]'
expect "the store is never tracked (git status clean)" '[ -z "$(git -C "$repo" status --porcelain)" ]'

# --- GC66: id assignment --------------------------------------------------------
gl "$repo" -- create '{"id":"auth-1","kind":"task","epic":"auth","title":"one","size":"S"}'
gl "$repo" -- create '{"id":"auth-7","kind":"task","epic":"auth","title":"seven"}'
gl "$repo" -- create '{"id":"auth-login","kind":"task","epic":"auth","title":"named"}'
gl "$repo" -- create '{"kind":"task","epic":"auth","title":"next","module":"graph","size":"S","deps":["auth-1"]}'
eq "GC66: create without an id in epic auth holding auth-1, auth-7 -> auth-8" 'auth-8' "$out"
gl "$repo" -- create '{"kind":"task","title":"loose"}'
eq "GC66: a node with no epic lands in the inbox as inbox-1" 'inbox-1' "$out"
expect "GC66: no-epic nodes live in epics/inbox.json" \
  '[ "$(jq -c "[.epic, (.nodes | map(.id))]" "$S/epics/inbox.json")" = "[null,[\"inbox-1\"]]" ]'
gl "$repo" -- create '{"id":"billing","kind":"epic","title":"Billing"}'
gl "$repo" -- create '{"kind":"promote","epic":"billing","title":"promote","promote_to":"main"}'
eq "GC66: the first node of an empty epic is <epic>-1" 'billing-1' "$out"
gl "$repo" -- create '{"id":"inbox-2","kind":"task","epic":"auth","title":"squatter"}'
gl "$repo" -- create '{"kind":"task","title":"loose two"}'
eq "GC66: an assigned id skips one already taken elsewhere in the store" 'inbox-3' "$out"

before=$(cat "$S"/epics/*.json | cksum)
for bad in '{"id":"auth-1","kind":"task","title":"dup"}' \
           '{"id":"inbox","kind":"task","title":"reserved"}' \
           '{"kind":"external","title":"ext"}' \
           '{"kind":"task","epic":"nope","title":"orphan"}' \
           '{"kind":"epic","title":"no id"}' \
           '{"kind":"task","title":"x","created_at":"2026-01-01T00:00:00Z"}' \
           '{"kind":"task","title":"x","size":"XL"}' \
           '{"id":"Bad--Id","kind":"task","title":"x"}' \
           '{"kind":"task"}' \
           'not json'; do
  gl "$repo" -- create "$bad"
  expect "create refuses $bad (exit 1)" '[ "$rc" = 1 ] && [ -n "$err" ]'
done
eq "refused creates leave every epic file unchanged" "$before" "$(cat "$S"/epics/*.json | cksum)"

# --- list / show, through graph.sh (validate_node on every node) ----------------
gl "$repo" -- list
expect "backend list: every node passes validate_node" 'valid'
g "$repo" -- list
expect "graph.sh list (GRAPH_BACKEND=local) exits 0 and validates" '[ "$rc" = 0 ] && valid'
eq "list holds every created node" '10' "$(jq length <<<"$out")"
eq "the local backend never emits kind external" '["epic","promote","task"]' "$(jq -c 'map(.kind) | unique' <<<"$out")"
eq "create fills §4.1 defaults (status ready, target BASE_BRANCH, no claim)" \
  '{"status":"ready","target_branch":"main","claim":null,"needs_human":false,"checklist":[],"pinged_at":null}' \
  "$(node auth-8 '{status, target_branch, claim, needs_human, checklist, pinged_at}')"
eq "create normalizes string deps to {id, via: null}" '[{"id":"auth-1","via":null}]' "$(node auth-8 .deps)"
g "$repo" BASE_BRANCH=release/x -- show inbox-1
expect "graph.sh show: one valid node" '[ "$rc" = 0 ] && valid && [ "$(jq -r .id <<<"$out")" = inbox-1 ]'
g "$repo" -- show auth --format md
eq "graph.sh show --format md renders title + body" "$(printf '# Auth\n\n## Context\nlogin')" "$out"
g "$repo" -- show nope
expect "show of an unknown id exits 1" '[ "$rc" = 1 ]'
g "$repo" -- ready
eq "graph.sh ready over the local store applies ready.jq" \
  '["auth-1","auth-7","auth-login","inbox-1","inbox-2","inbox-3"]' "$(jq -sc 'map(.id) | sort' <<<"$out")"

# --- update / link / flag + journal --------------------------------------------
gl "$repo" -- update auth-8 '{"status":"in-review","title":"next, renamed"}' --actor ann --run r1
expect "update exits 0" '[ "$rc" = 0 ]'
gl "$repo" -- show auth-8
eq "update merges the patch and bumps updated_at" '{"status":"in-review","title":"next, renamed"}' "$(jq -c '{status, title}' <<<"$out")"
eq "update journals a transition with from/to status, actor and run" \
  '{"actor":"ann","run":"r1","op":"transition","id":"auth-8","from":"ready","to":"in-review"}' \
  "$(tail -n 1 "$S/events.jsonl" | jq -c '{actor, run, op, id, from, to}')"
before=$(cat "$S/epics/auth.json" | cksum)
for bad in '{"id":"x"}' '{"epic":"billing"}' '{"pinged_at":"2026-01-01T00:00:00Z"}' '{"status":"bogus"}' '{"claim":{"actor":"a"}}' '[]'; do
  gl "$repo" -- update auth-8 "$bad"
  expect "update refuses $bad (exit 1)" '[ "$rc" = 1 ]'
done
gl "$repo" -- update nope '{"title":"x"}'
expect "update of an unknown id exits 1" '[ "$rc" = 1 ]'
eq "refused updates leave the store unchanged" "$before" "$(cat "$S/epics/auth.json" | cksum)"

n0=$(events "$S" '.op == "link"')
gl "$repo" -- link auth-8 auth-7 'api contract'
gl "$repo" -- link auth-8 auth-7 'api contract'
gl "$repo" -- link auth-8 auth-1
gl "$repo" -- show auth-8
eq "link appends {id, via}; repeating it is a no-op; an existing edge keeps its via" \
  '[{"id":"auth-1","via":null},{"id":"auth-7","via":"api contract"}]' "$(jq -c .deps <<<"$out")"
eq "link journals only the edge it added" "$((n0 + 1))" "$(events "$S" '.op == "link"')"
gl "$repo" -- link auth-8 auth-8
expect "link refuses a self edge" '[ "$rc" = 1 ]'
gl "$repo" -- flag auth-7 needs-human on
gl "$repo" -- show auth-7
eq "flag on sets needs_human" 'true' "$(jq -c .needs_human <<<"$out")"
gl "$repo" -- flag auth-7 needs-human off
gl "$repo" -- show auth-7
eq "flag off clears it" 'false' "$(jq -c .needs_human <<<"$out")"
gl "$repo" -- flag auth-7 needs-human maybe
expect "flag with a bad value is a usage error" '[ "$rc" = 2 ]'
gl "$repo" -- update auth '{"body":"epic body"}'
gl "$repo" -- show auth
eq "update reaches the epic node in its file's epic field" '"epic body"' "$(jq -c .body <<<"$out")"

expect "journal: every line is {ts, actor, run, op, id, from, to, body} with a §6.3 op" \
  'jq -se "all(.[]; (keys == ([\"ts\",\"actor\",\"run\",\"op\",\"id\",\"from\",\"to\",\"body\"] | sort)) and (.op | IN(\"create\",\"claim\",\"release\",\"reclaim\",\"transition\",\"comment\",\"link\",\"apply\",\"lock-broken\")))" "$S/events.jsonl" >/dev/null'
eq "journal: one create event per node" '10' "$(events "$S" '.op == "create"')"

# --- GC23: atomic writes ---------------------------------------------------------
# Eight concurrent writers into one epic: the lock serializes them, every id is
# distinct, and every write lands whole.
pids=""
for i in 1 2 3 4 5 6 7 8; do
  (cd "$repo" && env $ENV_CLEAR LOCK_WAIT_SECONDS=20 bash "$backend" create "{\"kind\":\"task\",\"epic\":\"billing\",\"title\":\"burst $i\"}" \
     > "$tmp/burst.$i" 2>&1) & pids="$pids $!"
done
brc=0; for p in $pids; do wait "$p" || brc=1; done
eq "GC23: 8 concurrent creates all succeed" '0' "$brc"
eq "GC23: they get 8 distinct ids billing-2..billing-9" 'billing-2 billing-3 billing-4 billing-5 billing-6 billing-7 billing-8 billing-9' \
  "$(cat "$tmp"/burst.* | sort -t- -k2n | tr '\n' ' ' | sed 's/ $//')"
expect "GC23: no *.tmp.* files remain anywhere in STATE_DIR" '[ -z "$(find "$S" -name "*.tmp.*")" ]'
expect "GC23: every epic file parses with schema 1" \
  'for f in "$S"/epics/*.json; do jq -e ".schema == 1 and (.nodes | type) == \"array\"" "$f" >/dev/null || exit 1; done'
expect "GC23: no lock is left behind" '[ ! -e "$S/lock" ] && [ ! -e "$S/lock.break" ]'
gl "$repo" -- list
expect "GC23: the store reads back whole and valid (18 nodes)" 'valid && [ "$(jq length <<<"$out")" = 18 ]'

# --- schema guard ----------------------------------------------------------------
cp -R "$S" "$tmp/s-schema"
jq '.schema = 2' "$tmp/s-schema/store.json" > "$tmp/x" && mv "$tmp/x" "$tmp/s-schema/store.json"
gl "$repo" STATE_DIR="$tmp/s-schema" -- list
expect "store.json schema 2 -> refused with expected vs found" '[ "$rc" = 1 ] && grep -q "expected 1, found 2" <<<"$err"'
gl "$repo" STATE_DIR="$tmp/s-schema" -- create '{"kind":"task","title":"x"}'
expect "store.json schema 2 -> writes refused too" '[ "$rc" = 1 ] && grep -q "expected 1, found 2" <<<"$err"'
jq '.schema = 1' "$tmp/s-schema/store.json" > "$tmp/x" && mv "$tmp/x" "$tmp/s-schema/store.json"
jq '.schema = 3' "$tmp/s-schema/epics/auth.json" > "$tmp/x" && mv "$tmp/x" "$tmp/s-schema/epics/auth.json"
gl "$repo" STATE_DIR="$tmp/s-schema" -- list
expect "an epic file with schema 3 -> refused naming the file" '[ "$rc" = 1 ] && grep -q "auth.json: expected 1, found 3" <<<"$err"'

# --- GC44: pinged_at derivation ----------------------------------------------------
P="$tmp/s-ping"
gl "$repo" STATE_DIR="$P" -- create '{"id":"hum-1","kind":"task","title":"human claimed","status":"claimed","claim":{"actor":"ann","run":null,"at":null,"by":"human"}}'
gl "$repo" STATE_DIR="$P" -- create '{"id":"hum-2","kind":"task","title":"never pinged","status":"claimed","claim":{"actor":"bob","run":null,"at":null,"by":"human"}}'
cat "$fx/gc44-events.jsonl" >> "$P/events.jsonl"
g "$repo" STATE_DIR="$P" -- list
expect "GC44: list survives a torn journal line and validates" '[ "$rc" = 0 ] && valid'
eq "GC44: pinged_at = the newest STALE-CLAIM-PING comment event (by ts)" '"2026-10-06T00:00:00Z"' "$(node hum-1 .pinged_at)"
eq "GC44: no comment event with that prefix -> pinged_at null" 'null' "$(node hum-2 .pinged_at)"
g "$repo" STATE_DIR="$P" -- show hum-1
eq "GC44: show derives pinged_at the same way" '"2026-10-06T00:00:00Z"' "$(jq -c .pinged_at <<<"$out")"
gl "$repo" STATE_DIR="$P" -- update hum-1 '{"pinged_at":null}'
expect "GC44: pinged_at is derived, never patched" '[ "$rc" = 1 ]'
expect "GC44: stored nodes carry no pinged_at" '[ "$(jq "[.nodes[] | has(\"pinged_at\")] | any" "$P/epics/inbox.json")" = false ]'

# --- GC22: the lock -----------------------------------------------------------------
# fresh_state <dir>: a store holding one node, `t`.
fresh_state() {
  rm -rf "$1"
  gl "$repo" STATE_DIR="$1" -- create '{"id":"t","kind":"task","title":"lock target"}'
}
plant() { mkdir -p "$1/lock"; [ $# -lt 2 ] || printf '%s\n' "$2" > "$1/lock/owner"; }

# (a) a lock with a dead pid on this host, older than LOCK_STALE_SECONDS: broken.
L="$tmp/s-a"; fresh_state "$L"
stale="$host $(dead_pid) dead-run $(( $(now) - 1000 ))"
plant "$L" "$stale"
gl "$repo" STATE_DIR="$L" LOCK_WAIT_SECONDS=5 -- update t '{"title":"after break"}'
expect "GC22(a): the write succeeds after breaking the stale lock" '[ "$rc" = 0 ]'
eq "GC22(a): exactly one lock-broken event, naming the judged owner line" "1" \
  "$(events "$L" '.op == "lock-broken" and .from == "'"$stale"'"')"
expect "GC22(a): the write landed and no lock remains" \
  '[ ! -e "$L/lock" ] && [ ! -e "$L/lock.break" ] && [ "$(jq -r ".nodes[0].title" "$L/epics/inbox.json")" = "after break" ]'

# Not stale unless every condition holds: each is a live lock -> exit 75.
for case in "young:$host $(dead_pid) r $(now)" \
            "other host:not-$host $(dead_pid) r $(( $(now) - 1000 ))" \
            "EPERM or live pid 1:$host 1 r $(( $(now) - 1000 ))" \
            "malformed owner:garbage"; do
  name="${case%%:*}" line="${case#*:}"
  L="$tmp/s-live"; fresh_state "$L"; plant "$L" "$line"
  gl "$repo" STATE_DIR="$L" LOCK_WAIT_SECONDS=0 -- update t '{"title":"x"}'
  expect "GC22(a): $name lock is live -> exit 75, lock kept, nothing broken" \
    '[ "$rc" = 75 ] && [ "$(cat "$L/lock/owner")" = "$line" ] && [ "$(events "$L" ".op == \"lock-broken\"")" = 0 ]'
done
L="$tmp/s-age"; fresh_state "$L"
line="$host $(dead_pid) r $(( $(now) - 100 ))"; plant "$L" "$line"
gl "$repo" STATE_DIR="$L" LOCK_STALE_SECONDS=300 LOCK_WAIT_SECONDS=0 -- update t '{"title":"x"}'
expect "GC22(a): staleness uses LOCK_STALE_SECONDS against the owner epoch (100s < 300s: live)" '[ "$rc" = 75 ]'
gl "$repo" STATE_DIR="$L" LOCK_STALE_SECONDS=50 LOCK_WAIT_SECONDS=1 -- update t '{"title":"x"}'
expect "GC22(a): ... and 100s > 50s: broken" '[ "$rc" = 0 ] && [ "$(events "$L" ".op == \"lock-broken\"")" = 1 ]'

# (b) a live lock and LOCK_WAIT_SECONDS=2: exit 75 after the wait.
L="$tmp/s-b"; fresh_state "$L"
line="$host $$ live-run $(now)"; plant "$L" "$line"
t0=$(now)
gl "$repo" STATE_DIR="$L" LOCK_WAIT_SECONDS=2 -- update t '{"title":"x"}'
dt=$(( $(now) - t0 ))
expect "GC22(b): live lock + LOCK_WAIT_SECONDS=2 -> exit 75 after waiting (${dt}s)" \
  '[ "$rc" = 75 ] && [ "$dt" -ge 1 ] && [ "$dt" -le 6 ] && grep -q LOCK_WAIT_SECONDS <<<"$err"'
expect "GC22(b): the holder's lock is untouched and the store unchanged" \
  '[ "$(cat "$L/lock/owner")" = "$line" ] && [ "$(jq -r ".nodes[0].title" "$L/epics/inbox.json")" = "lock target" ]'

# (d) a lock dir with no owner (a holder between mkdir and the owner write): live.
L="$tmp/s-d"; fresh_state "$L"; plant "$L"
gl "$repo" STATE_DIR="$L" LOCK_STALE_SECONDS=0 LOCK_WAIT_SECONDS=0 -- update t '{"title":"x"}'
expect "GC22(d): owner-less lock is treated as live -> exit 75, not broken" \
  '[ "$rc" = 75 ] && [ -d "$L/lock" ] && [ ! -e "$L/lock/owner" ] && [ "$(events "$L" ".op == \"lock-broken\"")" = 0 ]'
gl "$repo" STATE_DIR="$L" -- unlock --force
gl "$repo" STATE_DIR="$L" LOCK_WAIT_SECONDS=0 -- update t '{"title":"x"}'
expect "operator unlock --force clears it; the next write succeeds" '[ "$rc" = 0 ]'

# A stale lock.break (a breaker that died mid-break) is reaped, then the lock broken.
L="$tmp/s-reap"; fresh_state "$L"
stale="$host $(dead_pid) dead-lock $(( $(now) - 1000 ))"; plant "$L" "$stale"
mkdir "$L/lock.break"; printf '%s\n' "$host $(dead_pid) dead-breaker $(( $(now) - 1000 ))" > "$L/lock.break/owner"
gl "$repo" STATE_DIR="$L" LOCK_WAIT_SECONDS=5 -- update t '{"title":"x"}'
expect "GC22: a stale lock.break is reaped (lock.break.reap) and the stale lock broken once" \
  '[ "$rc" = 0 ] && [ ! -e "$L/lock.break" ] && [ ! -e "$L/lock.break.reap" ] && [ "$(events "$L" ".op == \"lock-broken\"")" = 1 ]'

# (c) two concurrent breakers of one stale lock, plus a third process that acquires
# in between. b2 judges the lock stale, then is held inside its break until c has
# acquired; b1 breaks meanwhile. b2's re-check must see c's owner line, not the one
# it judged, and leave c's lock alone.
L="$tmp/s-c"; fresh_state "$L"
stale="$host $(dead_pid) dead-run $(( $(now) - 1000 ))"; plant "$L" "$stale"
sync="$tmp/sync-c"; mkdir -p "$sync"
race() { # <role>
  (cd "$repo" && env $ENV_CLEAR STATE_DIR="$L" LOCK_WAIT_SECONDS=15 STALE_LINE="$stale" \
     bash "$fx/lock-race.sh" "$1" "$sync" > "$sync/$1.log" 2>&1)
}
race b2 & p_b2=$!
i=0; while [ ! -e "$sync/b2-judged" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
expect "GC22(c): breaker b2 judged the lock stale and is paused before breaking" '[ -e "$sync/b2-judged" ] && [ -d "$L/lock" ]'
race b1 & p_b1=$!
race c & p_c=$!
crc=0
wait "$p_b1" || crc=1; wait "$p_c" || crc=1; wait "$p_b2" || crc=1
expect "GC22(c): all three processes finish with exit 0" '[ "$crc" = 0 ]'
[ "$crc" = 0 ] || cat "$sync"/*.log >&2
eq "GC22(c): exactly one lock-broken event" '1' "$(events "$L" '.op == "lock-broken"')"
eq "GC22(c): the third process's lock survived b2's outdated break" 'intact' "$(cat "$sync/c-result" 2>/dev/null || echo missing)"
expect "GC22(c): no lock, lock.break or tmp file left" '[ ! -e "$L/lock" ] && [ ! -e "$L/lock.break" ] && [ -z "$(find "$L" -name "*.tmp.*")" ]'

# Stress: six unsynchronized breakers of one stale lock: one break, all succeed.
L="$tmp/s-many"; fresh_state "$L"
stale="$host $(dead_pid) dead-run $(( $(now) - 1000 ))"; plant "$L" "$stale"
pids=""
for i in 1 2 3 4 5 6; do
  (cd "$repo" && env $ENV_CLEAR STATE_DIR="$L" LOCK_WAIT_SECONDS=15 bash "$fx/lock-race.sh" n "$tmp" >/dev/null 2>&1) & pids="$pids $!"
done
mrc=0; for p in $pids; do wait "$p" || mrc=1; done
expect "GC22: six concurrent breakers all acquire in turn" '[ "$mrc" = 0 ] && [ ! -e "$L/lock" ]'
eq "GC22: ... with exactly one lock-broken event" '1' "$(events "$L" '.op == "lock-broken"')"

# --- GC27: two worktrees, one STATE_DIR -------------------------------------------
wt="$tmp/wt-b"
git -C "$repo" worktree add -q --detach "$wt"
claim='{"status":"claimed","claim":{"actor":"agent-1","run":"run-1","at":"2026-11-08T00:00:00Z","by":"agent"}}'
gl "$repo" -- update auth-1 "$claim" --actor agent-1 --run run-1
expect "GC27: claim (as an update) from worktree A succeeds" '[ "$rc" = 0 ]'
g "$wt" -- show auth-1
eq "GC27: the claim is visible from worktree B" \
  '{"status":"claimed","claim":{"actor":"agent-1","run":"run-1","at":"2026-11-08T00:00:00Z","by":"agent"}}' \
  "$(jq -c '{status, claim}' <<<"$out")"
gl "$wt" -- create '{"kind":"task","epic":"auth","title":"from B"}'
id_b="$out"
g "$repo" -- show "$id_b"
expect "GC27: a node created from worktree B is visible from A" '[ "$rc" = 0 ] && [ "$(jq -r .title <<<"$out")" = "from B" ]'
expect "GC27: both worktrees resolve the same STATE_DIR and neither tracks it" \
  '[ "$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir)/delivery" = "$S" ] && [ -z "$(git -C "$wt" status --porcelain)" ] && [ -z "$(git -C "$repo" status --porcelain)" ]'

if [ "$fails" -ne 0 ]; then echo "graph-local-test: FAILED" >&2; exit 1; fi
echo "graph-local-test: all passed"
