#!/usr/bin/env bash
# Tests for promote.sh and tick-merge.sh (docs/delivery_graph_spec.md §9, §10):
# golden cases GC49, GC50, GC51, GC52, GC39 (the tick-merge refusal) and GC59
# (the promote.sh part) — §17 row E4 — plus the merged-result gate of
# tick-merge (a PR green alone but red merged with its base is not merged: it
# gets a rebase action; at the patch budget it escalates to needs-human), a
# conflicting merge, the mergeability re-poll, the post-merge re-read, the
# base-moved and head-moved-during-the-gate refusals, and that no gate worktree
# is left behind. Also: promote.sh labels its PR agent-authored (reconcile then
# closes the node on a merge), releases its claim on SIGTERM during the gate,
# and both scripts' gates resolve the gated tree's own .claude/delivery.conf,
# not the caller's exported config.
# Signal windows: TERM, INT and HUP, each sent to the script's PID alone and
# to its whole process group (Ctrl-C, a hangup, `kill -- -pgid`), while
# promote.sh's `graph claim` has landed (the claim is released, not leaked),
# while its `gh pr create` has recorded the PR (the claim is kept for
# reconcile, not released), and while tick-merge.sh's `gh pr merge` has landed
# (the merge is still reconciled and reported). And a gate that ignores TERM
# is KILLed after a bounded wait, so the caller still exits.
# The claim window pauses a copy of the engine ($tmp/eng: graph.sh patched to
# wait on $SHIM_STATE/pause-claim after the backend claim); the gh windows are
# the shim's pause-create / pause-merge. Each signal run is a job of its own
# (set -m: its own process group, and INT not ignored at entry) with a private
# TMPDIR, since a group signal kills helpers before their own cleanup.
#
# Offline: a throwaway repo under ${TMPDIR:-/tmp} clones a bare local "origin".
# The graph is GRAPH_BACKEND=local (a private STATE_DIR per case); the forge is
# FORGE=github behind a stateful recording gh shim
# (fixtures/promote/gh-shim.sh), and `sleep` is shimmed so re-polls are
# instant. Nothing reaches a real forge.
#
# bash 3.2: no jq filter containing `{a, b}` goes inside an `expect` (eval)
# string, where 3.2 brace-expands it; compute such values first, then `eq`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
fx="$here/fixtures/promote"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-promote-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/shim"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/gh-shim.sh" > "$tmp/bin/gh"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$SHIM_STATE/log"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"

# Isolated git: no host config, hooks or signing.
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$tmp/gitconfig" user.name test
git config --file "$tmp/gitconfig" user.email test@example.invalid
git config --file "$tmp/gitconfig" init.defaultBranch main

# origin: main (two commits), task heads forked from main's first commit (so
# they are behind), rel/same == main, release/x == main + one commit.
git init -q --bare "$tmp/origin.git"
git init -q "$tmp/seed"
(
  cd "$tmp/seed"
  echo base > f; git add f; git commit -q -m base
  git branch fork
  git checkout -q -b task/x--ok fork;   echo ok > ok-file;   git add ok-file;   git commit -q -m ok
  git checkout -q -b task/y--red fork;  echo b > conflict-b; git add conflict-b; git commit -q -m red-with-main
  git checkout -q -b task/z--conf fork; echo zzz > f;        git commit -q -am conflicting
  git checkout -q -b task/c--cnf fork;  mkdir .claude; echo 'MODULES="from-tree"' > .claude/delivery.conf
  git add .claude; git commit -q -m tree-conf
  git checkout -q main
  echo main2 > f; echo a > conflict-a; git add f conflict-a; git commit -q -m main2
  git branch rel/same
  git checkout -q -b release/x; echo feat > feature; git add feature; git commit -q -m feature
  git remote add origin "$tmp/origin.git"
  git push -q origin main rel/same release/x task/x--ok task/y--red task/z--conf task/c--cnf
)
git clone -q "$tmp/origin.git" "$tmp/repo"
repo="$tmp/repo"
mkdir -p "$repo/.claude"
printf 'BASE_BRANCH=main\nSPEC_SOURCES=from-caller-conf\n' > "$repo/.claude/delivery.conf"
sha() { git -C "$repo" rev-parse "origin/$1"; }
main_sha=$(sha main); rel_sha=$(sha release/x)
x_sha=$(sha task/x--ok); y_sha=$(sha task/y--red); z_sha=$(sha task/z--conf); c_sha=$(sha task/c--cnf)

