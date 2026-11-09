#!/usr/bin/env bash
# Tests for the github write path (docs/delivery_graph_spec.md §5, §6.1, §6.2;
# §17 row B2): backends/graph-github.sh create/update/link/flag/claim/release/
# comment/reconcile, `graph.sh transition`/`claim`/`reconcile --fix`, and the
# task-queue.sh / claim-task.sh compatibility wrappers. Golden cases GC33 (the
# reaper), GC42 (the issue is closed), GC61 (task-queue.sh byte-identical to
# v0.1.4), GC68 (external nodes), GC71 (task+epic is a task) and GC75 (a keyword
# close survives a reopen); plus the H0 bootstrap (close-on-merge into a
# non-default BASE_BRANCH, once per (issue, PR)), the reconcile compare-and-set
# on updatedAt, exit 4/75 handling, and comments past gh's 100-per-issue cap.
#
# Offline: a recording, stateful gh shim (fixtures/graph-github-write/gh-shim.sh)
# sits first on PATH; writes mutate its board, so a later read sees them. The
# v0.1.4 outputs it compares against were captured from v0.1.4's task-queue.sh
# run against the same shim and boards (fixtures/ready/gc5-v014.jsonl,
# fixtures/graph-github-write/parity-v014*.jsonl). Runs in a throwaway git repo
# so the host repo's .claude/delivery.conf never leaks in.
#
# bash 3.2: no jq filter containing `{a, b}` goes inside an `expect` (eval)
# string, where 3.2 brace-expands it; compute such values first, then `eq`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
graph="$scripts/graph.sh"
backend="$scripts/backends/graph-github.sh"
fx="$here/fixtures/graph-github-write"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-github-write-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/gh-shim.sh" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
st="$tmp/state"

# load <board.json> [prs.json]: a fresh shim state.
load() {
  rm -rf "$st"; mkdir -p "$st"
  cp "$1" "$st/board.json"
  if [ -n "${2:-}" ]; then cp "$2" "$st/prs.json"; else echo '[]' > "$st/prs.json"; fi
  : > "$st/log"
}

