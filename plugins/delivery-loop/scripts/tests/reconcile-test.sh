#!/usr/bin/env bash
# Tests for lib/reconcile.jq (docs/delivery_graph_spec.md §5 `reconcile.jq`):
# the reconcile assertions of golden cases GC2, GC4, GC6, GC7, GC24 (record),
# GC25 (record), GC42 (record), GC43, GC44, GC45 (record), GC65, GC68 (the
# reconcile side of the `external` node kind, §4.1/§5) and GC69 (§12;
# §17 row A5, hardened by issue #47), plus the amended §5 rows of
# lib/transitions.jq that reconcile's records depend on (merged PR -> done from
# every open status; epic ready -> done; ready/blocked drift -> in-review;
# stale-claim reclaim from in-review/changes-requested/approved/ready), and
# GC72/GC73 (issue #52: applied_prs respects a reopen; stale agent claims are
# released from every open status that can hold one).
#
# Offline. GC2/GC4/GC6/GC7 reuse the ready fixtures (fixtures/ready/); the other
# cases are sparse fixtures in fixtures/reconcile/, filled out by expand.jq.
# Every case asserts the exact record list, so a control node that wrongly gets
# a record fails the case too.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib"
fx="$here/fixtures/reconcile"
rfx="$here/fixtures/ready"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-reconcile-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done; fails=1; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }

now=1798761600 # 2027-01-01T00:00:00Z, expand.jq's fixture_now

# run_sparse <fixture> [input filter]: `reconcile` over a sparse fixture; the
# records go to $tmp/out, stderr to $tmp/err.
run_sparse() {
  jq -c -L "$lib" -L "$fx" "include \"expand\"; include \"reconcile\";
    full_input | ${2:-.} | reconcile" "$fx/$1.json" >"$tmp/out" 2>"$tmp/err"
}
# run_nodes <ready fixture>: `reconcile` over a full node array, no PRs.
run_nodes() {
  jq -c -L "$lib" --argjson now "$now" 'include "reconcile";
    {nodes: ., prs: [], now: $now} | reconcile' "$rfx/$1" >"$tmp/out" 2>"$tmp/err"
}
# moves: the records in $tmp/out as "<op> <id> <from>-><to>" strings.
moves() { jq -c '[.[] | "\(.op) \(.id) \(.from)->\(.to)"]' "$tmp/out"; }
# stderr_has <name> <substring>
stderr_has() {
  if grep -qF -- "$2" "$tmp/err"; then pass "$1"
  else fail "$1" "stderr lacks: $2" "stderr: $(cat "$tmp/err")"; fi
}

# --- rule 8 warnings, and the rule 1/2 records on the ready fixtures -----------------
run_nodes gc2.json
stderr_has "GC2 reconcile warns on a cancelled dep" \
  "warn: gc2-blocked: blocked on cancelled dep gc2-dep-cancelled"
eq "GC2 the cancelled dep never unblocks (no records)" '[]' "$(moves)"

run_nodes gc4.json
eq "GC4 needs_human, deps done, blocked -> no blocked -> ready (control unblocks)" \
  '["transition gc4-unflagged blocked->ready"]' "$(moves)"

run_nodes gc6.json
stderr_has "GC6 reconcile warns on the cycle" "warn: cycle: gc6-a → gc6-b → gc6-a"
eq "GC6 cycle members are not ready: both ready -> blocked" \
  '["transition gc6-a ready->blocked","transition gc6-b ready->blocked"]' "$(moves)"

run_nodes gc7.json
stderr_has "GC7 reconcile warns on an unknown dep" "warn: gc7-orphan: unknown dep gc7-missing"
eq "GC7 the unknown dep is unmet: ready -> blocked" \
  '["transition gc7-orphan ready->blocked"]' "$(moves)"
if grep -q 'gc7-control' "$tmp/err"; then fail "GC7 control has no warning" "$(cat "$tmp/err")"
else pass "GC7 control has no warning"; fi

# --- rule 5: stale agent claims -----------------------------------------------------
# Staleness compares instants: gc24-offset is 4.5h old (lexically 1.5h) and
# gc24-offset-fresh 2.5h old (lexically 4.5h), so a raw-string or offset-dropping
# parse fails one of them.
run_sparse gc24
eq "GC24 agent claim idle >4h, no PR -> one reclaim record (offsets normalized)" \
  '["reclaim gc24-stale claimed->ready","reclaim gc24-offset claimed->ready"]' "$(moves)"