# The gate: records where it ran, runs $tmp/gate-hook when present (a race
# injected mid-gate), hangs while $tmp/gate-hang exists (its pid in
# $tmp/gate-pid; 60 s cap; ignoring TERM while $tmp/gate-trap-term exists),
# and is red when $tmp/gate-red exists or when both
# conflict-a (main's) and conflict-b (task y's) are in the tree.
cat > "$tmp/gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$(pwd) \$(git rev-parse HEAD) \$(git rev-parse --verify --quiet HEAD^2 || echo -)" >> "$tmp/gate-runs"
[ ! -f "$tmp/gate-trap-term" ] || trap '' TERM
[ ! -f "$tmp/gate-hook" ] || bash "$tmp/gate-hook"
if [ -f "$tmp/gate-hang" ]; then
  echo \$\$ > "$tmp/gate-pid"; i=0
  while [ -f "$tmp/gate-hang" ] && [ \$i -lt 600 ]; do command -p sleep 0.1; i=\$((i + 1)); done
fi
if [ -f "$tmp/gate-red" ]; then echo "boom: the gate is red"; exit 1; fi
if [ -f conflict-a ] && [ -f conflict-b ]; then echo "conflict-a and conflict-b together"; exit 1; fi
echo "gate green"
EOF
: > "$tmp/gate-runs"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$tmp/notified" > "$tmp/notify.sh"
# The conf gate: what lib/config.sh resolves inside the gated tree.
cat > "$tmp/conf-gate.sh" <<EOF
#!/usr/bin/env bash
. "$scripts/lib/config.sh"
printf '%s|%s|%s|%s\n' "\$MODULES" "\$GRAPH_BACKEND" "\$STATE_DIR" "\$SPEC_SOURCES" > "$tmp/conf-seen"
EOF
chmod +x "$tmp/gate.sh" "$tmp/notify.sh" "$tmp/conf-gate.sh"

ENV_CLEAR="-u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u BASE_BRANCH -u LIST_LIMIT
  -u GITLAB_TOKEN -u GITEA_TOKEN -u GH_TOKEN -u GH_REPO -u GH_HOST -u GATE_CMD -u PROMOTE_GATE_CMD
  -u WORKTREE_SETUP_CMD -u NOTIFY_ESCALATE_CMD -u TASK_MERGE_METHOD -u PROMOTE_MERGE_METHOD
  -u STATE_DIR -u LOCK_WAIT_SECONDS"