# run [VAR=value …] -- <script> <args…>: sets $rc, $out, $err. The shim state
# (board, log) persists across runs until the next `load`.
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  # shellcheck disable=SC2086
  (cd "$tmp" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REPO -u GH_HOST \
     -u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u LIST_LIMIT -u BASE_BRANCH \
     -u GITLAB_TOKEN -u GITEA_TOKEN -u STATE_DIR -u LOCK_WAIT_SECONDS -u SHIM_GH_VERSION \
     -u CLAIM_GRACE_SECONDS \
     PATH="$tmp/bin:$PATH" SHIM_STATE="$st" $envs \
     bash "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
g() { local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift; run ${e[@]+"${e[@]}"} -- "$graph" "$@"; }

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
log_has()   { grep -qF -- "$1" "$st/log"; }
log_count() { grep -cF -- "$1" "$st/log" || true; }
# issue <n> <jq>: a field expression over issue <n> of the shim board.
issue() { jq -c --argjson n "$1" ".[] | select(.number == \$n) | $2" "$st/board.json"; }
labels() { issue "$1" '[.labels[].name] | sort'; }
bodies() { issue "$1" '[.comments[].body]'; }
# node <id> <jq>: over the last `list` output.
node() { jq -c --arg id "$1" ".[] | select(.id == \$id) | $2" <<<"$out"; }

# Board builders (jq): issue($n; $title; $labels; $body), pr(...).
B='def L($n): {id: "LA_\($n)", name: $n, description: "", color: "EDEDED"};
   def c($b; $t): {author: {login: "x"}, authorAssociation: "OWNER", body: $b, createdAt: $t};
   def i($n; $t; $labels; $body): {number: $n, title: $t, state: "OPEN", stateReason: "",
     labels: [$labels[] | L(.)], assignees: [], body: $body,
     createdAt: ("2026-01-01T00:00:00Z" | fromdate + $n | todate), updatedAt: "2026-01-02T00:00:00Z",
     comments: [], blockedBy: {nodes: [], totalCount: 0}, parent: null,
     closedByPullRequestsReferences: []};
   def closed($r): .state = "CLOSED" | .stateReason = $r;'
board() { jq -n "$B $1" > "$2"; }
prs() { jq -n -L "$fx" "include \"pr\"; $1" > "$2"; }

# --- GC61: task-queue.sh is byte-identical to v0.1.4 --------------------------------
load "$here/fixtures/graph-github/gc5-issues.json"
run -- "$scripts/task-queue.sh"
eq "GC61: task-queue.sh over the GC5 github fixture is byte-identical to v0.1.4" \
  "$(cat "$here/fixtures/ready/gc5-v014.jsonl")" "$out"
eq "GC61: exit 0, nothing on stderr" "0:" "$rc:$err"
load "$here/fixtures/graph-github/gc5-issues.json"
run -- "$scripts/task-queue.sh" --fix
eq "GC61: task-queue.sh --fix over the GC5 fixture: same stdout" \
  "$(cat "$here/fixtures/ready/gc5-v014.jsonl")" "$out"
expect "every gh pr list carries an explicit --limit (GC33: v0.1.4's default 30 blinded the reaper)" \
  '[ "$(log_count "gh pr list")" -gt 0 ] && ! grep "gh pr list" "$st/log" | grep -qv -- "--limit"'

# The parity board exercises every --fix rule v0.1.4 had: a merged PR into a
# non-default BASE_BRANCH (H0), blocked <-> ready, a stale agent claim, a stale
# human claim, an epic whose children are all closed.
load "$fx/parity-board.json" "$fx/parity-prs.json"
run BASE_BRANCH=release/x -- "$scripts/task-queue.sh"
eq "GC61: parity board, no --fix: stdout byte-identical to v0.1.4" "$(cat "$fx/parity-v014-nofix.jsonl")" "$out"
run BASE_BRANCH=release/x -- "$scripts/task-queue.sh" --fix
eq "GC61: parity board --fix: stdout byte-identical to v0.1.4" "$(cat "$fx/parity-v014.jsonl")" "$out"
eq "--fix: exit 0" 0 "$rc"
expect "--fix: fix lines go to stderr, as v0.1.4's did" \
  'grep -q "^fix: transition 4 blocked -> ready" <<<"$err" && ! grep -q "^fix:" <<<"$out"'
eq "H0: the task whose PR merged into BASE_BRANCH is closed completed" '["CLOSED","COMPLETED"]' "$(issue 3 '[.state, .stateReason]')"
eq "H0: with the AUTO-CLOSE: PR #<n> marker" \
  '["AUTO-CLOSE: PR #101 merged into release/x. (Reconciled by graph.sh reconcile --fix.)"]' "$(bodies 3)"
expect "H0: the close precedes its marker (a crash leaves no marker on an open issue)" \
  '[ "$(grep -n "gh issue close 3 --reason completed" "$st/log" | cut -d: -f1)" -lt "$(grep -n "gh issue comment 3 " "$st/log" | cut -d: -f1)" ]'
eq "epic: every child closed -> closed completed" '"CLOSED"' "$(issue 1 .state)"
eq "epic: its AUTO-CLOSE comment names no PR" '["AUTO-CLOSE: epic fully delivered: all 2 children are done or cancelled. (Reconciled by graph.sh reconcile --fix.)"]' "$(bodies 1)"
eq "blocked -> ready: label swap" '["size:S","status:ready","task"]' "$(labels 4)"
eq "ready -> blocked: label swap" '["size:S","status:blocked","task"]' "$(labels 5)"
eq "stale agent claim: assignee, claim:agent and status:claimed removed" '[[],["size:S","status:ready","task"]]' \
  "$(issue 7 '[[.assignees[].login], ([.labels[].name] | sort)]')"
eq "stale agent claim: RECLAIMED comment, v0.1.4 text verbatim" \
  '"RECLAIMED: agent claim was idle >4h with no open PR; task is ready again."' "$(issue 7 '.comments[-1].body')"
eq "stale human claim: one STALE-CLAIM-PING, never released" \
  '[["ann"],"STALE-CLAIM-PING: this claim has been inactive for 72h — still on it? (Human claims are never auto-reclaimed.)"]' \
  "$(issue 8 '[[.assignees[].login], .comments[-1].body]')"
eq "claimed with an open agent PR -> in-review (§2 exception 5)" '"status:in-review"' \
  "$(issue 9 '[.labels[].name | select(startswith("status:"))] | first')"
eq "a fresh agent claim is untouched" '[]' "$(bodies 10)"

# H0: at most once per (issue, PR). A human reopens #3: the same merge never
# re-closes it; a newer merged PR for it does.
jq 'map(if .number == 3 then .state = "OPEN" | .stateReason = "REOPENED" else . end)' "$st/board.json" > "$st/b" && mv "$st/b" "$st/board.json"
: > "$st/log"
run BASE_BRANCH=release/x -- "$scripts/task-queue.sh" --fix
expect "H0: a reopened task is not re-closed by the PR already applied" \
  '[ "$rc" = 0 ] && ! log_has "gh issue close 3" && [ "$(issue 3 .state)" = "\"OPEN\"" ]'
jq -L "$fx" 'include "pr"; . + [pr(103; "MERGED"; "release/x"; "Delivery-Task: 3"; "task/3-again")]' "$st/prs.json" > "$st/p" && mv "$st/p" "$st/prs.json"
run BASE_BRANCH=release/x -- "$scripts/task-queue.sh" --fix
eq "H0: a NEWER merged PR closes it again, with its own marker" \
  '["CLOSED","AUTO-CLOSE: PR #103 merged into release/x. (Reconciled by graph.sh reconcile --fix.)"]' \
  "$(issue 3 '[.state, .comments[-1].body]')"

# --- GC42: merged agent PR into a non-default target -> the issue is closed --------
board '[ i(20; "approved, targets release/x"; ["task","status:approved","size:S"]; "Delivery-Target: release/x"),
         i(21; "dependent"; ["task","status:blocked","size:S"]; "Depends-on: #20") ]' "$tmp/gc42.json"
prs '[ pr(120; "MERGED"; "release/x"; "Delivery-Task: 20"; "task/20--x") ]' "$tmp/gc42-prs.json"
load "$tmp/gc42.json" "$tmp/gc42-prs.json"
g -- reconcile
eq "GC42: reconcile record X -> done naming the PR (then its dependent -> ready)" \
  '[{"op":"transition","id":"20","from":"approved","to":"done","reason":"PR #120 merged into release/x"},{"op":"transition","id":"21","from":"blocked","to":"ready","reason":"every dep is done"}]' \
  "$(jq -sc . <<<"$out")"
expect "GC42: reconcile without --fix writes nothing" '! log_has "issue close" && ! log_has "issue edit" && ! log_has "issue comment"'
g -- reconcile --fix
eq "GC42: --fix exits 0 and prints each applied record" \
  "$(printf 'fix: transition 20 approved -> done: PR #120 merged into release/x\nfix: transition 21 blocked -> ready: every dep is done')" "$out"
