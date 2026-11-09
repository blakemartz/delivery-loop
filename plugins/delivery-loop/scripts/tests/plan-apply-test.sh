#!/usr/bin/env bash
# Tests for `plan.sh apply` + lib/plan-apply.jq (docs/delivery_graph_spec.md
# §8.3, §9, §4.1; §17 row E2): golden cases GC35 (idempotent on local; id reuse
# across plans refused), GC36 (github: epic issues, tasks with --parent and
# --blocked-by), GC53 (a missing target branch is printed, then pushed) and GC54
# (drift reported, node unchanged, exit 0). Also the gaps lint leaves to apply:
# duplicate deps deduplicated, two plan files sharing a plan id refused, branch
# names checked with `git check-ref-format --branch` before any write,
# whitespace-only via/criteria refused, `#N` deps resolved only against
# `graph.sh list`, duplicate JSON keys refused; plus the promote node (§9).
#
# Offline, under the caller's TMPDIR:
#   - origin is a bare repo in the test's temp dir, and the work repo a clone;
#   - a git shim first on PATH logs every call and refuses any push whose
#     origin is not under the temp dir (never a real remote); every other call
#     is the real git;
#   - a recording, stateful gh shim (fixtures/graph-github-write/gh-shim.sh)
#     serves the github backend and the forge's `pr list` (reconcile).
# bash 3.2: no jq filter containing `{a, b}` inside an eval'd string.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
plan="$scripts/plan.sh"
graph="$scripts/graph.sh"
fx="$here/fixtures/plan-apply"
demo="$fx/demo.plan.json"
realgit="$(command -v git)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-plan-apply-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
st="$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$here/fixtures/graph-github-write/gh-shim.sh" >"$tmp/bin/gh"
cat >"$tmp/bin/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >>"$tmp/git.log"
if [ "\${1:-}" = push ]; then
  url="\$("$realgit" remote get-url origin 2>/dev/null || true)"
  case "\$url" in
    "$tmp"/*) : ;;
    *) echo "git shim: refusing to push to \$url (not a test remote)" >&2; exit 97 ;;
  esac
  [ ! -f "$tmp/fail-push" ] || { echo "git shim: injected push failure" >&2; exit 1; }
fi
exec "$realgit" "\$@"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/git"

fails=0 rc=0 out="" err=""
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else fail "$1" "missing: $3"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "unexpected: $3"; else ok "$1"; fi; }

# fresh_repo [branch…]: a new bare origin holding main (+ the given branches)
# and a fresh clone at $repo; resets the shim state and logs.
fresh_repo() {
  rm -rf "$tmp/origin.git" "$tmp/repo" "$tmp/seed" "$st" "$tmp/fail-push"
  mkdir -p "$st"; echo '[]' >"$st/board.json"; echo '[]' >"$st/prs.json"; : >"$st/log"
  "$realgit" init -q --bare "$tmp/origin.git"
  "$realgit" -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
  "$realgit" init -q "$tmp/seed"
  "$realgit" -C "$tmp/seed" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m seed
  "$realgit" -C "$tmp/seed" push -q "$tmp/origin.git" HEAD:refs/heads/main
  local b
  for b in "$@"; do "$realgit" -C "$tmp/seed" push -q "$tmp/origin.git" "HEAD:refs/heads/$b"; done
  "$realgit" clone -q "$tmp/origin.git" "$tmp/repo"
  repo="$tmp/repo"
  : >"$tmp/git.log"
}

# run [VAR=value …] -- <script> <args…>: in $repo, with both shims on PATH.
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  # shellcheck disable=SC2086
  (cd "$repo" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REPO -u GH_HOST \
     -u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u LIST_LIMIT -u BASE_BRANCH \
     -u GITLAB_TOKEN -u GITEA_TOKEN -u STATE_DIR -u LOCK_WAIT_SECONDS -u SHIM_GH_VERSION \
     -u CLAIM_GRACE_SECONDS -u PLANS_DIR -u MODULES \
     PATH="$tmp/bin:$PATH" SHIM_STATE="$st" MODULES="policy plan" PLANS_DIR=plans/ $envs \
     bash "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
apply_local() { local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
                run GRAPH_BACKEND=local ${e[@]+"${e[@]}"} -- "$plan" apply "$@"; }
apply_gh()    { run -- "$plan" apply "$@"; }
# board_local: the local store, as `graph.sh list` (sorted by id) in $board.
board_local() { run GRAPH_BACKEND=local -- "$graph" list; board=$(jq -c 'sort_by(.id)' <<<"$out"); }
board_gh()    { run -- "$graph" list; board=$(jq -c 'sort_by(.id | tonumber)' <<<"$out"); }
nodef() { jq -c --arg id "$1" ".[] | select(.id == \$id) | $2" <<<"$board"; }
byref() { jq -c --arg r "$1" ".[] | select(.plan_ref == \$r) | $2" <<<"$board"; }
created() { printf '%s\n' "$out" | grep -c '^created: ' || true; }

# --- local backend: GC53, then GC35 -----------------------------------------------
fresh_repo
apply_local -- "$demo"
eq "local apply: exit 0" 0 "$rc"
push='git push origin origin/main:refs/heads/release/x'
has "GC53: prints the exact git push" "$out" "$push"
eq "GC53: the printed push is the command run" "$push" "$(grep '^git push' "$tmp/git.log")"
eq "GC53: printed before any node is created" "$push" \
  "$(printf '%s\n' "$out" | grep -E '^(git push|created: )' | head -n 1)"
eq "GC53: release/x now on origin at origin/main" \
  "$("$realgit" -C "$tmp/origin.git" rev-parse refs/heads/main)" \
  "$("$realgit" -C "$tmp/origin.git" rev-parse --verify --quiet refs/heads/release/x || echo missing)"
eq "local apply: 2 epics + 4 tasks + 1 promote created" 7 "$(created)"
has "local apply: summary line" "$out" "applied (7 created, 0 existing, 0 drift)"
has "duplicate dep: lint warns" "$err" 'task `queue`: duplicate dep `store-schema` (kept the first)'
order=$(printf '%s\n' "$out" | sed -n 's/^created: [a-z]* \([a-z-]*\) .*/\1/p' | tr '\n' ' ')
eq "creation order: epics, tasks topologically, then the promote node" \
  "core ui store-schema queue board-view user-guide demo-promote " "$order"