# r <script> <state-dir> [VAR=value …] -- <args…>: sets $rc, $out, $err; the gh
# shim log is reset.
r() {
  local script="$1" st="$2" envs=""; shift 2
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  : > "$tmp/shim/log"
  # shellcheck disable=SC2086
  (cd "$repo" && env $ENV_CLEAR GRAPH_BACKEND=local FORGE=github STATE_DIR="$st" \
     GATE_CMD="bash $tmp/gate.sh" PATH="$tmp/bin:$PATH" SHIM_STATE="$tmp/shim" $envs \
     bash "$scripts/$script" "$@" > "$tmp/out" 2> "$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
g() { local st="$1"; shift; r graph.sh "$st" -- "$@"; [ "$rc" = 0 ] || { echo "setup failed: graph.sh $*: $err" >&2; exit 1; }; }

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
log_has() { grep -qF -- "$1" "$tmp/shim/log"; }
field() { (cd "$repo" && env $ENV_CLEAR GRAPH_BACKEND=local STATE_DIR="$1" bash "$scripts/graph.sh" show "$2") | jq -c "$3"; }
worktrees() { git -C "$repo" worktree list | wc -l | tr -d ' '; }
gate_runs() { wc -l < "$tmp/gate-runs" | tr -d ' '; }
last_gate() { tail -n 1 "$tmp/gate-runs"; }

# A plan board: epic e1 (done) with done task e1-1, an unrelated done task, and
# two promote nodes: release/x -> main (trees differ), rel/same -> main (equal).
board() {
  g "$1" create '{"id":"e1","kind":"epic","title":"Epic one","status":"done","plan_ref":"rel/e1"}'
  g "$1" create '{"id":"e1-1","kind":"task","epic":"e1","title":"first task","size":"S","status":"done","plan_ref":"rel/e1-1"}'
  g "$1" create '{"id":"stray","kind":"task","title":"not in the plan","size":"S","status":"done"}'
  g "$1" create '{"id":"rel-promote","kind":"promote","title":"Promote release/x","deps":["e1"],"target_branch":"release/x","promote_to":"main","plan_ref":"rel/rel-promote"}'
  g "$1" create '{"id":"same-promote","kind":"promote","title":"Promote rel/same","deps":["e1"],"target_branch":"rel/same","promote_to":"main","plan_ref":"same/same-promote"}'
}
events() { wc -l < "$1/events.jsonl" | tr -d ' '; }

# --- GC59: invalid config -> exit 1 before any graph/forge call --------------------
S="$tmp/s59"; board "$S"; before=$(events "$S")
r promote.sh "$S" FORGE=gitlab -- rel-promote
expect "GC59: promote.sh under FORGE=gitlab without GITLAB_TOKEN exits 1" '[ "$rc" = 1 ]'
expect "GC59: the message names GITLAB_TOKEN" 'grep -q GITLAB_TOKEN <<<"$err"'
expect "GC59: no forge call (shim log empty)" '[ ! -s "$tmp/shim/log" ]'
eq "GC59: no graph write (journal unchanged)" "$before" "$(events "$S")"
eq "GC59: the node is still ready" '"ready"' "$(field "$S" rel-promote .status)"
r tick-merge.sh "$S" FORGE=gitlab -- 201 "$x_sha"
expect "tick-merge.sh under the same invalid config exits 1, no forge call" '[ "$rc" = 1 ] && [ ! -s "$tmp/shim/log" ]'

# --- refusals before a claim ---------------------------------------------------------
r promote.sh "$S" -- e1-1
expect "promote.sh on a task node exits 1" '[ "$rc" = 1 ] && grep -q "not a promote node" <<<"$err"'
eq "a refused node is not claimed" 'null' "$(field "$S" e1-1 .claim)"
r promote.sh "$S" -- --x
expect "promote.sh usage error exits 2" '[ "$rc" = 2 ]'

# --- GC49: identical trees -----------------------------------------------------------
r promote.sh "$S" -- same-promote
expect "GC49: exits 0" '[ "$rc" = 0 ]'
eq "GC49: node done" '"done"' "$(field "$S" same-promote .status)"
expect "GC49: note 'nothing to promote' on the node" \
  'tail -n 3 "$S/events.jsonl" | grep "\"op\":\"comment\"" | grep -q "nothing to promote"'
expect "GC49: no PR (no pr create)" '! log_has "pr create"'
eq "GC49: no gate run" 0 "$(gate_runs)"
eq "GC49: stdout result" '"nothing-to-promote"' "$(jq -c .result <<<"$out")"

# --- GC50: red PROMOTE_GATE_CMD ------------------------------------------------------
touch "$tmp/gate-red"
r promote.sh "$S" PROMOTE_GATE_CMD="$tmp/gate.sh" NOTIFY_ESCALATE_CMD="$tmp/notify.sh" -- rel-promote
rm -f "$tmp/gate-red"
expect "GC50: exits 1" '[ "$rc" = 1 ]'
eq "GC50: needs_human set" 'true' "$(field "$S" rel-promote .needs_human)"
eq "GC50: claim released" 'null' "$(field "$S" rel-promote .claim)"
eq "GC50: back to ready" '"ready"' "$(field "$S" rel-promote .status)"
expect "GC50: no PR" '! log_has "pr create"'
expect "GC50: the comment carries the failing output" \
  'grep "\"op\":\"comment\"" "$S/events.jsonl" | grep "PROMOTE-GATE-RED" | grep -q "boom: the gate is red"'
expect "GC50: NOTIFY_ESCALATE_CMD ran" '[ -f "$tmp/notified" ]'
eq "GC50: the gate ran on a fresh tree of origin/release/x" "$rel_sha -" "$(last_gate | cut -d" " -f2-)"
expect "GC50: the gate ran outside the checkout" '[ "$(last_gate | cut -d" " -f1)" != "$repo" ]'
eq "GC50: the gate worktree is removed" 1 "$(worktrees)"

# --- GC51: green gate ----------------------------------------------------------------
S="$tmp/s51"; board "$S"
r promote.sh "$S" -- rel-promote
expect "GC51: exits 0" '[ "$rc" = 0 ]'
expect "GC51: PR head T base P, titled Promote T → P" \
  'log_has "gh pr create --head release/x --base main --title Promote release/x → main --body-file"'
expect "GC51: the PR is opened with --label agent-authored" \
  'grep "^gh pr create " "$tmp/shim/log" | grep -q -- "--label agent-authored"'
expect "GC51: body contains Delivery-Task: <id>" 'grep -qx "Delivery-Task: rel-promote" "$tmp/shim/create-body"'
expect "GC51: body lists the plan's done tasks only" \
  'grep -q "e1-1: first task" "$tmp/shim/create-body" && ! grep -q stray "$tmp/shim/create-body"'
eq "GC51: node in-review" '"in-review"' "$(field "$S" rel-promote .status)"
eq "GC51: stdout names the PR" '{"result":"promoted","pr":150}' "$(jq -c '{result, pr}' <<<"$out")"
eq "GC51: GATE_CMD (PROMOTE_GATE_CMD empty) ran on origin/release/x" "$rel_sha -" "$(last_gate | cut -d" " -f2-)"
eq "GC51: the gate worktree is removed" 1 "$(worktrees)"
eq "the forge recorded the promotion PR labelled agent-authored" '["agent-authored"]' \
  "$(jq -c '.["150"].labels | map(.name)' "$tmp/shim/prs.json")"
# A human merges it; reconcile (rule 3) closes the promote node.
jq '.["150"].state = "MERGED" | .["150"].mergedAt = (now | todate)' "$tmp/shim/prs.json" > "$tmp/shim/prs.new"
mv "$tmp/shim/prs.new" "$tmp/shim/prs.json"
r graph.sh "$S" -- reconcile --fix
expect "reconcile --fix after the merge exits 0" '[ "$rc" = 0 ]'
eq "a merged labelled promotion PR moves the promote node to done" '"done"' "$(field "$S" rel-promote .status)"

# An open promotion PR already on head T into P is reused, not duplicated.
S="$tmp/s51b"; board "$S"
jq -n '{"140": {number: 140, url: "https://github.com/example/repo/pull/140", state: "OPEN",
  headRefName: "release/x", baseRefName: "main", headRefOid: "abc", mergeable: "MERGEABLE",
  mergeStateStatus: "CLEAN", statusCheckRollup: [], body: "Delivery-Task: rel-promote",
  labels: [], comments: [], reviews: [], author: {login: "agent"}, closingIssuesReferences: []}}' \
  > "$tmp/shim/prs.json"