expect "GC42: the github backend closes the issue --reason completed" 'log_has "gh issue close 20 --reason completed"'
eq "GC42: closed COMPLETED, with a comment naming the PR" \
  '["CLOSED","COMPLETED","AUTO-CLOSE: PR #120 merged into release/x. (Reconciled by graph.sh reconcile --fix.)"]' \
  "$(issue 20 '[.state, .stateReason, .comments[-1].body]')"
eq "GC42: the dependent is relabelled ready in the same pass" '["size:S","status:ready","task"]' "$(labels 21)"
g -- reconcile
eq "GC42: the next pass has nothing to do (the marker makes the PR applied)" "" "$out"

# --- GC33: the reaper sees only linked PRs, past gh's default page of 30 ------------
stale_claim='| .assignees = [{login: "shim-user"}] | .comments = [c("CLAIM agent-1 h-1-1 t"; "2026-01-02T00:00:00Z")]'
board "[ i(12; \"stale claimed\"; [\"task\",\"status:claimed\",\"claim:agent\",\"size:S\"]; \"x\") $stale_claim ]" "$tmp/gc33.json"
prs '[ range(300; 340) as $n | pr($n; "OPEN"; "main"; "unrelated"; "feat/\($n)") ]
     + [ pr(200; "OPEN"; "main"; "Mentions #12 in passing."; "feat/mention") ]' "$tmp/gc33-mention.json"
jq -L "$fx" 'include "pr"; . + [pr(201; "OPEN"; "main"; "Delivery-Task: 12"; "feat/linked")]' "$tmp/gc33-mention.json" > "$tmp/gc33-linked.json"
load "$tmp/gc33.json" "$tmp/gc33-linked.json"
g -- reconcile --fix
expect "GC33: the PR carrying Delivery-Task: 12, 42 PRs deep, is #12's open PR: not reclaimed" \
  '[ "$rc" = 0 ] && ! grep -q "reclaim 12" <<<"$out" && [ "$(bodies 12 | jq length)" = 1 ]'
eq "GC33: … and its claimed status is repaired to in-review instead (§5 rule 4)" \
  '"fix: transition 12 claimed -> in-review: open PR #201"' "$(jq -Rc . <<<"$out")"
load "$tmp/gc33.json" "$tmp/gc33-mention.json"
g -- reconcile --fix
eq "GC33: a PR that only mentions #12 is not linked: the stale claim is reclaimed" \
  '"fix: reclaim 12 claimed -> ready: RECLAIMED: agent claim was idle >4h with no open PR; task is ready again."' "$(jq -Rc . <<<"$out")"
eq "GC33: RECLAIMED voids the CLAIM; assignee and claim labels gone" \
  '[[],["size:S","status:ready","task"],"RECLAIMED: agent claim was idle >4h with no open PR; task is ready again."]' \
  "$(issue 12 '[[.assignees[].login], ([.labels[].name] | sort), .comments[-1].body]')"
g -- show 12
eq "GC33: after the reclaim the node reads unclaimed and ready" '[null,"ready"]' "$(jq -c '[.claim, .status]' <<<"$out")"

# --- updatedAt re-check before applying (the plan -> apply race) --------------------
load "$tmp/gc33.json" "$tmp/gc33-mention.json"
echo 12 > "$st/touch-before-view"
g -- reconcile --fix
eq "a claim touched between plan and apply is not reclaimed: exit 4 (board changed, re-run)" 4 "$rc"
expect "exit 4: nothing written, the plan is reported stale" \
  '! log_has "issue edit 12" && ! log_has "issue comment 12" && grep -q "stale record: #12" <<<"$err" && grep -q "re-run reconcile" <<<"$err"'
load "$tmp/gc33.json" "$tmp/gc33-mention.json"
echo 12 > "$st/touch-before-view"
run -- "$scripts/task-queue.sh" --fix
expect "task-queue.sh --fix treats exit 4 as retryable: it re-plans (a second reconcile pass), exit 0" \
  '[ "$rc" = 0 ] && [ "$(log_count "gh issue list --state all")" -ge 3 ] && grep -q "board changed" <<<"$err"'
eq "… and the re-planned pass sees the claim as fresh (touched after the plan): never reclaimed" \
  '["status:claimed",["shim-user"],1]' \
  "$(issue 12 '[([.labels[].name | select(startswith("status:"))] | first), [.assignees[].login], (.comments | length)]')"
eq "… so the ready set (stdout) is empty" "" "$out"
load "$tmp/gc33.json" "$tmp/gc33-mention.json"
run -- "$scripts/task-queue.sh" --fix
eq "untouched, the wrapper reclaims and prints the task in the v0.1.4 shape" \
  '{"number":12,"title":"stale claimed","unblocks":0,"size":"S","started":false,"epic":null,"module":"none"}' "$out"