board_local
eq "local: plan-applied nodes use their plan ids" \
  '["board-view","core","demo-promote","queue","store-schema","ui","user-guide"]' "$(jq -c 'map(.id)' <<<"$board")"
eq "local: plan_ref = <plan>/<id>" '"demo/queue"' "$(nodef queue .plan_ref)"
eq "local: every node targets release/x" '["release/x"]' "$(jq -c 'map(.target_branch) | unique' <<<"$board")"
eq "local: task epic" '"core"' "$(nodef queue .epic)"
eq "duplicate dep: one edge, the first via" '[{"id":"store-schema","via":"lib/store.jq read_store"}]' "$(nodef queue .deps)"
eq "local: module/size" '["plan","M"]' "$(nodef queue '[.module, .size]')"
has "local: body carries the context" "$(nodef queue .body)" 'Order the ready set.'
has "local: body carries the criteria as a checklist" "$(nodef queue .body)" '- [ ] queue test passes'
eq "promote node (§9): kind, deps = the plan's epics, promote_to" \
  '["promote",["core","ui"],"main","release/x",null]' \
  "$(nodef demo-promote '[.kind, [.deps[].id], .promote_to, .target_branch, .epic]')"
eq "promote node title" '"Promote release/x → main"' "$(nodef demo-promote .title)"
eq "statuses after reconcile: no-dep tasks and epics ready; dependents and the promote node blocked" \
  '["blocked","ready","blocked","blocked","ready","ready","ready"]' "$(jq -c 'map(.status)' <<<"$board")"
first_board="$board"