r promote.sh "$S" -- rel-promote
expect "an existing promotion PR is reused (no pr create)" '[ "$rc" = 0 ] && ! log_has "pr create"'
eq "reused PR: stdout and in-review" '140 "in-review"' "$(jq -c .pr <<<"$out") $(field "$S" rel-promote .status)"

# --- promote.sh: SIGTERM during the gate releases the claim ---------------------------
S="$tmp/sterm"; board "$S"
rm -f "$tmp/gate-pid"; touch "$tmp/gate-hang"; : > "$tmp/shim/log"
# shellcheck disable=SC2086
( cd "$repo" && exec env $ENV_CLEAR GRAPH_BACKEND=local FORGE=github STATE_DIR="$S" \
    GATE_CMD="bash $tmp/gate.sh" PATH="$tmp/bin:$PATH" SHIM_STATE="$tmp/shim" \
    bash "$scripts/promote.sh" rel-promote > "$tmp/out" 2> "$tmp/err" ) &
bg=$!
i=0
while [ ! -s "$tmp/gate-pid" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
gate_pid=$(cat "$tmp/gate-pid" 2>/dev/null || echo none)
expect "TERM case: the gate started" '[ "$gate_pid" != none ]'
eq "TERM case: the node is claimed while the gate runs" '"claimed"' "$(field "$S" rel-promote .status)"
kill -TERM "$bg"
wait "$bg" && rc=0 || rc=$?
rm -f "$tmp/gate-hang"
out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
eq "TERM case: promote.sh exits 143" 143 "$rc"
eq "TERM case: the claim is released" 'null' "$(field "$S" rel-promote .claim)"
eq "TERM case: the node is back to ready, not flagged" '"ready" false' \
  "$(field "$S" rel-promote .status) $(field "$S" rel-promote '.needs_human // false')"
expect "TERM case: no PR" '! log_has "pr create"'
expect "TERM case: the gate process is stopped" '! kill -0 "$gate_pid" 2>/dev/null'
eq "TERM case: the gate worktree is removed" 1 "$(worktrees)"

# --- promote.sh: the gate resolves the gated tree's own config --------------------------
S="$tmp/sconf"; board "$S"
g "$S" create '{"id":"conf-promote","kind":"promote","title":"Promote c","target_branch":"task/c--cnf","promote_to":"main"}'
echo '{}' > "$tmp/shim/prs.json"; rm -f "$tmp/conf-seen"
r promote.sh "$S" GATE_CMD="$tmp/conf-gate.sh" MODULES=from-caller -- conf-promote
expect "conf case (promote): exits 0" '[ "$rc" = 0 ]'
eq "conf case (promote): the tree's conf wins; caller env/conf values do not leak" \
  'from-tree|github||docs/*_spec.md' "$(cat "$tmp/conf-seen" 2>/dev/null)"

# --- tick-merge ---------------------------------------------------------------------
M="$tmp/sm"
for t in x y z w h v c b m p; do
  g "$M" create "{\"id\":\"$t\",\"kind\":\"task\",\"title\":\"task $t\",\"size\":\"S\",\"status\":\"approved\"}"
done
g "$M" create '{"id":"pp","kind":"promote","title":"Promote release/x","target_branch":"release/x","promote_to":"main","status":"in-review"}'

# mkpr <n> <head> <sha> <base> <conclusion> <task> [extra-label]
mkpr() {
  jq --arg n "$1" --arg head "$2" --arg sha "$3" --arg base "$4" --arg c "$5" --arg task "$6" --arg extra "${7:-}" \
    '.[$n] = {number: ($n | tonumber), url: "https://github.com/example/repo/pull/\($n)", state: "OPEN",
      headRefName: $head, baseRefName: $base, headRefOid: $sha, mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN",
      statusCheckRollup: [{__typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: $c}],
      body: "Delivery-Task: \($task)",
      labels: ([{name: "agent-authored"}] + (if $extra == "" then [] else [{name: $extra}] end)),
      comments: [], reviews: [], author: {login: "agent"}, closingIssuesReferences: [], mergedAt: null}' \
    "$tmp/shim/prs.json" > "$tmp/shim/prs.new"
  mv "$tmp/shim/prs.new" "$tmp/shim/prs.json"
}
echo '{}' > "$tmp/shim/prs.json"
mkpr 201 task/x--ok "$x_sha" main SUCCESS x
mkpr 202 task/y--red "$y_sha" main SUCCESS y
mkpr 203 task/z--conf "$z_sha" main SUCCESS z
mkpr 204 task/x--ok "$x_sha" main FAILURE w
mkpr 205 release/x "$rel_sha" main SUCCESS pp
mkpr 206 task/x--ok "$x_sha" main SUCCESS h needs-human
mkpr 207 task/x--ok "$x_sha" main SUCCESS v
mkpr 208 task/c--cnf "$c_sha" main SUCCESS c
mkpr 209 task/x--ok "$x_sha" main SUCCESS b
mkpr 210 task/x--ok "$x_sha" main SUCCESS m
mkpr 211 task/y--red "$y_sha" main SUCCESS p
jq '.["211"].comments = [{body: "Patch iteration: 3/3", author: {login: "agent"}}]' "$tmp/shim/prs.json" > "$tmp/shim/prs.new"
mv "$tmp/shim/prs.new" "$tmp/shim/prs.json"