# --- exit 75 survives graph.sh reconcile --fix and the wrapper ----------------------
# Only the local backend locks: hold its lock with a live owner (this shell).
sd="$tmp/local-state"
g GRAPH_BACKEND=local STATE_DIR="$sd" -- create '{"id":"x-1","kind":"task","title":"blocked, no deps","status":"blocked"}'
expect "local: a node to reconcile" '[ "$rc" = 0 ]'
mkdir "$sd/lock"; printf '%s %s - %s\n' "$(uname -n)" "$$" "$(date +%s)" > "$sd/lock/owner"
load "$tmp/gc42.json"
g GRAPH_BACKEND=local STATE_DIR="$sd" LOCK_WAIT_SECONDS=1 -- reconcile --fix
eq "a busy backend lock (75) is preserved by graph.sh reconcile --fix, not mapped to 1" 75 "$rc"
expect "exit 75 says busy, retry" 'grep -q "busy" <<<"$err"'
t0=$(date +%s)
run GRAPH_BACKEND=local STATE_DIR="$sd" LOCK_WAIT_SECONDS=1 -- "$scripts/task-queue.sh" --fix
t1=$(date +%s)
expect "task-queue.sh --fix retries 75, then warns and still prints the (fresh) ready set" \
  '[ "$rc" = 0 ] && grep -q "did not settle" <<<"$err" && [ "$(jq -r .number <<<"$out")" = x-1 ]'
expect "… backing off between the busy passes (5 lock waits of 1s + 4 pauses of 1s)" '[ $((t1 - t0)) -ge 9 ]'
rm -rf "$sd/lock"
run GRAPH_BACKEND=local STATE_DIR="$sd" -- "$scripts/task-queue.sh" --fix
expect "lock free: the wrapper applies it, exit 0" '[ "$rc" = 0 ] && grep -q "fix: transition x-1 blocked -> ready" <<<"$err"'
g GRAPH_BACKEND=local STATE_DIR="$sd" -- transition x-1 cancelled --human ann
expect "local: transition --human ann is journaled with ann as the actor" \
  '[ "$rc" = 0 ] && [ "$(jq -c "select(.op == \"transition\") | [.actor, .from, .to]" "$sd/events.jsonl" | tail -n 1)" = "[\"ann\",\"ready\",\"cancelled\"]" ]'

# --- GC68: unlabelled issues the graph references are external nodes ----------------
board '[ i(1; "T"; ["task","status:ready","size:S"]; "Depends-on: #2"),
         i(3; "U"; ["task","status:blocked","size:S"]; "Depends-on: #4"),
         i(5; "V"; ["task","status:blocked","size:S"]; "Depends-on: #6"),
         (i(2; "A done"; []; "plain") | closed("COMPLETED")),
         (i(4; "B open, odd labels"; ["status:ready","needs-human","size:L","module:z","claim:agent"]; "Depends-on: #1")
            | .assignees = [{login: "ann"}] | .comments = [c("STALE-CLAIM-PING x"; "2026-01-03T00:00:00Z"), c("AUTO-CLOSE: PR #9 merged"; "2026-01-03T00:00:01Z")]),
         (i(6; "D not planned"; []; "plain") | closed("NOT_PLANNED")),
         i(7; "C unreferenced"; []; "Depends-on: #1"),
         i(8; "E epic"; ["epic"]; "- [ ] #9"),
         i(9; "checklist child"; []; "plain"),
         i(10; "backlink child"; []; "Part of epic #8"),
         (i(11; "native child"; []; "plain") | .parent = {number: 8}),
         i(12; "names a non-epic"; []; "see epic #1"),
         (i(13; "native blocker"; []; "plain") | closed("COMPLETED")),
         (i(14; "W"; ["task","size:S"]; "x") | .blockedBy = {nodes: [{number: 13}], totalCount: 1}) ]' "$tmp/gc68.json"
load "$tmp/gc68.json"
g -- list
eq "GC68: referenced unlabelled issues are external: dep targets, epic checklist / backlink / native children" \
  '["2","4","6","9","10","11","13"]' "$(jq -c '[.[] | select(.kind == "external") | .id] | sort_by(tonumber)' <<<"$out")"
eq "GC68: an unreferenced unlabelled issue (C, or one naming a non-epic) is not a node" '[]' \
  "$(jq -c '[.[] | select(.id == "7" or .id == "12")]' <<<"$out")"
eq "GC68: A / B / D normalize to done / blocked / cancelled" '["done","blocked","cancelled"]' \
  "$(jq -c '[.[] | select(.id == "2" or .id == "4" or .id == "6")] | sort_by(.id) | map(.status)' <<<"$out")"
eq "GC68: an external's fixed fields are forced, whatever its labels, assignees, comments and edges" \
  '{"claim":null,"pinged_at":null,"applied_prs":[],"deps":[],"checklist":[],"module":null,"size":null,"plan_ref":null,"promote_to":null,"needs_human":false}' \
  "$(node 4 '{claim, pinged_at, applied_prs, deps, checklist, module, size, plan_ref, promote_to, needs_human}')"
eq "GC68: an external's epic is derived as for any node" '["8","8",null]' "$(jq -c '[.[] | select(.id == "10" or .id == "11" or .id == "9") | .epic] | sort_by(. // "")' <<<"$out" | jq -c 'sort_by(. == null) ')"
g -- ready
eq "GC68: T (dep A done) and W (native dep done) are ready; U (B open) and V (D cancelled) are not" '["1","14"]' "$(jq -sc 'map(.id)' <<<"$out")"
g -- reconcile
eq "GC68: reconcile warns V: blocked on cancelled dep D, and no unknown dep" \
  'warn: 5: blocked on cancelled dep 6' "$(grep '^warn:' <<<"$err" | grep -v 'cycle' || true)"
eq "GC68: no fix record for A, B or D" '[]' "$(jq -sc '[.[] | select(.id == "2" or .id == "4" or .id == "6")]' <<<"$out")"
: > "$st/log"
g -- transition 4 ready --actor human
eq "an external takes no transition: exit 2" 2 "$rc"
expect "… and nothing is written" '! log_has "issue edit" && ! log_has "issue close" && grep -q "external node takes no transition" <<<"$err"'