eq "GC24 reclaim reason keeps the v0.1.4 RECLAIMED text" \
  '"RECLAIMED: agent claim was idle >4h with no open PR; task is ready again."' \
  "$(jq -c '.[0].reason' "$tmp/out")"
eq "GC24 records carry exactly {op, id, from, to, reason}" '[["from","id","op","reason","to"]]' \
  "$(jq -c '[.[] | keys] | unique' "$tmp/out")"
# Any open PR for the node (agent or not) protects the claim (GC33's reaper).
# Without it, the in-review node's stale claim is released too (GC73).
run_sparse gc24 '.prs = []'
eq "GC24 without the PR, the in-review stale claim is released as well (GC73)" \
  '["reclaim gc24-stale claimed->ready","reclaim gc24-has-pr in-review->ready","reclaim gc24-offset claimed->ready"]' \
  "$(moves)"
eq "GC24 without the PR: no warnings" '' "$(cat "$tmp/err")"

# GC73 (issue #52, O2): v0.1.4 released any stale claim:agent with no open PR,
# whatever its status label. A stale agent claim on an in-review /
# changes-requested / approved node (its PR closed unmerged, or none) or on a
# ready node (claim drift; N-2: a live CLAIM comment with no assignee) is
# released to ready. An open PR, a fresh claim or a human claim protects it.
run_sparse gc73
eq "GC73 stale agent claims released from in-review (closed-unmerged PR), changes-requested, approved, ready" \
  '["reclaim gc73-in-review in-review->ready","reclaim gc73-changes changes-requested->ready","reclaim gc73-approved approved->ready","reclaim gc73-orphan ready->ready"]' \
  "$(moves)"
eq "GC73 every release is a RECLAIMED record (the claim is cleared)" \
  '["reclaim"]|["RECLAIMED: agent claim was idle >4h with no open PR; task is ready again."]' \
  "$(jq -c 'map(.op) | unique' "$tmp/out")|$(jq -c 'map(.reason) | unique' "$tmp/out")"
eq "GC73 no record for the open-PR, fresh and human claims; no warnings" '[]|' \
  "$(jq -c '[.[] | select(.id == "gc73-open-pr" or .id == "gc73-fresh" or .id == "gc73-human")]' "$tmp/out")|$(cat "$tmp/err")"
# A released ready node is unclaimed in the working copy: no later rule sees
# the claim (a reclaim cannot be followed by a ping or a second reclaim).
run_sparse gc73 '.now += 30 * 24 * 3600'
eq "GC73 a month later: the same four releases, the human claim gets its one ping" \
  '["reclaim gc73-in-review in-review->ready","reclaim gc73-changes changes-requested->ready","reclaim gc73-approved approved->ready","reclaim gc73-orphan ready->ready","reclaim gc73-fresh in-review->ready","ping gc73-human in-review->in-review"]' \
  "$(moves)"
# needs_human still freezes the claim, from any status.
run_sparse gc73 '.nodes |= map(.needs_human = true)'
eq "GC73 needs_human: no release from any status" '[]' "$(jq -c '[.[] | select(.op == "reclaim")]' "$tmp/out")"

# --- rule 3: merged PR -> done ---------------------------------------------------------
run_sparse gc25
eq "GC25 merged PR -> x done, its dependent -> ready in the same pass" \
  '["transition gc25-x in-review->done","transition gc25-dependent blocked->ready"]' "$(moves)"

run_sparse gc42
eq "GC42 merged agent PR into the node's target release/x -> done (wrong base, non-agent: none)" \
  '["transition 42 approved->done"]' "$(moves)"
eq "GC42 the done record names the PR" '"PR #142 merged into release/x"' \
  "$(jq -c '.[0].reason' "$tmp/out")"
# The amended §5 row: every open status may go done on a merged PR (label drift,
# human-driven PRs), never a closed one.
for s in blocked ready claimed in-review changes-requested approved; do
  run_sparse gc42 ".nodes[0].status = \"$s\""
  eq "GC42 merged PR -> done from $s" "[\"transition 42 $s->done\"]" "$(moves)"