: >"$tmp/git.log"
apply_local -- "$demo"
eq "GC35: second run exit 0" 0 "$rc"
eq "GC35: second run creates 0 nodes" 0 "$(created)"
has "GC35: second run reports every node as existing" "$out" "applied (0 created, 7 existing, 0 drift)"
eq "GC35: second run reports no drift" "" "$(printf '%s\n' "$err" | grep '^drift:' || true)"
eq "GC35: second run pushes nothing (target exists)" "" "$(grep '^git push' "$tmp/git.log" || true)"
board_local
eq "GC35: store unchanged by the second run" "$first_board" "$board"

apply_local -- "$fx/other.plan.json"
eq "GC35: a second plan reusing an id: exit 1" 1 "$rc"
has "GC35: names the reused id" "$err" '`store-schema`: id already exists with plan_ref "demo/store-schema"'
has "GC35: refused before any write" "$err" "apply refused (nothing written)"
board_local
eq "GC35: nothing of the second plan was created (not even its epic)" "$first_board" "$board"

# --- GC54: drift is reported, never overwritten ------------------------------------
run GRAPH_BACKEND=local -- "$graph" update queue '{"title": "Ready queue (renamed by a human)"}'
eq "GC54 setup: a human renames a node" 0 "$rc"
jq '.tasks[3].criteria = ["the guide names every command", "and one more"]' "$demo" >"$tmp/drift.plan.json"
apply_local -- "$tmp/drift.plan.json"
eq "GC54: exit 0" 0 "$rc"
has "GC54: drift: <id> title" "$err" "drift: queue title"
has "GC54: drift: <id> body (the plan's criteria changed)" "$err" "drift: user-guide body"
eq "GC54: exactly those two drift lines" 2 "$(printf '%s\n' "$err" | grep -c '^drift:' || true)"
eq "GC54: 0 created" 0 "$(created)"
board_local
eq "GC54: the node is unchanged" '"Ready queue (renamed by a human)"' "$(nodef queue .title)"
hasnt "GC54: the body is unchanged" "$(nodef user-guide .body)" "and one more"

# --- refusals before any write (local) ---------------------------------------------
fresh_repo
# refused <name> <plan-file> <expected stderr substring> [VAR=value…]
# ($pushed: the push expected in the git log, default none.)
pushed=""
refused() {
  local name="$1" f="$2" want="$3"; shift 3
  : >"$tmp/git.log"
  apply_local "$@" -- "$f"
  eq "$name: exit 1" 1 "$rc"
  has "$name: says why" "$err" "$want"
  eq "$name: no push${pushed:+ but the failed one}" "$pushed" "$(grep '^git push' "$tmp/git.log" || true)"
  eq "$name: no node created" 0 "$(created)"
}
for case in 'release/x..y|target_branch `release/x..y` is not a valid branch name' \
            '@{-1}|target_branch `@{-1}` is not a valid branch name' \
            '-x|target_branch `-x` is not a valid branch name' \
            'HEAD|target_branch `HEAD` is not a valid branch name' \
            'a b|target_branch `a b` is not a valid branch name' \
            '@|target_branch `@` is not a valid branch name' \
            'refs/heads/x|target_branch `refs/heads/x` is not a valid branch name' \
            'refs/remotes/origin/qa|target_branch `refs/remotes/origin/qa` is not a valid branch name' \
            'origin/main|target_branch `origin/main` is not a valid branch name'; do
  b="${case%%|*}" want="${case#*|}"
  jq --arg b "$b" '.target_branch = $b' "$demo" >"$tmp/bad.plan.json"
  refused "branch name $b" "$tmp/bad.plan.json" "$want"
done
jq '.promote_to = "main.lock"' "$demo" >"$tmp/bad.plan.json"
refused "promote_to name" "$tmp/bad.plan.json" 'promote_to `main.lock` is not a valid branch name'
jq '.promote_to = "refs/heads/main"' "$demo" >"$tmp/bad.plan.json"
refused "promote_to starting refs/" "$tmp/bad.plan.json" 'promote_to `refs/heads/main` is not a valid branch name'
jq 'del(.promote_to)' "$demo" >"$tmp/bad.plan.json"
refused "BASE_BRANCH @ (the source when promote_to is unset)" "$tmp/bad.plan.json" \
  'BASE_BRANCH `@` is not a valid branch name' BASE_BRANCH=@