# --- GC71: an issue labelled both task and epic is a task only ----------------------
board '[ i(30; "X task+epic"; ["task","epic","size:S"]; "- [ ] #33"),
         i(32; "U"; ["task","size:S"]; "free"),
         (i(31; "T"; ["task","size:S"]; "Part of epic #30") | .createdAt = "2026-01-05T00:00:00Z"),
         (i(33; "C"; ["task","size:S"]; "Part of epic #30") | closed("COMPLETED")),
         i(40; "Y task+epic"; ["task","epic","size:S"]; "x"),
         (i(41; "Y child"; ["task","size:S"]; "Part of epic #40") | closed("COMPLETED")) ]' "$tmp/gc71.json"
load "$tmp/gc71.json"
g -- list
eq "GC71: X and Y normalize to kind task with an empty checklist" '[["task",[]],["task",[]]]' \
  "$(jq -c '[.[] | select(.id == "30" or .id == "40") | [.kind, .checklist]]' <<<"$out")"
run -- "$scripts/task-queue.sh"
# Every candidate is S with unblocks 0, so only started-epic and age order them:
# X, U, Y by age, then T (the newest). v0.1.4 ranked T first, as a started epic.
eq "GC71: X is ready; T is not started and U precedes it (v0.1.4 put T first)" \
  '[[30,false],[32,false],[40,false],[31,false]]' "$(jq -sc 'map([.number, .started])' <<<"$out")"
g -- reconcile
eq "GC71: no -> done record for X or Y (v0.1.4 auto-closed Y)" '[]' \
  "$(jq -sc '[.[] | select(.to == "done")]' <<<"$out")"

# --- GC75: a merged PR that closed the issue by closing keyword counts as applied ---
board '[ (i(50; "X reopened"; ["task","status:ready","size:S"]; "x")
            | .closedByPullRequestsReferences = [{id: "PR_1", number: 150, url: "u"}] | ._closers = [150]),
         i(51; "dependent"; ["task","status:blocked","size:S"]; "Depends-on: #50"),
         (i(52; "only linked, never closed"; ["task","status:ready","size:S"]; "x")
            | .closedByPullRequestsReferences = [{id: "PR_2", number: 152, url: "u"}]),
         (i(53; "closed by another repo"; ["task","status:ready","size:S"]; "x")
            | .closedByPullRequestsReferences = [{id: "PR_3", number: 153, url: "u"}] | ._closers = [{number: 153, repo: "other/repo"}]),
         (i(54; "closed keyword, still closed"; ["task","size:S"]; "x") | closed("COMPLETED")
            | .closedByPullRequestsReferences = [{id: "PR_4", number: 154, url: "u"}] | ._closers = [154]) ]' "$tmp/gc75.json"
prs '[ pr(150; "MERGED"; "main"; "Closes #50\n\nDelivery-Task: 50"; "task/50--x"),
       pr(152; "MERGED"; "main"; "Delivery-Task: 52"; "task/52--x"),
       pr(153; "MERGED"; "main"; "Delivery-Task: 53"; "task/53--x") ]' "$tmp/gc75-prs.json"
load "$tmp/gc75.json" "$tmp/gc75-prs.json"
g -- list
eq "GC75: X's applied_prs holds the PR whose closing keyword closed it (timeline closer)" '[150]' "$(node 50 .applied_prs)"
eq "GC75: a linked PR that never closed the issue is not evidence" '[]' "$(node 52 .applied_prs)"
eq "GC75: a closer from another repository is not this repo's PR" '[]' "$(node 53 .applied_prs)"
expect "GC75: only open delivery issues with a closing reference read their timeline" \
  'log_has "-F n=50 " && log_has "-F n=52 " && log_has "-F n=53 " && ! log_has "-F n=54 " && ! log_has "-F n=51 "'
g -- show 50
eq "GC75: show derives the same applied_prs" '[150]' "$(jq -c .applied_prs <<<"$out")"
g -- reconcile
eq "GC75: no record for X or its dependent; the PR-less evidence controls do close" \
  '[["52","done"],["53","done"]]' "$(jq -sc 'map([.id, .to])' <<<"$out")"
run SHIM_GH_VERSION=2.93.0 -- "$graph" list
expect "GC75 on gh < 2.94: no closedByPullRequestsReferences, no timeline read (one warning)" \
  '[ "$rc" = 0 ] && ! grep "gh issue list" "$st/log" | tail -n 1 | grep -q closedBy && [ "$(grep -c "native relations ignored" <<<"$err")" = 1 ]'

# --- the 100-comment cap on the write path ------------------------------------------
board '[ (i(60; "human claim, pinged at comment 104"; ["task","status:claimed","size:S"]; "x")
            | .assignees = [{login: "ann"}]
            | .comments = ([range(1; 104) as $k | c("chatter \($k)"; ("2026-01-01T00:00:00Z" | fromdate + $k | todate))]
                           + [c("STALE-CLAIM-PING @ann"; "2026-01-01T01:00:00Z")])) ]' "$tmp/long.json"
load "$tmp/long.json"
g -- reconcile --fix
eq "a STALE-CLAIM-PING past comment 100 is seen (re-read): no second ping" "0:" "$rc:$out"
expect "… the 104-comment issue was re-read with gh issue view --json comments" 'log_has "gh issue view 60 --json comments"'

