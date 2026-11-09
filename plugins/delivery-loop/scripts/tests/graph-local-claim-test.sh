#!/usr/bin/env bash
# Tests for the local backend's claim/release/comment/reconcile and the graph.sh
# routing over it (docs/delivery_graph_spec.md §5, §6.1, §6.3): golden cases
# GC21 (8 concurrent claims, one winner), GC24 (the `reclaim` event), GC25 (a
# merged PR on the forge -> done, its dependent -> ready, end to end) — §17 row
# C2 — plus GC66 through `graph.sh create`, the routed writes, human claims,
# stale-claim pings, the reconcile compare-and-set, and `graph.sh show`'s
# journal tail.
#
# Runs in a throwaway git repo under ${TMPDIR:-/tmp}, so the host repo's
# .claude/delivery.conf never leaks in. The forge is FORGE=github behind the
# merged forge-github gh shim (fixtures/forge-github/gh-shim.sh), answering from
# fixtures/graph-local-claim/. Staleness is set up by back-dating a node's
# timestamps in its epic file (the store stamps them; nothing else can).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backend="$here/../backends/graph-local.sh"
graph="$here/../graph.sh"
lib="$here/../lib"
fx="$here/fixtures/graph-local-claim"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-local-claim-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
git init -q "$repo"
mkdir -p "$tmp/bin" "$tmp/shim"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$here/fixtures/forge-github/gh-shim.sh" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

ENV_CLEAR="-u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u BASE_BRANCH -u LIST_LIMIT
  -u LOCK_STALE_SECONDS -u LOCK_WAIT_SECONDS -u GITLAB_TOKEN -u GITEA_TOKEN -u GH_TOKEN -u GH_REPO -u GH_HOST"