jq '.tasks[2].deps[0].via = "lib/store.jq\nread_store"' "$demo" >"$tmp/bad.plan.json"
refused "a multi-line via" "$tmp/bad.plan.json" 'the via of dep `store-schema` must be one line to apply'
jq '.tasks[2].context = "Order it.\nDelivery-Plan: other/zzz"' "$demo" >"$tmp/bad.plan.json"
refused "a marker line in plan text (local too: plans stay portable)" "$tmp/bad.plan.json" \
  'task `queue`: context carries `Delivery-Plan:`'
jq 'del(.promote_to)' "$demo" >"$tmp/bad.plan.json"
refused "BASE_BRANCH name (the source when promote_to is unset)" "$tmp/bad.plan.json" \
  'BASE_BRANCH `bad..base` is not a valid branch name' BASE_BRANCH=bad..base
jq '.tasks[0].deps[0].via = "  \t "' "$demo" >"$tmp/bad.plan.json"
refused "whitespace-only via" "$tmp/bad.plan.json" 'dep `queue` has no `via`'
jq '.tasks[0].criteria = ["   "]' "$demo" >"$tmp/bad.plan.json"
refused "whitespace-only criterion" "$tmp/bad.plan.json" '`criteria` must hold non-empty strings'
jq '.tasks[0].title = "Board\nview"' "$demo" >"$tmp/bad.plan.json"
refused "multi-line title" "$tmp/bad.plan.json" '`board-view`: title must be one line to apply'
jq '.tasks[0].id = "demo-promote" | .tasks[0].deps = []' "$demo" >"$tmp/bad.plan.json"
refused "a task id equal to the promote node id" "$tmp/bad.plan.json" 'promote node id `demo-promote` collides'
jq '.plan = "a-plan-id-that-is-exactly-forty-chars-ok"' "$demo" >"$tmp/bad.plan.json"
refused "a promote id past 40 chars (local)" "$tmp/bad.plan.json" 'is not a valid local id'
sed 's/"plan": "demo",/"plan": "demo", "plan": "demo2",/' "$demo" >"$tmp/bad.plan.json"
refused "a duplicate JSON key" "$tmp/bad.plan.json" 'duplicate JSON object key'
mkdir -p "$repo/plans"
cp "$demo" "$repo/plans/demo.plan.json"
cp "$demo" "$repo/plans/demo-copy.plan.json"
refused "two plan files sharing a plan id" "$repo/plans/demo.plan.json" \
  'plan id `demo` is also the plan id of plans/demo-copy.plan.json'
rm -rf "$repo/plans"
touch "$tmp/fail-push"
pushed="$push"
refused "a failed git push" "$demo" "git push failed"
pushed=""
rm -f "$tmp/fail-push"
# A local branch named origin/main, on another commit, would win `origin/main`.
"$realgit" -C "$repo" branch -q origin/main "$("$realgit" -C "$repo" -c user.name=t -c user.email=t@example.com \
  commit-tree -m shadow "$("$realgit" -C "$repo" rev-parse 'HEAD^{tree}')")"
refused "origin/<P> shadowed by a local branch" "$demo" "origin/main is ambiguous"
"$realgit" -C "$repo" branch -q -D origin/main
jq '.promote_to = "qa"' "$demo" >"$tmp/bad.plan.json"
refused "the source branch is missing on origin" "$tmp/bad.plan.json" "origin has no branch qa"
board_local
eq "refusals: the store is still empty" '[]' "$board"

# A target branch that exists is never pushed.
fresh_repo release/x
apply_local -- "$demo"
eq "existing target: exit 0" 0 "$rc"
eq "existing target: no push" "" "$(grep '^git push' "$tmp/git.log" || true)"
hasnt "existing target: nothing printed about creating it" "$out" "is missing on origin"