runs0=$(gate_runs)
r tick-merge.sh "$M" -- 201 "$y_sha"
expect "GC52: head moved -> exit 1" '[ "$rc" = 1 ] && grep -q "head moved" <<<"$err"'
expect "GC52: head moved -> no merge request" '! log_has "pr merge"'

r tick-merge.sh "$M" -- 204 "$x_sha"
expect "GC52: checks failure -> exit 1" '[ "$rc" = 1 ] && grep -q "checks=failure" <<<"$err"'
expect "GC52: checks failure -> no merge request" '! log_has "pr merge"'

r tick-merge.sh "$M" -- 205 "$rel_sha"
expect "GC39: a clean+success promotion PR -> exit 1" '[ "$rc" = 1 ] && grep -q "GC39" <<<"$err"'
expect "GC39: no merge request" '! log_has "pr merge"'

r tick-merge.sh "$M" -- 206 "$x_sha"
expect "a needs-human PR -> exit 1, no merge request" '[ "$rc" = 1 ] && grep -q "needs-human" <<<"$err" && ! log_has "pr merge"'
eq "no gate ran for an ineligible PR" "$runs0" "$(gate_runs)"

r tick-merge.sh "$M" -- 202 "$y_sha"
expect "merged result red (green alone, red with main) -> exit 1, no merge request" '[ "$rc" = 1 ] && ! log_has "pr merge"'
eq "the rebase action is emitted" '"rebase" 202 "y"' "$(jq -c .action <<<"$out") $(jq -c .pr <<<"$out") $(jq -c .id <<<"$out")"
eq "the merged-result gate ran on a merge whose first parent is origin/main" "$main_sha" \
  "$(git -C "$repo" rev-parse "$(last_gate | cut -d" " -f2)^1")"