# g <state-dir> [VAR=value …] -- <graph.sh args…>: sets $rc, $out, $err; the gh
# shim log ($tmp/shim/log) is reset. gl: the same, straight to the backend.
_run() {
  local script="$1" st="$2" envs=""; shift 2
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  : > "$tmp/shim/log"
  # shellcheck disable=SC2086
  (cd "$repo" && env $ENV_CLEAR GRAPH_BACKEND=local FORGE=github BASE_BRANCH=main \
     STATE_DIR="$st" PATH="$tmp/bin:$PATH" SHIM_FX="$fx" SHIM_STATE="$tmp/shim" $envs \
     bash "$script" "$@" > "$tmp/out" 2> "$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
g()  { _run "$graph" "$@"; }
gl() { _run "$backend" "$@"; }

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
events() { jq -s "map(select($2)) | length" "$1/events.jsonl"; }   # <state> <jq-select>
last_event() { tail -n 1 "$1/events.jsonl" | jq -c "${2:-.}"; }
# field <state> <id> <jq>: a field of node <id>, read back through graph.sh show.
field() { g "$1" -- show "$2"; jq -c "$3" <<<"$out"; }
# backdate <state> <id> <created_at> <updated_at>: test setup only.
backdate() {
  local f
  for f in "$1"/epics/*.json; do
    jq --arg id "$2" --arg c "$3" --arg u "$4" '
      def bd: if .id == $id then .created_at = $c | .updated_at = $u else . end;
      (if .epic != null then .epic |= bd else . end) | .nodes |= map(bd)' "$f" > "$f.new"
    mv "$f.new" "$f"
  done
}
epoch_iso() { jq -nr --argjson s "$1" '$s | todate'; }
ago() { epoch_iso $(( $(date -u +%s) - $1 )); }

# --- routing: create/update/link/flag go to the backend (GC66 via graph.sh) -----
R="$tmp/route"
g "$R" -- create '{"id":"auth","kind":"epic","title":"Auth"}'
g "$R" -- create '{"id":"auth-1","kind":"task","epic":"auth","title":"one","size":"S"}'
g "$R" -- create '{"id":"auth-7","kind":"task","epic":"auth","title":"seven","size":"S"}'
g "$R" -- create '{"kind":"task","epic":"auth","title":"next","size":"S"}'
eq "GC66 via graph.sh create: no id in epic auth holding auth-1, auth-7 -> auth-8" 'auth-8' "$out"
printf '%s' '{"kind":"task","epic":"auth","title":"from stdin","size":"S"}' > "$tmp/node.json"
(cd "$repo" && env $ENV_CLEAR GRAPH_BACKEND=local STATE_DIR="$R" bash "$graph" create - < "$tmp/node.json" > "$tmp/out") && rc=0 || rc=$?
eq "graph.sh create - reads the node from stdin" 'auth-9' "$(cat "$tmp/out")"
g "$R" -- update auth-8 '{"module":"graph"}'
expect "graph.sh update routes to the backend" '[ "$rc" = 0 ] && [ "$(field "$R" auth-8 .module)" = "\"graph\"" ]'
g "$R" -- link auth-8 auth-1 plan
expect "graph.sh link routes to the backend" \
  '[ "$rc" = 0 ] && [ "$(field "$R" auth-8 .deps)" = "[{\"id\":\"auth-1\",\"via\":\"plan\"}]" ]'
g "$R" -- flag auth-7 needs-human on
expect "graph.sh flag routes to the backend" '[ "$rc" = 0 ] && [ "$(field "$R" auth-7 .needs_human)" = true ]'
g "$R" -- update nope '{"title":"x"}'
eq "a routed write passes the backend's exit status through (unknown node -> 1)" 1 "$rc"
g "$R" -- flag auth-7 needs-human maybe
eq "a routed write passes the backend's usage exit through (2)" 2 "$rc"
for bad in "claim" "claim auth-1" "claim auth-1 a --run" "claim auth-1 a extra" "claim auth-1 --human" \
           "claim --human ann" "reconcile --dry" "reconcile --fix x" "bogus"; do
  # shellcheck disable=SC2086
  g "$R" -- $bad
  eq "graph.sh $bad -> usage (exit 2)" 2 "$rc"
done

# --- claim: policy pre-check, atomic set, human claims --------------------------
g "$R" -- claim auth-1 agent-a --run run-1
expect "graph.sh claim of a ready node exits 0" '[ "$rc" = 0 ]'
eq "the claim is set: claimed, by agent, actor and run recorded" \
  '{"status":"claimed","actor":"agent-a","run":"run-1","by":"agent"}' \
  "$(field "$R" auth-1 '{status, actor: .claim.actor, run: .claim.run, by: .claim.by}')"
eq "a claim event is journaled (actor = claimant, run, ready -> claimed)" \
  '{"actor":"agent-a","run":"run-1","op":"claim","id":"auth-1","from":"ready","to":"claimed","body":"agent"}' \
  "$(last_event "$R" '{actor, run, op, id, from, to, body}')"
before=$(cat "$R"/epics/*.json "$R/events.jsonl" | cksum)
g "$R" -- claim auth-1 agent-b
expect "claiming a claimed node exits 1 (not claimable), naming why" \
  '[ "$rc" = 1 ] && case "$err" in *"not claimable"*) true ;; *) false ;; esac'
g "$R" -- claim auth-7 agent-b
expect "an agent never claims a needs_human node (exit 1)" \
  '[ "$rc" = 1 ] && case "$err" in *needs-human*) true ;; *) false ;; esac'
g "$R" -- claim nope agent-b
eq "claiming an unknown node exits 1" 1 "$rc"
g "$R" -- update auth-9 '{"status":"blocked"}'
before=$(cat "$R"/epics/*.json "$R/events.jsonl" | cksum)
g "$R" -- claim auth-9 agent-b
eq "claiming a blocked node exits 1 (the transition table refuses)" 1 "$rc"
eq "refused claims write nothing" "$before" "$(cat "$R"/epics/*.json "$R/events.jsonl" | cksum)"
gl "$R" -- claim auth-1 agent-b run-2
eq "the backend's own test-and-set refuses a claimed node (exit 1)" 1 "$rc"
eq "... and writes nothing" "$before" "$(cat "$R"/epics/*.json "$R/events.jsonl" | cksum)"
gl "$R" -- claim auth-8 agent-b -
eq "the backend refuses an agent claim with no run (usage)" 2 "$rc"

g "$R" -- claim auth-7 --human ann
expect "a human claims a node (needs_human does not stop a human)" '[ "$rc" = 0 ]'
eq "a human claim: by human, no run" '{"status":"claimed","claim":{"actor":"ann","run":null,"by":"human"}}' \
  "$(field "$R" auth-7 '{status, claim: (.claim | {actor, run, by})}')"

g "$R" -- claim auth-8 agent-c
run_default=$(field "$R" auth-8 .claim.run)
expect "an agent claim without --run gets <host>-<pid>-<epoch>" \
  'case "$run_default" in "\"$(uname -n)-"*) true ;; *) false ;; esac'

# --- release / comment -----------------------------------------------------------
g "$R" -- release auth-1 "gate is red" --actor agent-a
expect "graph.sh release exits 0" '[ "$rc" = 0 ]'
eq "release clears the claim and returns a claimed node to ready" '{"status":"ready","claim":null}' \
  "$(field "$R" auth-1 '{status, claim}')"
eq "release journals {release, claimed -> ready, reason}" \
  '{"actor":"agent-a","op":"release","from":"claimed","to":"ready","body":"gate is red"}' \
  "$(last_event "$R" '{actor, op, from, to, body}')"
n=$(wc -l < "$R/events.jsonl")
g "$R" -- release auth-1 "again"
expect "releasing an unclaimed node is a no-op (exit 0, no event)" '[ "$rc" = 0 ] && [ "$(wc -l < "$R/events.jsonl")" = "$n" ]'
g "$R" -- release auth-7 "handing back"
eq "release keeps needs_human set" '{"status":"ready","needs_human":true,"claim":null}' \
  "$(field "$R" auth-7 '{status, needs_human, claim}')"
g "$R" -- comment auth-1 "a durable note" --actor ann
expect "graph.sh comment exits 0 and journals a comment event" \
  '[ "$rc" = 0 ] && [ "$(last_event "$R" "{op, id, body, actor}")" = "{\"op\":\"comment\",\"id\":\"auth-1\",\"body\":\"a durable note\",\"actor\":\"ann\"}" ]'
before=$(cat "$R"/epics/*.json | cksum)
printf 'multi\nline' | (cd "$repo" && env $ENV_CLEAR GRAPH_BACKEND=local STATE_DIR="$R" bash "$graph" comment auth-1 - > /dev/null) && rc=0 || rc=$?
expect "comment - reads the text from stdin" '[ "$rc" = 0 ] && [ "$(last_event "$R" .body)" = "\"multi\\nline\"" ]'
eq "a comment never touches the node files" "$before" "$(cat "$R"/epics/*.json | cksum)"
g "$R" -- comment nope "x"
eq "commenting on an unknown node exits 1" 1 "$rc"

# --- graph.sh show: the node's last 10 journal events (§6.3) ---------------------
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do g "$R" -- comment auth-8 "note $i"; done
g "$R" -- show auth-8
expect "show: stdout is still exactly one valid node" \
  '[ "$rc" = 0 ] && jq -e -s -L "$lib" "include \"node\"; length == 1 and (.[0] | validate_node | .id == \"auth-8\")" <<<"$out" > /dev/null'
eq "show: stderr carries exactly the last 10 journal events of the node" \
  '["note 3","note 4","note 5","note 6","note 7","note 8","note 9","note 10","note 11","note 12"]' \
  "$(jq -sc 'map(.body)' <<<"$err")"
g "$R" -- show auth-9
eq "show: a node with fewer events prints all of its own (and no other node's)" \
  '[["create","auth-9"],["transition","auth-9"]]' "$(jq -sc 'map([.op, .id])' <<<"$err")"
g "$R" -- show auth-9 --format md
expect "show --format md: the same tail on stderr, the markdown on stdout" \
  '[ "$(jq -s length <<<"$err")" = 2 ] && [ "$out" = "# from stdin" ]'

# --- GC21: 8 concurrent graph.sh claim X -> exactly one winner --------------------
C="$tmp/race"
g "$C" -- create '{"id":"x","kind":"task","title":"contended","size":"S"}'
pids=""
for i in 1 2 3 4 5 6 7 8; do
  (cd "$repo" && env $ENV_CLEAR GRAPH_BACKEND=local STATE_DIR="$C" \
     bash "$graph" claim x "agent-$i" --run "run-$i" > /dev/null 2> "$tmp/race-$i.err" && r=0 || r=$?
   echo "$r" > "$tmp/race-$i.rc") &
  pids="$pids $!"
done
# shellcheck disable=SC2086
wait $pids
codes=$(cat "$tmp"/race-*.rc | sort | tr '\n' ' ')
eq "GC21: 8 concurrent claims -> exactly one exit 0, seven exit 1" "0 1 1 1 1 1 1 1 " "$codes"
eq "GC21: exactly one claim event" 1 "$(events "$C" '.op == "claim"')"
winner=$(for i in 1 2 3 4 5 6 7 8; do if [ "$(cat "$tmp/race-$i.rc")" = 0 ]; then echo "agent-$i"; fi; done)
eq "GC21: the stored claim is the winner's" "\"$winner\"" "$(field "$C" x .claim.actor)"
expect "GC21: no lock or tmp file is left behind" \
  '[ ! -e "$C/lock" ] && [ -z "$(find "$C" -name "*.tmp.*")" ]'

# --- GC24: a stale agent claim, no PR -> reclaim (node ready + reclaim event) ------
# Only PR 302 (Delivery-Task: z, open) is on the forge; y has none.
A="$tmp/stale"
g "$A" -- create '{"id":"y","kind":"task","title":"idle claim","size":"S"}'
g "$A" -- create '{"id":"z","kind":"task","title":"claim with a PR","size":"S"}'
g "$A" -- create '{"id":"h","kind":"task","title":"human claim","size":"S"}'
g "$A" -- claim y agent-y --run run-y
g "$A" -- claim z agent-z --run run-z
g "$A" -- claim h --human ann
backdate "$A" y "$(ago 90000)" "$(ago 18000)"     # claim idle 5h
backdate "$A" z "$(ago 90000)" "$(ago 18000)"
backdate "$A" h "$(ago 300000)" "$(ago 262800)"   # human claim idle 73h
before=$(cat "$A"/epics/*.json "$A/events.jsonl" | cksum)
g "$A" -- reconcile
expect "reconcile without --fix prints the records and writes nothing" \
  '[ "$rc" = 0 ] && [ "$before" = "$(cat "$A"/epics/*.json "$A/events.jsonl" | cksum)" ]'
eq "reconcile (dry run), in rule order: z -> in-review (its open PR, rule 4), reclaim y (5), ping h (6)" \
  '[["transition","z","claimed","in-review"],["reclaim","y","claimed","ready"],["ping","h","claimed","claimed"]]' \
  "$(jq -sc 'map([.op, .id, .from, .to])' <<<"$out")"
g "$A" -- reconcile --fix
expect "GC24: reconcile --fix exits 0" '[ "$rc" = 0 ]'
expect "GC24: --fix prints a fix: line per applied record" \
  '[ "$(grep -c "^fix: " <<<"$out")" = 3 ] && grep -qF "fix: reclaim y claimed -> ready: RECLAIMED" <<<"$out"'
eq "GC24: local: the reclaimed node is ready with no claim" '{"status":"ready","claim":null}' \
  "$(field "$A" y '{status, claim}')"
eq "GC24: local: one reclaim event, with the RECLAIMED reason" \
  '[{"op":"reclaim","id":"y","from":"claimed","to":"ready","reclaimed":true}]' \
  "$(jq -sc 'map(select(.op == "reclaim") | {op, id, from, to, reclaimed: (.body | startswith("RECLAIMED:"))})' "$A/events.jsonl")"
eq "GC43 locally: a claimed node with an open agent PR goes in-review" '"in-review"' "$(field "$A" z .status)"
eq "GC44 locally: the stale human claim is pinged once (pinged_at derives), never released" \
  '{"status":"claimed","by":"human","pinged":true}' \
  "$(field "$A" h '{status, by: .claim.by, pinged: (.pinged_at != null)}')"
g "$A" -- reconcile
eq "a second reconcile has nothing left to fix (no second ping)" '' "$out"

# The compare-and-set: a record whose node moved since the plan is refused.
g "$A" -- show y
stamp=$(jq -r .updated_at <<<"$out")
gl "$A" -- reconcile "{\"op\":\"transition\",\"id\":\"y\",\"from\":\"ready\",\"to\":\"blocked\",\"reason\":\"a dep is not done\",\"updated_at\":\"2020-01-01T00:00:00Z\"}"
eq "a record with a stale updated_at exits 4" 4 "$rc"
gl "$A" -- reconcile "{\"op\":\"transition\",\"id\":\"y\",\"from\":\"claimed\",\"to\":\"ready\",\"reason\":\"x\",\"updated_at\":\"$stamp\"}"
eq "a record with a stale from status exits 4" 4 "$rc"
gl "$A" -- reconcile "{\"op\":\"reclaim\",\"id\":\"y\",\"from\":\"ready\",\"to\":\"ready\",\"reason\":\"x\",\"updated_at\":\"$stamp\"}"
eq "a reclaim of a node with no agent claim exits 4" 4 "$rc"
before=$(cat "$A"/epics/*.json "$A/events.jsonl" | cksum)
for bad in '{"op":"close","id":"y","from":"ready","to":"done","reason":"x","updated_at":"x"}' \
           '{"op":"ping","id":"y","from":"ready","to":"done","reason":"x","updated_at":"x"}' \
           '{"op":"transition","id":"y","from":"ready","to":"done","reason":"x"}' \
           '{"op":"transition","id":"Y Y","from":"ready","to":"done","reason":"x","updated_at":"x"}' \
           '{"op":"transition","id":"y","from":"ready","to":"done","reason":"x","updated_at":"x","extra":1}' \
           '[]'; do
  gl "$A" -- reconcile "$bad"
  eq "reconcile refuses the malformed record $bad (exit 1)" 1 "$rc"
done
gl "$A" -- reconcile "{\"op\":\"transition\",\"id\":\"y\",\"from\":\"ready\",\"to\":\"bogus\",\"reason\":\"x\",\"updated_at\":\"$stamp\"}"
eq "reconcile refuses a record whose result fails validate_node (exit 1)" 1 "$rc"
eq "refused records write nothing" "$before" "$(cat "$A"/epics/*.json "$A/events.jsonl" | cksum)"

# --- GC25: a merged PR (Delivery-Task: x) -> x done; its dependent -> ready ------
# PR 301 is merged into main with Delivery-Task: x; PR 300 is merged into
# main with Delivery-Task: w, but before the oldest open node existed.
M="$tmp/merged"
g "$M" -- create '{"id":"x","kind":"task","title":"shipped","size":"S","status":"in-review"}'
g "$M" -- create '{"id":"dep","kind":"task","title":"waits on x","size":"S","status":"blocked","deps":["x"]}'
g "$M" -- create '{"id":"w","kind":"task","title":"old PR","size":"S"}'
backdate "$M" x "2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z"
backdate "$M" dep "2026-01-01T01:00:00Z" "2026-01-01T01:00:00Z"
backdate "$M" w "2026-01-01T02:00:00Z" "2026-01-01T02:00:00Z"
g "$M" -- reconcile --fix
expect "GC25: reconcile --fix exits 0" '[ "$rc" = 0 ]'
expect "GC25: the merged read asks the forge for PRs merged since the oldest open node" \
  'grep -qF "gh pr list --state merged --search merged:>=2026-01-01T00:00:00Z" "$tmp/shim/log"'
expect "GC25: and the open read" 'grep -qF "gh pr list --state open" "$tmp/shim/log"'
eq "GC25: fix lines: x done (PR #301), then dep ready, in one pass" \
  "$(printf 'fix: transition x in-review -> done: PR #301 merged into main\nfix: transition dep blocked -> ready: every dep is done')" \
  "$out"
g "$M" -- list
eq "GC25: x is done, dep is ready, w (merged before the window) untouched" \
  '{"dep":"ready","w":"ready","x":"done"}' "$(jq -cS 'map({(.id): .status}) | add' <<<"$out")"
eq "GC25: both moves are journaled as transitions with the reason" \
  '[["x","in-review","done","PR #301 merged into main"],["dep","blocked","ready","every dep is done"]]' \
  "$(jq -sc 'map(select(.op == "transition") | [.id, .from, .to, .body])' "$M/events.jsonl")"
g "$M" -- ready
eq "GC25: dep is now in the ready set" '["dep","w"]' "$(jq -sc 'map(.id) | sort' <<<"$out")"

# A forge failure stops reconcile before anything is written.
before=$(cat "$M"/epics/*.json "$M/events.jsonl" | cksum)
g "$M" FORGE=gitlab -- reconcile --fix
eq "an invalid config exits 1 before any I/O" 1 "$rc"
g "$M" SHIM_FX="$tmp/nowhere" -- reconcile --fix
expect "a failing forge read exits nonzero and writes nothing" \
  '[ "$rc" != 0 ] && [ "$before" = "$(cat "$M"/epics/*.json "$M/events.jsonl" | cksum)" ]'

if [ "$fails" -ne 0 ]; then
  echo "graph-local-claim tests FAILED" >&2
  exit 1
fi
echo "graph-local-claim tests passed"