# No promote_to: no promote node; a missing target is cut from BASE_BRANCH.
fresh_repo
jq 'del(.promote_to)' "$demo" >"$tmp/nopromote.plan.json"
apply_local -- "$tmp/nopromote.plan.json"
eq "no promote_to: exit 0" 0 "$rc"
eq "no promote_to: 6 nodes, no promote node" 6 "$(created)"
has "no promote_to: the target is cut from origin/BASE_BRANCH" "$out" 'git push origin origin/main:refs/heads/release/x'

# --- github backend: GC36 ----------------------------------------------------------
B='def L($n): {id: "LA_\($n)", name: $n, description: "", color: "EDEDED"};
   def i($n; $t; $labels; $body; $state): {number: $n, title: $t, state: $state,
     stateReason: (if $state == "CLOSED" then "COMPLETED" else "" end), body: $body,
     labels: [$labels[] | L(.)], assignees: [], comments: [],
     createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
     blockedBy: {nodes: [], totalCount: 0}, parent: null, closedByPullRequestsReferences: []};'
gh_board() { jq -n "$B [i(42; \"Config loader\"; [\"task\", \"status:ready\"]; \"\"; \"CLOSED\"), i(99; \"A plain issue\"; []; \"\"; \"OPEN\")]" >"$st/board.json"; }
# The plan's tasks in reverse, so creation must reorder them topologically.
jq '.tasks |= reverse' "$here/fixtures/plan/valid.plan.json" >"$tmp/gh.plan.json"
fresh_repo release/x
gh_board
apply_gh "$tmp/gh.plan.json"
eq "GC36 github apply: exit 0" 0 "$rc"
eq "GC36: 7 issues created" 7 "$(grep -c '^gh issue create' "$st/log" || true)"
board_gh
core=$(byref demo/core .id | tr -d '"') ui=$(byref demo/ui .id | tr -d '"')
ss=$(byref demo/store-schema .id | tr -d '"') q=$(byref demo/queue .id | tr -d '"')
bv=$(byref demo/board-view .id | tr -d '"') pr=$(byref demo/demo-promote .id | tr -d '"')
eq "GC36: the epic issues carry the epic label" '["epic","epic"]' "$(jq -c '[.[] | select(.plan_ref == "demo/core" or .plan_ref == "demo/ui") | .kind]' <<<"$board")"
cr() { grep '^gh issue create' "$st/log" | grep -F -- "--title $1 " || true; }
has "GC36: an epic is created with --label epic" "$(cr 'Core engine')" "--label epic"
has "GC36: a task is created with --parent <its epic issue>" "$(cr 'Ready queue')" "--parent $core"
has "GC36: ... and --blocked-by its plan dep's issue" "$(cr 'Ready queue')" "--blocked-by $ss"
has "GC36: ... and --blocked-by the existing #42" "$(cr 'Ready queue')" "--blocked-by 42"
has "GC36: board-view is blocked by queue (created first: topological order)" "$(cr 'Board view')" "--blocked-by $q"
eq "GC36: native parent recorded" "$ui" "$(byref demo/board-view .epic | tr -d '"')"
eq "GC36: blocked-by edges" '["42","'"$ss"'"]' "$(byref demo/queue '[.deps[].id] | sort_by(tonumber)')"
eq "GC36: deps resolve before their dependents (issue numbers ascend)" 1 \
  "$( [ "$ss" -lt "$q" ] && [ "$q" -lt "$bv" ] && echo 1 || echo 0)"
has "GC36: body line Delivery-Plan" "$(byref demo/queue .body)" "Delivery-Plan: demo/queue"
has "GC36: body line Delivery-Target" "$(byref demo/queue .body)" "Delivery-Target: release/x"
has "GC36: a via is recorded as a Depends-on line" "$(byref demo/queue .body)" "Depends-on: #$ss (via: lib/store.jq read_store)"
eq "promote issue (github): kind, promote_to, blocked by both epics" \
  '["promote","main",["'"$core"'","'"$ui"'"]]' "$(byref demo/demo-promote '[.kind, .promote_to, ([.deps[].id] | sort_by(tonumber))]')"
