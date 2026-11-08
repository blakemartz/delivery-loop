#!/usr/bin/env bash
# Tests for lib/tick-plan.jq and tick-plan.sh (docs/delivery_graph_spec.md §5
# `tick-plan.jq`, §9): golden cases GC12–GC20, GC39 (plan assertion), GC62, GC70
# and the `tick-plan.sh` part of GC59 (§12, §17 rows A6, A7).
#
# Offline. The plan cases run tick_plan over the sparse fixtures in
# fixtures/tick-plan/ (expand.jq fills in the §4.1/§4.2 defaults). The script
# cases run a copy of the scripts directory in a throwaway git repo, with
# graph.sh and forge.sh replaced by stubs that log every call and answer from
# fixtures, so the host repo's .claude/delivery.conf never leaks in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib"
fx="$here/fixtures/tick-plan"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-tick-plan-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done; fails=1; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }

# plan <fixture> [jq filter on the plan] [jq filter on the sparse input]:
# the plan for a fixture, projected, as compact JSON.
plan() {
  jq -c -L "$lib" -L "$fx" "include \"expand\"; include \"tick-plan\";
    ${3:-.} | full_input | tick_plan | ${2:-.}" "$fx/$1.json"
}
# acts <fixture> [input filter]: the actions as "<action> <pr|id>" strings.
acts() { plan "$1" '[.actions[] | "\(.action) \(.pr // .id)"]' "${2:-.}"; }
# waits_for <name> <fixture> <substring> [input filter]: some waiting line
# contains <substring>.
waits_for() {
  if plan "$2" '.waiting[]' "${4:-.}" | grep -qF -- "$3"; then pass "$1"
  else fail "$1" "no waiting line contains: $3" "waiting: $(plan "$2" .waiting "${4:-.}")"; fi
}

# --- priority rules ---------------------------------------------------------------
eq "GC12 serial: changes-requested + review-pending + ready -> [patch]" \
  '["patch 1"]' "$(acts gc12)"
waits_for "GC12 the deferred review is named in waiting" gc12 "review PR #2"

eq "GC13 parallel 3: patch + starts for a and b, second a skipped" \
  '["patch 7","start t-a1","start t-b1"]' "$(acts gc13)"
waits_for "GC13 the skipped a task waits on its module lock" gc13 "t-a2 waits for module a on main"
eq "GC13 each PR in at most one action" true \
  "$(plan gc13 '[.actions[].pr // empty] | length == (unique | length)')"
# A PR's node has one status, so even a board where every PR could match a
# rule yields one action per PR.
eq "GC13 one action per PR across every rule (misc board)" true \
  "$(plan misc '[.actions[].pr // empty] | length == (unique | length)')"

eq "GC14 cap reached, counting an approved-unmerged PR -> no start" '[]' "$(acts gc14)"
waits_for "GC14 waiting names the cap" gc14 "start capped: 2 in flight of cap 2"
eq "GC14 parallel 2, same board -> still no start" '[]' "$(acts gc14 '.flags.parallel = 2')"
eq "GC14 control: without the approved PR the start fills the slot" '["start t-ready"]' \
  "$(acts gc14 '.prs = [] | .nodes |= map(select(.id != "t-approved"))')"

eq "GC15 --auto-merge: merge A, merge C, rebase B" \
  '["merge 11","merge 13","rebase 12"]' "$(acts gc15)"
eq "GC15 merge actions carry the judged head sha" \
  '["aaaaaaa000000000000000000000000000000000","ccccccc000000000000000000000000000000000"]' \
  "$(plan gc15 '[.actions[] | select(.action == "merge") | .sha]')"
eq "GC15 without --auto-merge: only the rebase" '["rebase 12"]' \
  "$(acts gc15 '.flags.auto_merge = false')"
waits_for "GC15 without --auto-merge, approved+clean PRs await a human" gc15 \
  "PR #11 (t-a) is approved: awaiting a human merge" '.flags.auto_merge = false'
eq "merge refused on pending/failure checks, blocked/unknown mergeability (GC57)" '[]' \
  "$(acts gc15 '.prs = [{number: 1, task_id: "t-a", checks: "pending"},
                         {number: 2, task_id: "t-b", checks: "failure"},
                         {number: 3, task_id: "t-c", mergeable: "blocked"},
                         {number: 4, task_id: "t-c", mergeable: "unknown"}]')"