expect "the merged-result gate saw HEAD^2 = the PR head" '[ "$(last_gate | cut -d" " -f3)" = "$y_sha" ]'
eq "the merged-result worktree is removed" 1 "$(worktrees)"

runs1=$(gate_runs)
r tick-merge.sh "$M" -- 203 "$z_sha"
expect "a conflicting merge -> exit 1, rebase action, no merge request" \
  '[ "$rc" = 1 ] && [ "$(jq -r .action <<<"$out")" = rebase ] && grep -q "does not merge cleanly" <<<"$err" && ! log_has "pr merge"'
eq "a conflicting merge runs no gate" "$runs1" "$(gate_runs)"
eq "the conflicted worktree is removed" 1 "$(worktrees)"

rm -f "$tmp/notified"
r tick-merge.sh "$M" NOTIFY_ESCALATE_CMD="$tmp/notify.sh" -- 211 "$y_sha"
expect "patch budget: a red merged result at 3/3 -> exit 1, no merge request" '[ "$rc" = 1 ] && ! log_has "pr merge"'
eq "patch budget: stdout is the needs-human result, not a rebase" '{"pr":211,"id":"p","result":"needs-human"}' \
  "$(jq -c '{pr, id, result}' <<<"$out")"
expect "patch budget: stdout carries the reason" '[ -n "$(jq -r ".reason // empty" <<<"$out")" ]'
eq "patch budget: the node is flagged needs-human" 'true' "$(field "$M" p .needs_human)"
expect "patch budget: the node carries an escalation comment with the gate output" \
  'grep "\"op\":\"comment\"" "$M/events.jsonl" | grep "MERGE-NEEDS-HUMAN" | grep -q "conflict-a and conflict-b together"'
expect "patch budget: NOTIFY_ESCALATE_CMD ran" '[ -f "$tmp/notified" ]'

# The base moves while the gate runs: refused, no merge request.
cat > "$tmp/gate-hook" <<EOF
git --git-dir="$tmp/origin.git" update-ref refs/heads/main \
  "\$(git --git-dir="$tmp/origin.git" commit-tree "$main_sha^{tree}" -p "$main_sha" -m moved)"
EOF
r tick-merge.sh "$M" -- 209 "$x_sha"
rm -f "$tmp/gate-hook"
git --git-dir="$tmp/origin.git" update-ref refs/heads/main "$main_sha"
expect "base moved during the gate -> exit 1, refused" '[ "$rc" = 1 ] && grep -q "origin/main moved from $main_sha" <<<"$err"'
expect "base moved during the gate -> no merge request" '! log_has "pr merge"'
eq "base moved: node stays approved" '"approved"' "$(field "$M" b .status)"

# The head moves while the gate runs: the forge's head pin refuses the merge.
cat > "$tmp/gate-hook" <<EOF
jq '.["210"].headRefOid = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$tmp/shim/prs.json" > "$tmp/shim/prs.hook"
mv "$tmp/shim/prs.hook" "$tmp/shim/prs.json"
EOF
r tick-merge.sh "$M" -- 210 "$x_sha"
rm -f "$tmp/gate-hook"
expect "head moved during the gate -> exit 1, not merged" '[ "$rc" = 1 ] && grep -q "pr-merge failed" <<<"$err"'
expect "head moved during the gate -> gh pr merge never called" '! log_has "gh pr merge"'
eq "head moved: node stays approved" '"approved"' "$(field "$M" m .status)"

# The merged result's own .claude/delivery.conf governs its gate.
rm -f "$tmp/conf-seen"
r tick-merge.sh "$M" GATE_CMD="$tmp/conf-gate.sh" MODULES=from-caller -- 208 "$c_sha"
expect "conf case (tick-merge): merged, exit 0" '[ "$rc" = 0 ]'
eq "conf case (tick-merge): the merged tree's conf wins; caller env/conf values do not leak" \
  'from-tree|github||docs/*_spec.md' "$(cat "$tmp/conf-seen" 2>/dev/null)"

touch "$tmp/shim/merge-noop"
r tick-merge.sh "$M" -- 207 "$x_sha"
rm -f "$tmp/shim/merge-noop"
expect "a merge the re-read does not show merged -> exit 1" '[ "$rc" = 1 ] && log_has "pr merge 207"'
eq "not merged: node stays approved" '"approved"' "$(field "$M" v .status)"