done
run_sparse gc42 '.nodes[0].status = "cancelled"'
eq "GC42 a cancelled node is not reopened as done" '[]' "$(moves)"
# Several merged PRs for one node: one record, naming the newest PR.
run_sparse gc42 '.prs += [.prs[0] | .number = 150 | .url = "https://forge.example/pr/150"]'
eq "GC42 two merged PRs for one node -> one record, newest PR" '["PR #150 merged into release/x"]' \
  "$(jq -c 'map(.reason)' "$tmp/out")"
# The base is checked per PR before picking the newest: a newer merge into another
# base (a cherry-pick into main) must not hide the merge into target_branch.
run_sparse gc42 '.nodes = [.nodes[0] | .id = "1"]
                 | .prs = ([{number: 10, state: "merged", task_id: "1", base: "release/x"},
                            {number: 12, state: "merged", task_id: "1", base: "main"}]
                           | map(full_pr))'
eq "GC42 older merge into target, newer merge into main -> 1 done" \
  '["transition 1 approved->done"]' "$(moves)"
eq "GC42 the record names the qualifying PR, not the newer off-base one" \
  '"PR #10 merged into release/x"' "$(jq -c '.[0].reason' "$tmp/out")"
# A promotion PR targets promote_to (§9): head T, base P.
run_sparse gc42 '.nodes[0] |= (.kind = "promote" | .status = "in-review" | .promote_to = "main")
                 | .prs[0].base = "main"'
eq "GC42 merged promotion PR into promote_to -> promote node done" \
  '["transition 42 in-review->done"]' "$(moves)"

# GC72 (issue #52, O1): a human reopened task X whose merged PR #172 reconcile
# already applied (applied_prs) stays open: rule 3 acts once per (node, PR), so
# the merged-PR feed never re-closes it. The same board without applied_prs
# closes X and unblocks its dependent, and a newer merged PR still closes X.
run_sparse gc72
eq "GC72 reopened task, its merged PR in applied_prs -> no record (dependent stays blocked)" '[]' "$(moves)"
eq "GC72 skipping an applied PR is a filter, not a warning" '' "$(cat "$tmp/err")"
run_sparse gc72 '.nodes[0].applied_prs = []'
eq "GC72 the same board without applied_prs -> 72 done, 73 ready" \
  '["transition 72 ready->done","transition 73 blocked->ready"]' "$(moves)"
run_sparse gc72 '.prs += [.prs[0] | .number = 180 | .url = "https://forge.example/pr/180"]'
eq "GC72 a newer merged PR not yet applied closes the reopened task" \
  '["PR #180 merged into main"]' "$(jq -c '[.[] | select(.id == "72") | .reason]' "$tmp/out")"
run_sparse gc72 '.nodes[0].applied_prs = [100, 172]
                 | .prs = [.prs[0] | ., (.number = 100 | .url = "https://forge.example/pr/100")]'
eq "GC72 every merged PR already applied -> no record" '[]' "$(moves)"

# --- rule 4: open PR -> in-review --------------------------------------------------------
run_sparse gc43
eq "GC43 claimed + open agent PR -> claimed -> in-review (non-agent PR: none)" \
  '["transition gc43-claimed claimed->in-review"]' "$(moves)"

# GC69: status drift. An open agent PR whose node drifted to ready/blocked is
# repaired to in-review. Rule 4 runs before rules 1/2, so neither the done dep
# (blocked -> ready) nor the unmet dep (ready -> blocked) wins.
run_sparse gc69
eq "GC69 open agent PR on a ready/blocked node -> in-review (non-agent PR: none)" \
  '["transition gc69-ready ready->in-review","transition gc69-blocked blocked->in-review","transition gc69-ready-unmet ready->in-review"]' \
  "$(moves)"
eq "GC69 the drift record names the PR" '"open PR #69"' "$(jq -c '.[0].reason' "$tmp/out")"

# --- rule 6: stale human claims ----------------------------------------------------------
run_sparse gc44
eq "GC44 human claim idle 73h: one ping when pinged_at is null, none when set; never released" \
  '["ping gc44-unpinged claimed->claimed"]' "$(moves)"
eq "GC44 ping reason keeps the v0.1.4 STALE-CLAIM-PING text" true \
  "$(jq '.[0].reason | startswith("STALE-CLAIM-PING: this claim has been inactive for 72h")' "$tmp/out")"