eq "merge refused on a needs-human PR label or a needs-human node" '[]' \
  "$(acts gc15 '.prs = [{number: 1, task_id: "t-a", labels: ["agent-authored", "needs-human"]},
                         {number: 3, task_id: "t-c"}]
                | .nodes |= map(if .id == "t-c" then .needs_human = true else . end)')"

eq "GC16 approved+conflicting at patch_iteration 3 -> no rebase" '[]' "$(acts gc16)"
waits_for "GC16 the PR is listed in waiting" gc16 \
  "PR #21 (t-capped) is approved but conflicting at patch iteration 3/3"
eq "GC16 control: at patch_iteration 2 it is rebased" '["rebase 21"]' \
  "$(acts gc16 '.prs[0].patch_iteration = 2')"

eq "GC18 same module, different target_branch -> both started" \
  '["start t-main","start t-rel"]' "$(acts gc18)"
eq "GC18 control: same module and target -> one start" '["start t-main"]' \
  "$(acts gc18 '.nodes[1].target_branch = "main"')"
eq "module lock: an in-flight PR on (main, m) blocks a start on (main, m) only" \
  '["start t-rel"]' \
  "$(acts gc18 '.nodes += [{id: "t-busy", module: "m", status: "in-review"}]
                | .prs = [{number: 9, task_id: "t-busy", reviewed_at_head: true}]')"
eq "module lock: no-module tasks are exempt" '["start t-main","start t-rel"]' \
  "$(acts gc18 '.nodes |= map(.module = null | .target_branch = "main")')"

eq "GC19 promote node with every epic done -> [promote p]" '["promote p"]' "$(acts gc19)"
eq "GC19 same with needs_human -> no promote action" '[]' \
  "$(acts gc19 '.nodes[2].needs_human = true')"
waits_for "GC19 the needs-human promote node is listed in waiting" gc19 "p needs-human" \
  '.nodes[2].needs_human = true'
eq "promote waits while an epic is not done" '[]' "$(acts gc19 '.nodes[1].status = "in-review"')"

eq "GC20 nothing actionable -> actions []" '[]' "$(acts gc20)"
waits_for "GC20 waiting names the human merge" gc20 "PR #31 (t-dep) is approved: awaiting a human merge"
waits_for "GC20 waiting names the empty queue" gc20 "no ready tasks"
waits_for "GC20 waiting names the blocked task" gc20 "1 task(s) blocked on deps"
eq "GC20 empty board -> actions [], waiting [no ready tasks]" '[[],["no ready tasks"]]' \
  "$(plan gc20 '[.actions, .waiting]' '.nodes = [] | .prs = []')"

eq "GC39 --auto-merge, open promotion PR clean+success -> no merge action" '[]' "$(acts gc39)"
waits_for "GC39 the promotion PR awaits a human merge" gc39 "promotion PR #41 (p) awaits a human merge"

eq "GC62 changes-requested at patch_iteration 3 -> patch emitted" '["patch 62"]' "$(acts gc62)"
eq "GC62 patch reason names the escalation" true \
  "$(plan gc62 '.actions[0].reason | test("3/3: patch-task escalates")')"

# --- GC70 hardening: no duplicate starts or merges, base check ----------------------------
# A claim-less, module-less node whose agent PR is still open (status drifted to
# ready) is in ready.jq's set, but must not be started: that would spawn a
# duplicate implementation. No module lock protects it.
eq "GC70 claim-less, module-less node with an open agent PR -> no start (the free task starts)" \
  '["start t-free"]' "$(acts gc70-start)"
waits_for "GC70 the PR-held node is named in waiting" gc70-start \
  "t-drift is not started: it has an open agent PR (#70)"
eq "GC70 serial: the PR-held top task is skipped, the next ready task starts" \
  '["start t-free"]' "$(acts gc70-start '.flags = {}')"
eq "GC70 control: without the PR the drifted node is started" \
  '["start t-drift","start t-free"]' "$(acts gc70-start '.prs = []')"