echo 5 > "$tmp/shim/unknown-201"
r tick-merge.sh "$M" -- 201 "$x_sha"
expect "eligible + green merged result -> exit 0" '[ "$rc" = 0 ]'
expect "re-polled past mergeable unknown" 'log_has "sleep"'
expect "merged pinned to the head with TASK_MERGE_METHOD (squash)" \
  'log_has "gh pr merge 201 --squash --match-head-commit $x_sha"'
expect "the gate ran on origin/main merged with the head" \
  '[ "$(last_gate | cut -d" " -f3)" = "$x_sha" ] && [ "$(last_gate | cut -d" " -f1)" != "$repo" ]'
eq "stdout reports the merge" '{"pr":201,"result":"merged"}' "$(jq -c '{pr, result}' <<<"$out")"
eq "reconciled: the task is done" '"done"' "$(field "$M" x .status)"
eq "no gate worktree left behind" 1 "$(worktrees)"

# --- signal windows ------------------------------------------------------------------
# The engine copy whose graph.sh pauses after the backend claim has landed.
eng="$tmp/eng"
mkdir -p "$eng"
cp "$scripts"/*.sh "$eng/"
cp -R "$scripts/lib" "$scripts/backends" "$eng/"
awk '{ print }
  /^    bash "\$backend" claim "\$id" "\$actor"/ {
    print "    if [ -f \"$SHIM_STATE/pause-claim\" ]; then echo $$ > \"$SHIM_STATE/pause-claim.at\"; i=0"
    print "      while [ -f \"$SHIM_STATE/pause-claim\" ] && [ $i -lt 1200 ]; do command -p sleep 0.05; i=$((i + 1)); done; fi"
  }' "$scripts/graph.sh" > "$eng/graph.sh"
grep -q pause-claim "$eng/graph.sh" || { echo "FAIL - could not patch the claim pause into graph.sh" >&2; exit 1; }

# sig_run <script> <state-dir> <pause> <SIG> <pid|group> <args…>: start the
# script (from the engine copy) as its own job, wait until it sits at
# $SHIM_STATE/pause-<pause>, send SIG to its PID or its process group, lift the
# pause and wait. Sets $rc, $out, $err, $paused.
sig_run() {
  local script="$1" st="$2" pause="$3" sig="$4" to="$5" bg i=0; shift 5
  : > "$tmp/shim/log"
  rm -rf "$tmp/sigtmp" "$tmp/shim/pause-$pause.at"; mkdir -p "$tmp/sigtmp"
  touch "$tmp/shim/pause-$pause"
  set -m
  # shellcheck disable=SC2086
  ( cd "$repo" && exec env $ENV_CLEAR GRAPH_BACKEND=local FORGE=github STATE_DIR="$st" \
      GATE_CMD="bash $tmp/gate.sh" PATH="$tmp/bin:$PATH" SHIM_STATE="$tmp/shim" TMPDIR="$tmp/sigtmp" \
      bash "$eng/$script" "$@" > "$tmp/out" 2> "$tmp/err" < /dev/null ) &
  bg=$!
  set +m
  while [ ! -s "$tmp/shim/pause-$pause.at" ] && [ "$i" -lt 300 ]; do command -p sleep 0.1; i=$((i + 1)); done
  if [ -s "$tmp/shim/pause-$pause.at" ]; then paused=yes; else paused=no; fi
  if [ "$to" = group ]; then kill "-$sig" -- "-$bg" 2>/dev/null || true
  else kill "-$sig" "$bg" 2>/dev/null || true; fi
  rm -f "$tmp/shim/pause-$pause"
  wait "$bg" 2>/dev/null && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
signum() { case "$1" in INT) echo 2 ;; HUP) echo 1 ;; TERM) echo 15 ;; esac; }
releases() { grep -c '"op":"release"' "$1/events.jsonl" || true; }

for sig in TERM INT HUP; do
  code=$((128 + $(signum "$sig")))
  for to in pid group; do
    c="$sig to the $to"

    # B: promote.sh, the claim has landed when the signal comes.
    S="$tmp/sc-$sig-$to"; board "$S"; echo '{}' > "$tmp/shim/prs.json"
    sig_run promote.sh "$S" claim "$sig" "$to" rel-promote
    eq "claim window, $c: paused after the backend claim" yes "$paused"
    eq "claim window, $c: promote.sh exits $code" "$code" "$rc"
    eq "claim window, $c: the claim is released, the node ready" 'null "ready"' \
      "$(field "$S" rel-promote .claim) $(field "$S" rel-promote .status)"
    expect "claim window, $c: no gate, no PR" '! log_has "pr create" && [ "$(jq length "$tmp/shim/prs.json")" = 0 ]'

    # A: promote.sh, the PR is recorded when the signal comes.
    S="$tmp/sp-$sig-$to"; board "$S"; echo '{}' > "$tmp/shim/prs.json"
    sig_run promote.sh "$S" create "$sig" "$to" rel-promote
    eq "create window, $c: paused inside gh pr create" yes "$paused"
    eq "create window, $c: promote.sh exits $code" "$code" "$rc"
    eq "create window, $c: the promotion PR exists" '"OPEN"' "$(jq -c '.["150"].state' "$tmp/shim/prs.json")"
    eq "create window, $c: the claim is not released" 0 "$(releases "$S")"
    st_now=$(field "$S" rel-promote .status)
    expect "create window, $c: the node is claimed or in-review, not ready ($st_now)" \
      '[ "$st_now" = "\"claimed\"" ] || [ "$st_now" = "\"in-review\"" ]'
    if [ "$to" = pid ]; then
      eq "create window, $c: the PR is still reported, the node in-review" '150 "in-review"' \
        "$(jq -c .pr <<<"$out") $st_now"
    fi

    # tick-merge.sh, the merge has landed when the signal comes.
    M="$tmp/sm-$sig-$to"
    g "$M" create '{"id":"x","kind":"task","title":"task x","size":"S","status":"approved"}'
    echo '{}' > "$tmp/shim/prs.json"; mkpr 201 task/x--ok "$x_sha" main SUCCESS x
    sig_run tick-merge.sh "$M" merge "$sig" "$to" 201 "$x_sha"
    eq "merge window, $c: paused inside gh pr merge" yes "$paused"
    eq "merge window, $c: tick-merge.sh exits $code" "$code" "$rc"
    eq "merge window, $c: the landed merge is reported on stdout" '{"pr":201,"result":"merged"}' \
      "$(jq -c '{pr, result}' <<<"$out" 2>/dev/null)"
    eq "merge window, $c: reconciled, the task done" '"done"' "$(field "$M" x .status)"
  done
done
eq "signal windows: no gate worktree left behind" 1 "$(worktrees)"

# --- dl_gate_cleanup: a gate that ignores TERM is KILLed after a bounded wait ---------
S="$tmp/skill"; board "$S"; echo '{}' > "$tmp/shim/prs.json"
rm -f "$tmp/gate-pid"; touch "$tmp/gate-hang" "$tmp/gate-trap-term"; : > "$tmp/shim/log"
rm -rf "$tmp/sigtmp"; mkdir -p "$tmp/sigtmp"
# shellcheck disable=SC2086
( cd "$repo" && exec env $ENV_CLEAR GRAPH_BACKEND=local FORGE=github STATE_DIR="$S" \
    GATE_CMD="bash $tmp/gate.sh" PATH="$tmp/bin:$PATH" SHIM_STATE="$tmp/shim" TMPDIR="$tmp/sigtmp" \
    bash "$scripts/promote.sh" rel-promote > "$tmp/out" 2> "$tmp/err" ) &
bg=$!
i=0
while [ ! -s "$tmp/gate-pid" ] && [ "$i" -lt 300 ]; do command -p sleep 0.1; i=$((i + 1)); done
gate_pid=$(cat "$tmp/gate-pid" 2>/dev/null || echo none)
expect "TERM-ignoring gate: the gate started" '[ "$gate_pid" != none ]'
t0=$(date +%s)
kill -TERM "$bg"
wait "$bg" && rc=0 || rc=$?
elapsed=$(( $(date +%s) - t0 ))
rm -f "$tmp/gate-hang" "$tmp/gate-trap-term"
out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
eq "TERM-ignoring gate: promote.sh exits 143" 143 "$rc"
expect "TERM-ignoring gate: the exit is bounded (${elapsed}s, under 20s; the gate would hang 60s)" '[ "$elapsed" -lt 20 ]'
expect "TERM-ignoring gate: the gate was KILLed" '! kill -0 "$gate_pid" 2>/dev/null && grep -q "sending KILL" <<<"$err"'
eq "TERM-ignoring gate: the claim is released" 'null' "$(field "$S" rel-promote .claim)"
eq "TERM-ignoring gate: the gate worktree is removed" 1 "$(worktrees)"

exit "$fails"