run_sparse gc44 '.now += 30 * 24 * 3600'
eq "GC44 a month later: still one ping, still no reclaim" \
  '["ping gc44-unpinged claimed->claimed","ping gc44-recent claimed->claimed"]' "$(moves)"

# --- rule 7: epics done -------------------------------------------------------------------
run_sparse gc45
eq "GC45 epic with done + cancelled (checklist-only) children -> done; drifted-blocked epic -> done" \
  '["transition 1 ready->done","transition 4 blocked->done"]' "$(moves)"
eq "GC45 the checklist-only child's own epic stays null" 'null' \
  "$(jq -c -L "$fx" 'include "expand"; full_input | .nodes[] | select(.id == "3") | .epic' "$fx/gc45.json")"
run_sparse gc45 '.nodes |= map(select(.id != "3"))'
eq "GC45 control: without the checklist-only child epic 1 still has one done child" \
  '["transition 1 ready->done","transition 4 blocked->done"]' "$(moves)"
run_sparse gc45 '.nodes |= map(if .id == "3" then .status = "ready" else . end)'
eq "GC45 an open checklist-only child keeps epic 1 open" \
  '["transition 4 blocked->done"]' "$(moves)"
# Cascade: the open child's PR merges -> child done -> epic 5 done, same pass.
run_sparse gc45 '.prs[0].state = "merged"'
eq "GC45 merged PR closes the last child, then its epic, in one pass" \
  '["transition 9 in-review->done","transition 1 ready->done","transition 4 blocked->done","transition 5 ready->done"]' \
  "$(moves)"
# An epic of epics closes once its child epics do (rule 7 repeats).
run_sparse gc45 '.nodes += [{id: "10", kind: "epic", size: null, checklist: ["1", "4"]}] | .nodes |= map(full_node)'
eq "GC45 epic of epics closes in the same pass" \
  '["transition 1 ready->done","transition 4 blocked->done","transition 10 ready->done"]' "$(moves)"

# GC69 epic guard: rule 4's ready/blocked drift repair is for task/promote nodes.
# An open agent PR carrying an epic's id must not send the epic to in-review,
# where rule 7 could never close it.
epic_pr='.prs += [.prs[0] | .number = 95 | .task_id = "5" | .url = "https://forge.example/pr/95"]'
run_sparse gc45 "$epic_pr"
eq "GC69 open agent PR on a ready epic -> no in-review record (epic 5 stays open)" \
  '["transition 1 ready->done","transition 4 blocked->done"]' "$(moves)"
eq "GC69 the epic guard is a filter, not a skipped record" '' "$(cat "$tmp/err")"
run_sparse gc45 "$epic_pr | .prs[0].state = \"merged\""
eq "GC69 the epic with an open PR still closes when its last child merges (rule 7)" \
  '["transition 9 in-review->done","transition 1 ready->done","transition 4 blocked->done","transition 5 ready->done"]' \
  "$(moves)"

# --- GC68: external nodes get no record of any rule ------------------------------------------
# Externals: a (done, child of epic e), b (open, child of epic f), d (cancelled),
# x (open, with an open agent PR: rule 4), y (open, with a merged agent PR into
# its target: rule 3). Only their dependents and epics move: t (dep a done)
# unblocks, u (dep b open) blocks, v (dep d cancelled) stays blocked; epic e
# (children: done external a + done task c) completes, epic f (open external
# child b) does not.
run_sparse gc68
eq "GC68 externals get no record; their dependents and epics do" \
  '["transition gc68-e ready->done","transition gc68-t blocked->ready","transition gc68-u ready->blocked"]' \
  "$(moves)"
eq "GC68 an open external with no deps gets no blocked -> ready record" '[]' \
  "$(jq -c '[.[] | select(.id == "gc68-b" or .id == "gc68-x" or .id == "gc68-y")]' "$tmp/out")"
stderr_has "GC68 a cancelled external dep warns like any cancelled dep (GC2)" \
  "warn: gc68-v: blocked on cancelled dep gc68-d"
eq "GC68 the only warning is the cancelled dep (no skipped record, no unknown dep)" \
  'warn: gc68-v: blocked on cancelled dep gc68-d' "$(cat "$tmp/err")"
# Every rule 1-7 trigger an external could match, on one board: none fires.
run_sparse gc68 '.nodes = [.nodes[] | select(.kind == "external")]'
eq "GC68 a board of externals only -> no records, no warnings" '[]|' "$(moves)|$(cat "$tmp/err")"