has "promote issue: Delivery-Promote-To body line" "$(byref demo/demo-promote .body)" "Delivery-Promote-To: main"
has "promote issue: promote label" "$(grep '^gh issue create' "$st/log" | grep -F -- '--title Promote ')" "--label promote"
eq "promote issue is never claimable" "" "$(run -- "$graph" ready; printf '%s\n' "$out" | grep -F "\"$pr\"" || true)"

: >"$st/log"
apply_gh "$tmp/gh.plan.json"
eq "github second run: exit 0" 0 "$rc"
eq "github second run: no issue created" 0 "$(grep -c '^gh issue create' "$st/log" || true)"
eq "github second run: no drift (trailer lines are not the contract)" "" "$(printf '%s\n' "$err" | grep '^drift:' || true)"

jq --argjson n "$q" 'map(if .number == $n then .title = "Renamed queue" else . end)' "$st/board.json" >"$st/b" && mv "$st/b" "$st/board.json"
: >"$st/log"
apply_gh "$tmp/gh.plan.json"
eq "GC54 github: exit 0" 0 "$rc"
eq "GC54 github: drift: <id> title, nothing else" "drift: queue title" "$(printf '%s\n' "$err" | grep '^drift:' || true)"
eq "GC54 github: no edit to the drifted issue" "" "$(grep -E "^gh issue edit $q( |$)" "$st/log" || true)"
eq "GC54 github: title unchanged" '"Renamed queue"' "$(jq -c --argjson n "$q" '.[] | select(.number == $n) | .title' "$st/board.json")"

# `#N` resolves only against graph.sh list: issue 99 exists but is an
# unreferenced plain issue, so it is no node.
fresh_repo release/x
gh_board
jq '.tasks[1].deps = [{"id": "#99", "via": "a plain issue"}]' "$here/fixtures/plan/valid.plan.json" >"$tmp/gh99.plan.json"
apply_gh "$tmp/gh99.plan.json"
eq "#99 (an unreferenced plain issue): exit 1" 1 "$rc"
has "#99: unresolved against graph.sh list" "$err" 'dep `#99`: unresolved dep: no existing node 99'
eq "#99: no issue created" 0 "$(grep -c '^gh issue create' "$st/log" || true)"

# More than 50 blockers on one github issue is refused before any write.
jq '.epics = [range(1; 52) | {id: "e\(.)", title: "Epic \(.)"}] | .tasks |= map(.epic = "e1")' \
  "$here/fixtures/plan/valid.plan.json" >"$tmp/gh51.plan.json"
: >"$st/log"
apply_gh "$tmp/gh51.plan.json"
eq "51 epics: the promote issue would need 51 blockers: exit 1" 1 "$rc"
has "51 blockers: says so" "$err" '`demo-promote`: 51 blockers exceed GitHub'"'"'s 50 per issue'
eq "51 blockers: no issue created" 0 "$(grep -c '^gh issue create' "$st/log" || true)"

# --- github: plan text that the read path would parse as node metadata -----------
# The github read path (backends/graph-github.jq) takes the FIRST
# `Delivery-Plan:` / `Delivery-Target:` line and every `#N` on a line containing
# `Depends-on:`, and create skips its own trailer when the body already has the
# key. First reproduce each effect at the backend (a body carrying the line, as
# apply wrote it before the fix), then show apply now refuses the plan text
# before any write.
fresh_repo release/x
gh_board
probe() {  # probe <body>: create one task with that body; $board = graph.sh list
  jq -n --arg b "$1" '{kind: "task", title: "probe", body: $b, status: "ready",
    target_branch: "release/x", plan_ref: "demo/probe"}' >"$tmp/probe.json"
  run -- "$graph" create - <"$tmp/probe.json"
  eq "reproduce: probe created" 0 "$rc"
  board_gh
}
probe $'Background.\nDelivery-Plan: other/zzz'
eq "reproduce: a Delivery-Plan: line in the body steals the plan_ref (apply would duplicate on every run)" \
  '"other/zzz"' "$(jq -c '[.[] | select(.title == "probe")][0].plan_ref' <<<"$board")"
