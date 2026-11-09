#!/usr/bin/env bash
# Tests for promote.sh and tick-merge.sh (docs/delivery_graph_spec.md §9, §10):
# golden cases GC49, GC50, GC51, GC52, GC39 (the tick-merge refusal) and GC59
# (the promote.sh part) — §17 row E4 — plus the merged-result gate of
# tick-merge (a PR green alone but red merged with its base is not merged: it
# gets a rebase action), a conflicting merge, the mergeability re-poll, the
# post-merge re-read, and that no gate worktree is left behind.
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
  git checkout -q main
  echo main2 > f; echo a > conflict-a; git add f conflict-a; git commit -q -m main2
  git branch rel/same
  git checkout -q -b release/x; echo feat > feature; git add feature; git commit -q -m feature
  git remote add origin "$tmp/origin.git"
  git push -q origin main rel/same release/x task/x--ok task/y--red task/z--conf
)
git clone -q "$tmp/origin.git" "$tmp/repo"
repo="$tmp/repo"
mkdir -p "$repo/.claude"
echo 'BASE_BRANCH=main' > "$repo/.claude/delivery.conf"
sha() { git -C "$repo" rev-parse "origin/$1"; }
main_sha=$(sha main); rel_sha=$(sha release/x)
x_sha=$(sha task/x--ok); y_sha=$(sha task/y--red); z_sha=$(sha task/z--conf)

# The gate: records where it ran, red when $tmp/gate-red exists or when both
# conflict-a (main's) and conflict-b (task y's) are in the tree.
cat > "$tmp/gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$(pwd) \$(git rev-parse HEAD) \$(git rev-parse --verify --quiet HEAD^2 || echo -)" >> "$tmp/gate-runs"
if [ -f "$tmp/gate-red" ]; then echo "boom: the gate is red"; exit 1; fi
if [ -f conflict-a ] && [ -f conflict-b ]; then echo "conflict-a and conflict-b together"; exit 1; fi
echo "gate green"
EOF
: > "$tmp/gate-runs"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$tmp/notified" > "$tmp/notify.sh"
chmod +x "$tmp/gate.sh" "$tmp/notify.sh"

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
expect "GC51: body contains Delivery-Task: <id>" 'grep -qx "Delivery-Task: rel-promote" "$tmp/shim/create-body"'
expect "GC51: body lists the plan's done tasks only" \
  'grep -q "e1-1: first task" "$tmp/shim/create-body" && ! grep -q stray "$tmp/shim/create-body"'
eq "GC51: node in-review" '"in-review"' "$(field "$S" rel-promote .status)"
eq "GC51: stdout names the PR" '{"result":"promoted","pr":150}' "$(jq -c '{result, pr}' <<<"$out")"
eq "GC51: GATE_CMD (PROMOTE_GATE_CMD empty) ran on origin/release/x" "$rel_sha -" "$(last_gate | cut -d" " -f2-)"
eq "GC51: the gate worktree is removed" 1 "$(worktrees)"

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

# --- tick-merge ---------------------------------------------------------------------
M="$tmp/sm"
for t in x y z w h v; do
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

exit "$fails"