# --- GC65: a record the table rejects is skipped; the rest stand ------------------------------
run_sparse gc65
eq "GC65 the done node's reclaim is skipped, the claimed node's is applied" \
  '["transition gc65-blocked blocked->ready","reclaim gc65-claimed claimed->ready"]' "$(moves)"
stderr_has "GC65 the rejected record is a warning on stderr" \
  'warn: skipped reclaim gc65-done: illegal transition "gc65-done": done -> ready by reconcile'

# --- input validation ----------------------------------------------------------------------
if jq -c -L "$lib" -L "$fx" 'include "expand"; include "reconcile";
     full_input | .nodes[0].status = "open" | reconcile' "$fx/gc65.json" >/dev/null 2>&1; then
  fail "malformed node rejected" "accepted"
else pass "malformed node rejected"; fi
if jq -c -L "$lib" -L "$fx" 'include "expand"; include "reconcile";
     full_input | .prs = [{number: 1}] | reconcile' "$fx/gc65.json" >/dev/null 2>&1; then
  fail "malformed PR rejected" "accepted"
else pass "malformed PR rejected"; fi
if jq -c -L "$lib" -L "$fx" 'include "expand"; include "reconcile";
     full_input | .now = "2027-01-01T00:00:00Z" | reconcile' "$fx/gc65.json" >/dev/null 2>&1; then
  fail "non-numeric now rejected" "accepted"
else pass "non-numeric now rejected"; fi

# --- transitions.jq: the amended §5 rows reconcile depends on ------------------------------------
# <kind> <from> <to> <actor> <legal: 0|1>
while read -r kind from to actor want; do
  [ -n "$kind" ] || continue
  got=$(jq -n -L "$lib" --arg k "$kind" --arg f "$from" --arg t "$to" --arg a "$actor" \
    'include "transitions"; {id: "x", kind: $k, status: $f}
     | if transition_error($t; $a) == null then 1 else 0 end')
  eq "transition $kind $from -> $to by $actor is $( [ "$want" = 1 ] && echo legal || echo illegal)" "$want" "$got"
done <<'EOF'
task ready in-review reconcile 1
task blocked in-review reconcile 1
promote ready in-review reconcile 1
task ready in-review agent 0
task ready in-review human 0
task approved in-review reconcile 0
promote blocked in-review reconcile 1
epic ready in-review reconcile 0
external blocked in-review reconcile 0
external blocked ready reconcile 0
external blocked done reconcile 0
epic blocked in-review reconcile 0
task blocked done reconcile 1
task ready done reconcile 1
promote ready done reconcile 1
epic ready done reconcile 1
epic blocked done reconcile 1
epic in-review done reconcile 1
epic ready done agent 0
epic ready done human 0
task ready done agent 0
task done done reconcile 0
task cancelled done reconcile 0
task in-review ready reconcile 1
task changes-requested ready reconcile 1
task approved ready reconcile 1
task ready ready reconcile 1
promote in-review ready reconcile 1
task in-review ready agent 0
task approved ready human 0
task blocked ready agent 0
task done ready reconcile 0
EOF
eq "the kind-guarded rows: drift repair (task/promote), epic completion (epic)" \
  '[{"from":["ready","blocked"],"to":"in-review","kinds":["task","promote"]},{"from":["ready"],"to":"done","kinds":["epic"]}]' \
  "$(jq -c -n -L "$lib" 'include "transitions"; [transitions[] | select(.kinds) | {from, to, kinds}]')"
eq "the stale-reclaim rows: claimed (plus claimant release) and every later open status or ready" \
  '[["claimed"],["approved","changes-requested","in-review","ready"]]' \
  "$(jq -c -n -L "$lib" 'include "transitions";
      [transitions[] | select(.to == "ready" and any(.actors[]; . == "reconcile") and (.from != ["blocked"])) | .from | sort]')"
eq "the merged-PR row covers every open status" \
  '["approved","blocked","changes-requested","claimed","in-review","ready"]' \
  "$(jq -c -n -L "$lib" 'include "transitions";
      [transitions[] | select(.to == "done" and .kinds == null and (.when | test("GC42")))][0].from | sort')"

if [ "$fails" -ne 0 ]; then
  echo "reconcile tests FAILED" >&2
  exit 1
fi
echo "reconcile tests passed"