# --- graph.sh claim / claim-task.sh (the Lamport lock, unchanged) --------------------
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
recent_iso=$(jq -rn '(now - 5) | floor | todate')
board "[ i(70; \"ready\"; [\"task\",\"status:ready\",\"size:S\"]; \"x\"),
         (i(71; \"closed\"; [\"task\",\"size:S\"]; \"x\") | closed(\"COMPLETED\")),
         (i(72; \"assigned\"; [\"task\",\"status:ready\",\"size:S\"]; \"x\") | .assignees = [{login: \"ann\"}]),
         (i(73; \"rival fresh\"; [\"task\",\"status:ready\",\"size:S\"]; \"x\") | .comments = [c(\"CLAIM rival h-2-2 $recent_iso\"; \"$recent_iso\")]),
         (i(74; \"orphan\"; [\"task\",\"status:ready\",\"size:S\"]; \"x\") | .comments = [c(\"CLAIM ghost h-3-3 t\"; \"2026-01-01T00:00:00Z\")]),
         i(75; \"for a human\"; [\"task\",\"status:ready\",\"size:S\"]; \"x\"),
         (i(76; \"needs human\"; [\"task\",\"status:ready\",\"size:S\",\"needs-human\"]; \"x\")) ]" "$tmp/claims.json"
load "$tmp/claims.json"
run -- "$scripts/claim-task.sh" 70 agent-x
expect "claim-task.sh: exit 0, v0.1.4's one stdout line" \
  '[ "$rc" = 0 ] && grep -qE "^claimed #70 as agent-x \([^ ]+-[0-9]+-[0-9]+\)$" <<<"$out" && [ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ]'
run_id=$(sed -n 's/^claimed #70 as agent-x (\(.*\))$/\1/p' <<<"$out")
eq "claim: CLAIM <actor> <run> <ts> comment, then assignee + status:claimed + claim:agent" \
  "[\"CLAIM agent-x $run_id\",[\"shim-user\"],[\"claim:agent\",\"size:S\",\"status:claimed\",\"task\"]]" \
  "$(issue 70 '[(.comments[0].body | split(" ")[0:3] | join(" ")), [.assignees[].login], ([.labels[].name] | sort)]')"
expect "claim: v0.1.4's gh calls (pre-check view, comment, arbitrate, edit, sanity view)" \
  'log_has "gh issue view 70 --json state,assignees,labels" && log_has "gh issue view 70 --json comments" && log_has "gh issue edit 70 --add-assignee @me --add-label status:claimed --add-label claim:agent --remove-label status:ready" && log_has "gh issue view 70 --json assignees --jq .assignees | length"'
g -- show 70
eq "claim: the node now reads claimed by the agent run" "[\"claimed\",\"agent-x\",\"$run_id\",\"agent\"]" \
  "$(jq -c '[.status, .claim.actor, .claim.run, .claim.by]' <<<"$out")"
run -- "$scripts/claim-task.sh" 70 agent-y
eq "claim-task.sh on a claimed task: exit 1, nothing on stdout" "1:" "$rc:$out"
run -- "$scripts/claim-task.sh" 71 agent-x
eq "claim-task.sh on a closed issue: exit 1, nothing on stdout" "1:" "$rc:$out"
run -- "$scripts/claim-task.sh" 72 agent-x
eq "claim-task.sh on a human-assigned task: exit 1, nothing on stdout" "1:" "$rc:$out"
run -- "$scripts/claim-task.sh" 76 agent-x
eq "claim-task.sh on a needs-human task: exit 1 (policy pre-check)" "1:" "$rc:$out"
: > "$st/log"
run -- "$scripts/claim-task.sh" 73 agent-x
eq "lost race: exit 1, nothing on stdout" "1:" "$rc:$out"
expect "lost race: v0.1.4 stderr, and our CLAIM is withdrawn" \
  'grep -q "^lost claim race for #73 (winner: CLAIM rival h-2-2 " <<<"$err" && [ "$(issue 73 ".comments[-1].body" | grep -c "CLAIM-WITHDRAWN agent-x .* (lost to earlier claim)")" = 1 ]'
eq "lost race: no assignee, no label change" '[[],["size:S","status:ready","task"]]' \
  "$(issue 73 '[[.assignees[].login], ([.labels[].name] | sort)]')"
run -- "$scripts/claim-task.sh" 74 agent-x
expect "orphan: an unconverted CLAIM past the grace window is reaped, then we win" \
  '[ "$rc" = 0 ] && grep -q "^reaped orphan claim on #74: ghost h-3-3$" <<<"$err" && grep -q "^claimed #74 as agent-x " <<<"$out"'
g -- claim 75 --human ann
eq "graph.sh claim --human: exit 0; assignee + status:claimed, no CLAIM comment" \
  '[0,["ann"],["size:S","status:claimed","task"],[]]' \
  "$(issue 75 "[$rc, [.assignees[].login], ([.labels[].name] | sort), [.comments[].body]]")"
g -- show 75
eq "… which reads as a human claim" '{"actor":"ann","run":null,"at":null,"by":"human"}' "$(jq -c .claim <<<"$out")"

# --- release / transition / flag / comment -------------------------------------------
g -- release 70 "gate red"
eq "release: exit 0; claimant, claim:agent off; status:claimed -> ready" '[0,[],["size:S","status:ready","task"]]' \
  "$(issue 70 "[$rc, [.assignees[].login], ([.labels[].name] | sort)]")"
eq "release: the agent's CLAIM is withdrawn in the ledger" "\"CLAIM-WITHDRAWN agent-x $run_id (released: gate red)\"" \
  "$(issue 70 '.comments[-1].body')"
g -- show 70
eq "release: the node reads unclaimed and ready" '[null,"ready"]' "$(jq -c '[.claim, .status]' <<<"$out")"
: > "$st/log"
g -- release 70 "again"
expect "release of an unclaimed node is a no-op" '[ "$rc" = 0 ] && ! log_has "issue edit" && ! log_has "issue comment"'
g -- release 75 "back to the pool"
eq "release of a human claim: the human unassigned, RELEASED: comment" '[[],"RELEASED: back to the pool"]' \
  "$(issue 75 '[[.assignees[].login], .comments[-1].body]')"

: > "$st/log"
g -- transition 70 approved
eq "GC8: transition ready -> approved exits 2" 2 "$rc"
expect "GC8: nothing written" '! log_has "issue edit" && ! log_has "issue close" && grep -q "illegal transition" <<<"$err"'
g -- transition 74 in-review
eq "transition claimed -> in-review by agent: exit 0" 0 "$rc"
eq "… is a status label swap" '["claim:agent","size:S","status:in-review","task"]' "$(labels 74)"
expect "… and an agent transition posts no comment" '! log_has "issue comment 74"'
g -- transition 74 cancelled --actor agent
eq "GC47: transition cancelled --actor agent exits 2, unchanged" '[2,"OPEN"]' "[$rc,$(issue 74 .state)]"
g -- transition 74 cancelled --human ann
eq "GC47: transition cancelled --human ann closes the issue not planned" '[0,"CLOSED","NOT_PLANNED"]' \
  "[$rc,$(issue 74 '.state'),$(issue 74 '.stateReason')]"
eq "… recording the human in the close call's comment" \
  '"TRANSITIONED: in-review -> cancelled by ann (graph.sh transition)."' "$(issue 74 '.comments[-1].body')"
expect "… one close call, no separate comment" '[ "$(log_count "gh issue close 74")" = 1 ] && ! log_has "issue comment 74"'
g -- transition 74 ready --human ann
eq "a closed node takes no further transition (exit 2)" 2 "$rc"

g -- flag 72 needs-human on
eq "flag on: the needs-human label" '["needs-human","size:S","status:ready","task"]' "$(labels 72)"
: > "$st/log"
g -- flag 72 needs-human on
expect "flag on again: idempotent, no edit" '[ "$rc" = 0 ] && ! log_has "issue edit"'
g -- flag 72 needs-human off
eq "flag off: the label is removed" '["size:S","status:ready","task"]' "$(labels 72)"
g -- comment 72 "a durable note"
eq "comment: an issue comment" '"a durable note"' "$(issue 72 '.comments[-1].body')"
printf 'from stdin\nline two' > "$tmp/c.txt"
run -- "$graph" comment 72 - < "$tmp/c.txt"
eq "comment -: the text from stdin" '"from stdin\nline two"' "$(issue 72 '.comments[-1].body')"

# --- create / update / link -----------------------------------------------------------
board '[ i(1; "epic"; ["epic"]; "goal"), i(2; "dep a"; ["task","size:S"]; "x"), i(3; "dep b"; ["task","size:S"]; "x") ]' "$tmp/create.json"
load "$tmp/create.json"
g -- create '{"kind":"task","title":"new task","body":"## Context\nx","epic":"1","deps":[{"id":"2","via":"lib/x.jq"},"3"],"module":"graph","size":"M","target_branch":"release/x","plan_ref":"p/t1","status":"blocked"}'
eq "create: prints the new issue number" '0:4' "$rc:$out"
expect "create: native --parent and --blocked-by, the labels" \
  'log_has "--label task --label status:blocked --label module:graph --label size:M --parent 1 --blocked-by 2 --blocked-by 3"'
eq "create: body = the contract + Delivery-Target / Delivery-Plan + the via edge" \
  '"## Context\nx\n\nDelivery-Target: release/x\nDelivery-Plan: p/t1\nDepends-on: #2 (via: lib/x.jq)"' "$(issue 4 .body)"
g -- show 4
eq "create: the node reads back as written" \
  '["task","1",[{"id":"2","via":"lib/x.jq"},{"id":"3","via":null}],"graph","M","blocked","release/x","p/t1"]' \
  "$(jq -c '[.kind, .epic, .deps, .module, .size, .status, .target_branch, .plan_ref]' <<<"$out")"
g -- create '{"kind":"promote","title":"Promote release/x -> main","target_branch":"release/x","promote_to":"main"}'
g -- show "$out"
eq "create promote: Delivery-Promote-To body line" '["promote","release/x","main"]' "$(jq -c '[.kind, .target_branch, .promote_to]' <<<"$out")"
: > "$st/log"
for bad in '{"kind":"external","title":"x"}' '{"id":"9","kind":"task","title":"x"}' '{"kind":"task","title":"x","claim":{"actor":"a"}}' \
           '{"kind":"task","title":"x","status":"done"}' '{"kind":"task","title":"x"}{"kind":"task","title":"y"}'; do
  g -- create "$bad"
  expect "create refuses $bad (exit 1, no gh issue create)" '[ "$rc" = 1 ] && ! log_has "issue create"'
done
run SHIM_GH_VERSION=2.90.0 -- "$graph" create '{"kind":"task","title":"old gh","epic":"1","deps":["2"]}'
eq "create on gh < 2.94: text edges instead of native flags" '"Part of epic #1\nDepends-on: #2"' "$(issue "$out" .body)"

g -- update 4 '{"status":"ready","module":"forge","size":"S","needs_human":true,"title":"renamed"}'
eq "update: labels swapped in one edit (module/size replace every other module:/size: label)" \
  '["module:forge","needs-human","size:S","status:ready","task"]' "$(labels 4)"
eq "update: title" '"renamed"' "$(issue 4 .title)"
jq 'map(if .number == 4 then .labels += [{name: "size:L"}, {name: "module:extra"}] else . end)' "$st/board.json" > "$st/b" && mv "$st/b" "$st/board.json"
g -- show 4
eq "(a stray size:L / second module label: the read's precedence)" '["L","forge"]' "$(jq -c '[.size, .module]' <<<"$out")"
g -- update 4 '{"size":"M","module":"graph"}'
g -- show 4
eq "update size/module: the stray labels are removed, so the write is what reads back" '["M","graph"]' "$(jq -c '[.size, .module]' <<<"$out")"
g -- update 4 '{"module":null,"size":null}'
eq "update module/size null: every module:/size: label removed" '["needs-human","status:ready","task"]' "$(labels 4)"
: > "$st/log"
g -- update 4 '{"claim":null}'
expect "update refuses claim (claims go through claim/release): exit 1, nothing written" '[ "$rc" = 1 ] && ! log_has "issue edit"'
g -- update 4 '{"status":"bogus"}'
expect "update refuses an unknown status" '[ "$rc" = 1 ] && ! log_has "issue edit"'
g -- update 4 '{"status":"done"}'
eq "update status done: closed completed" '["CLOSED","COMPLETED"]' "$(issue 4 '[.state, .stateReason]')"
g -- update 4 '{"status":"ready"}'
expect "update of a closed issue refuses a status change (reopen is a human's call)" '[ "$rc" = 1 ] && grep -q "is closed" <<<"$err"'
g -- update 4 '{"body":"new body"}'
eq "… but takes a body edit" '"new body"' "$(issue 4 .body)"

: > "$st/log"
g -- link 2 3
eq "link: native --add-blocked-by" '0:[3]' "$rc:$(issue 2 '[.blockedBy.nodes[].number]')"
: > "$st/log"
g -- link 2 3
expect "link again: idempotent, no edit" '[ "$rc" = 0 ] && ! log_has "issue edit"'
g -- link 2 3 "shared config"
eq "link with via: the native edge exists, so only the Depends-on body line is added" '"x\nDepends-on: #3 (via: shared config)"' "$(issue 2 .body)"
g -- link 2 3 "renamed seam"
eq "link with a new via rewrites that line" '"x\nDepends-on: #3 (via: renamed seam)"' "$(issue 2 .body)"
g -- show 2
eq "link: deps read back with the via" '[{"id":"3","via":"renamed seam"}]' "$(jq -c .deps <<<"$out")"
g -- link 2 2
expect "link refuses a self edge" '[ "$rc" = 1 ]'
run SHIM_GH_VERSION=2.90.0 -- "$graph" link 3 1
eq "link on gh < 2.94: a Depends-on text edge" '"x\nDepends-on: #1"' "$(issue 3 .body)"

# --- reconcile records: the backend's compare-and-set --------------------------------
load "$tmp/gc42.json" "$tmp/gc42-prs.json"
rec='{"op":"transition","id":"21","from":"blocked","to":"ready","reason":"every dep is done","updated_at":"2026-01-02T00:00:00Z"}'
run -- "$backend" reconcile "$(jq -c '.updated_at = "2026-01-01T00:00:00Z"' <<<"$rec")"
expect "a record whose updated_at is not the issue's: exit 4, nothing written" '[ "$rc" = 4 ] && ! log_has "issue edit"'
run -- "$backend" reconcile "$(jq -c '.from = "ready"' <<<"$rec")"
expect "a record whose from is not the issue's status: exit 4" '[ "$rc" = 4 ]'
run -- "$backend" reconcile "$(jq -c '.reason = "no PR named" | .id = "20" | .from = "approved" | .to = "done"' <<<"$rec")"
expect "a rule-3 close whose reason names no PR is refused before any write (exit 1)" \
  '[ "$rc" = 1 ] && ! log_has "issue close" && grep -q "does not name its PR" <<<"$err"'
run -- "$backend" reconcile "$(jq -c '.id = "20" | .from = "approved" | .to = "done" | .reason = "PR #120 merged into release/x" | .pr = 121' <<<"$rec")"
expect "an explicit pr field must agree with the reason" '[ "$rc" = 1 ] && ! log_has "issue close"'
run -- "$backend" reconcile "$(jq -c '.id = "20" | .from = "approved" | .to = "done" | .reason = "PR #120 merged into release/x" | .pr = 120' <<<"$rec")"
eq "an explicit pr field is accepted" '"AUTO-CLOSE: PR #120 merged into release/x. (Reconciled by graph.sh reconcile --fix.)"' "$(issue 20 '.comments[-1].body')"
load "$tmp/gc42.json" "$tmp/gc42-prs.json"
: > "$st/fail-issue-comment"
g -- reconcile --fix
expect "crash window: the close lands, its marker fails: exit 1, the operator is told what to post" \
  '[ "$rc" = 1 ] && [ "$(issue 20 .state)" = "\"CLOSED\"" ] && grep -q "post .AUTO-CLOSE: PR #120" <<<"$err"'
expect "… and the apply loop stops there" '! log_has "issue edit 21"'
run -- "$backend" reconcile '{"op":"bogus","id":"21","from":"a","to":"b","reason":"r","updated_at":"t"}'
expect "an unknown op is refused (exit 1)" '[ "$rc" = 1 ]'

if [ "$fails" = 0 ]; then echo "graph-github-write-test: all passed"; else exit 1; fi