# Any status: an in-review node whose claim a human cleared is reviewed, not started.
eq "GC70 claim cleared on an in-review node -> review, no start" \
  '["review 70","start t-free"]' \
  "$(jq -c -L "$lib" -L "$fx" 'include "expand"; include "tick-plan";
      full_input | .nodes[0] |= (.status = "in-review" | .claim = null)
      | tick_plan | [.actions[] | "\(.action) \(.pr // .id)"]' "$fx/gc70-start.json")"

eq "GC70 two approved clean PRs for one task -> one merge (lowest PR); base mismatch -> none" \
  '["merge 71","merge 74"]' "$(acts gc70-merge)"
waits_for "GC70 the duplicate approved PR waits for a human" gc70-merge \
  "PR #72 (t-dup) is approved too, but PR #71 merges for the task"
waits_for "GC70 the off-base PR waits for a human" gc70-merge \
  "PR #73 (t-base) is approved but targets main, not the node's target release/x"
eq "GC70 control: with the base fixed, the off-base PR merges" \
  '["merge 71","merge 73","merge 74"]' "$(acts gc70-merge '.prs[2].base = "release/x"')"

# --- batch and mode rules -------------------------------------------------------------
eq "misc: merges, then promotes, then agent actions in priority order" \
  '["merge 50","promote p","review 55","review 56"]' "$(acts misc)"
eq "misc: non-agent, merged, needs-human and reviewed-at-head PRs produce no action" true \
  "$(plan misc '[.actions[].pr // empty] | all(. == 50 or . == 55 or . == 56)')"
waits_for "misc: a needs-human node is mentioned" misc "t-flagged needs-human"
waits_for "misc: a needs-human-labeled PR is mentioned" misc "PR #51 (t-human-pr) is labeled needs-human"
eq "serial: every merge and promote ahead of its one agent action" \
  '["merge 50","promote p","review 55"]' "$(acts misc '.flags.parallel = 1')"
eq "parallel truncates agent actions to N: three reviews at N=2 -> two, one deferred" \
  '[["review 1","review 2"],true]' \
  "$(plan gc12 '[[.actions[] | "\(.action) \(.pr)"], any(.waiting[]; test("deferred.*review PR #3"))]' \
     '.flags.parallel = 2
      | .nodes = [{id: "a", status: "in-review"}, {id: "b", status: "in-review"}, {id: "c", status: "in-review"}]
      | .prs = [{number: 1, task_id: "a"}, {number: 2, task_id: "b"}, {number: 3, task_id: "c"}]')"
eq "serial considers only the top ready task (locked top -> no start)" '[]' \
  "$(acts gc18 '.nodes[1].target_branch = "main"
                | .nodes += [{id: "t-busy", module: "m", status: "claimed"}]
                | .nodes += [{id: "t-free", created_at: "2026-01-02T00:00:00Z"}] | .flags = {}')"
eq "mode: serial by default, parallel N, clamped at 16" \
  '[{"name":"serial","n":1},{"name":"parallel","n":4},{"name":"parallel","n":16},{"name":"serial","n":1}]' \
  "$(jq -c -n -L "$lib" -L "$fx" 'include "expand"; include "tick-plan";
      [null, 4, 99, 1] | map({flags: {parallel: .}} | full_input | tick_plan | .mode)')"
eq "board counts task and promote nodes per status, every status keyed" \
  '{"blocked":0,"ready":1,"claimed":0,"in-review":0,"changes-requested":0,"approved":0,"done":0,"cancelled":0}' \
  "$(plan gc19 .board)"

# Inputs are validated: a malformed PR, node or flag fails fast.
for bad in '.prs[0].mergeable = "MERGEABLE"' '.nodes[0].status = "open"' '.flags.parallel = "3"'; do
  if plan gc12 . "$bad" >/dev/null 2>&1; then fail "malformed input rejected: $bad" "accepted"
  else pass "malformed input rejected: $bad"; fi
done

# --- tick-plan.sh ---------------------------------------------------------------------
# A copy of the scripts dir whose graph.sh / forge.sh are logging stubs.
repo="$tmp/repo"; sd="$tmp/scripts"
git init -q "$repo"
mkdir -p "$sd"
cp -R "$here/../lib" "$sd/lib"
cp "$here/../tick-plan.sh" "$sd/tick-plan.sh"
for seam in graph forge; do
  cat >"$sd/$seam.sh" <<EOF