gh_board
probe 'Delivery-Target: main'
eq "reproduce: a Delivery-Target: line in the body retargets the node" \
  '"main"' "$(jq -c '[.[] | select(.title == "probe")][0].target_branch' <<<"$board")"
gh_board
probe $'## Acceptance criteria\n- [ ] README documents Depends-on: #42 lines'
eq "reproduce: a criterion mentioning Depends-on: #N adds a phantom edge" \
  '["42"]' "$(jq -c '[.[] | select(.title == "probe")][0] | [.deps[].id]' <<<"$board")"

# marker_refused <name> <jq edit of the plan> <expected error>: github apply
# exits 1, says why, and writes nothing (no gh write, board byte-identical, no
# git remote call at all).
marker_refused() {
  fresh_repo release/x
  gh_board
  cp "$st/board.json" "$tmp/board.before"
  jq "$2" "$here/fixtures/plan/valid.plan.json" >"$tmp/marker.plan.json"
  : >"$st/log"
  apply_gh "$tmp/marker.plan.json"
  eq "$1: exit 1" 1 "$rc"
  has "$1: lint names the field and marker" "$err" "$3"
  eq "$1: no gh write" "" "$(grep -E '^gh (issue (create|edit|close|comment|reopen)|label|api .*(mutation|--method|-X))' "$st/log" || true)"
  eq "$1: board unchanged" "$(cat "$tmp/board.before")" "$(cat "$st/board.json")"
  eq "$1: no push, ls-remote or fetch" "" "$(grep -E '^git (push|ls-remote|fetch)' "$tmp/git.log" || true)"
  apply_gh "$tmp/marker.plan.json"
  eq "$1: a re-run still creates nothing (no duplicates)" 0 "$(grep -c '^gh issue create' "$st/log" || true)"
}
marker_refused "context Delivery-Plan: other/zzz" '.tasks[0].context = "Define the store.\nDelivery-Plan: other/zzz"' \
  'task `store-schema`: context carries `Delivery-Plan:`'
marker_refused "context Delivery-Target: main" '.tasks[0].context = "Delivery-Target: main"' \
  'task `store-schema`: context carries `Delivery-Target:`'
marker_refused "criterion mentioning Depends-on: #1" '.tasks[3].criteria = ["README documents Depends-on: #1 lines"]' \
  'task `user-guide`: criteria[0] carries `Depends-on:`'
marker_refused "epic goal naming another epic" '.epics[1].goal = "Follows epic #42"' \
  'epic `ui`: goal carries `epic #42`'

# Drift no longer hides a marker line: a human inserting `Delivery-Target: main`
# above the trailer block is body drift (and target_branch drift), not just the
# latter.
fresh_repo release/x
gh_board
apply_gh "$tmp/gh.plan.json"
eq "drift setup: github apply exit 0" 0 "$rc"
board_gh
q=$(byref demo/queue .id | tr -d '"')
jq --argjson n "$q" 'map(if .number == $n then .body = "Delivery-Target: main\n" + .body else . end)' \
  "$st/board.json" >"$st/b" && mv "$st/b" "$st/board.json"
: >"$st/log"
apply_gh "$tmp/gh.plan.json"
eq "marker drift: exit 0" 0 "$rc"
eq "marker drift: body and target_branch both reported" $'drift: queue body\ndrift: queue target_branch' \
  "$(printf '%s\n' "$err" | grep '^drift:' || true)"
eq "marker drift: nothing created" 0 "$(grep -c '^gh issue create' "$st/log" || true)"

# --- usage --------------------------------------------------------------------------
run -- "$plan" apply
eq "usage: apply without a file -> exit 2" 2 "$rc"

if [ "$fails" -ne 0 ]; then
  echo "plan-apply tests FAILED" >&2
  exit 1
fi
echo "plan-apply tests passed"