#!/usr/bin/env bash
echo "$seam.sh \$*" >>"\$STUB_LOG"
cat "\$STUB_DIR/$seam.json"
EOF
done
mkdir -p "$tmp/stub"
jq -L "$fx" 'include "expand"; full_input | .nodes' "$fx/gc13.json" >"$tmp/stub/graph.json"
jq -L "$fx" 'include "expand"; full_input | .prs' "$fx/gc13.json" >"$tmp/stub/forge.json"

# run_sh [VAR=value …] -- <args…>: sets $rc, $out, $err; the stub log is reset.
run_sh() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  : >"$tmp/log"
  # shellcheck disable=SC2086
  (cd "$repo" && env -u GRAPH_BACKEND -u FORGE -u GITLAB_TOKEN -u GITEA_TOKEN \
     STUB_LOG="$tmp/log" STUB_DIR="$tmp/stub" $envs \
     bash "$sd/tick-plan.sh" "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

run_sh -- --parallel 3
eq "tick-plan.sh reads graph.sh list and forge.sh pr-list --state open" \
  "$(printf 'graph.sh list\nforge.sh pr-list --state open')" "$(cat "$tmp/log")"
eq "tick-plan.sh prints the tick_plan of what the seams return (GC13 board)" \
  "$(jq -c -L "$lib" -L "$fx" 'include "expand"; include "tick-plan"; full_input | tick_plan' "$fx/gc13.json")" \
  "$(jq -c . <<<"$out")"

# GC17: --parallel parsing. Each line: <args> → <mode name> <n>.
while IFS='|' read -r args want; do
  [ -n "$want" ] || continue
  # shellcheck disable=SC2086
  run_sh -- $args
  eq "GC17 tick-plan.sh ${args:-(no flags)} -> $want" "$want" \
    "$(jq -r '"\(.mode.name) \(.mode.n)"' <<<"$out" 2>/dev/null || echo "rc=$rc $err")"
done <<'EOF'
|serial 1
--parallel|parallel 3
--parallel x|parallel 3
--parallel 20|parallel 16
--parallel 1|serial 1
--parallel 0|serial 1
--parallel -2|serial 1
--parallel 2.5|parallel 3
--parallel 08|parallel 8
--parallel 99999999999999999999|parallel 16
--parallel=5|parallel 5
--parallel --auto-merge|parallel 3
--auto-merge --parallel 4|parallel 4
EOF

jq '.[0].status = "approved"' "$tmp/stub/graph.json" >"$tmp/g" && mv "$tmp/g" "$tmp/stub/graph.json"
jq '.[0].mergeable = "clean" | .[0].checks = "success"' "$tmp/stub/forge.json" >"$tmp/f" \
  && mv "$tmp/f" "$tmp/stub/forge.json"
run_sh -- --parallel --auto-merge
eq "tick-plan.sh --auto-merge enables merge actions" '"merge"' "$(jq -c '.actions[0].action' <<<"$out")"
run_sh -- --parallel
eq "tick-plan.sh without --auto-merge emits no merge" '[]' \
  "$(jq -c '[.actions[] | select(.action == "merge")]' <<<"$out")"

run_sh -- --bogus
eq "tick-plan.sh unknown flag -> exit 2" 2 "$rc"
eq "tick-plan.sh unknown flag makes no seam call" "" "$(cat "$tmp/log")"

# GC59 (tick-plan.sh part): an invalid config exits 1 before any seam call.
for envs in "FORGE=gitlab GRAPH_BACKEND=local" "GRAPH_BACKEND=github FORGE=gitlab GITLAB_TOKEN=x" \
            "GRAPH_BACKEND=sqlite"; do
  # shellcheck disable=SC2086
  run_sh $envs -- --parallel 3
  eq "GC59 $envs: tick-plan.sh exits 1" 1 "$rc"
  eq "GC59 $envs: no graph/forge call (stub log empty)" "" "$(cat "$tmp/log")"
  case "$err" in
    *config:*) pass "GC59 $envs: stderr carries the config error" ;;
    *) fail "GC59 $envs: stderr carries the config error" "got: $err" ;;
  esac
done

if [ "$fails" -ne 0 ]; then
  echo "tick-plan tests FAILED" >&2
  exit 1
fi
echo "tick-plan tests passed"
