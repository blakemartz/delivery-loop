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
# #81: GitHub's title/body limits and NUL titles (create and apply, gh 2.96
# and 2.93), the 100-sub-issue cap per epic, no false body drift from CR in
# plan text, and the local stale-lock message.
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
  # A push that exits 0 but leaves origin without the branch (as a ref-update
  # error such as \`cannot lock ref\` can): apply must re-read origin.
  [ ! -f "$tmp/silent-push" ] || { echo "error: cannot lock ref (git shim: injected)" >&2; exit 0; }
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
  rm -rf "$tmp/origin.git" "$tmp/repo" "$tmp/seed" "$st" "$tmp/fail-push" "$tmp/silent-push"
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
            'origin/main|target_branch `origin/main` is not a valid branch name' \
            'HEAD/x|target_branch `HEAD/x` is not a valid branch name' \
            'head/x|target_branch `head/x` is not a valid branch name' \
            'Head/y|target_branch `Head/y` is not a valid branch name' \
            'head|target_branch `head` is not a valid branch name'; do
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
jq '.promote_to = "HEAD/main"' "$demo" >"$tmp/bad.plan.json"
refused "promote_to under HEAD/" "$tmp/bad.plan.json" 'promote_to `HEAD/main` is not a valid branch name'
jq '.promote_to = "head/main"' "$demo" >"$tmp/bad.plan.json"
refused "promote_to under head/ (case-insensitive)" "$tmp/bad.plan.json" 'promote_to `head/main` is not a valid branch name'
jq 'del(.promote_to)' "$demo" >"$tmp/bad.plan.json"
refused "BASE_BRANCH under HEAD/" "$tmp/bad.plan.json" 'BASE_BRANCH `HEAD/main` is not a valid branch name' BASE_BRANCH=HEAD/main
refused "BASE_BRANCH under Head/ (case-insensitive)" "$tmp/bad.plan.json" 'BASE_BRANCH `Head/main` is not a valid branch name' BASE_BRANCH=Head/main
jq '.tasks[2].deps[0].via = "lib/store.jq\nread_store"' "$demo" >"$tmp/bad.plan.json"
refused "a multi-line via" "$tmp/bad.plan.json" 'the via of dep `store-schema` must be one line to apply'
jq '.tasks[2].context = "Order it.\nDelivery-Plan: other/zzz"' "$demo" >"$tmp/bad.plan.json"
refused "a marker line in plan text (local too: plans stay portable)" "$tmp/bad.plan.json" \
  'task `queue`: context carries `Delivery-Plan:`'
for form in 'Depends-on: x\r#1' 'Depends-on:\r#1' 'Depends-on: \r\r#1'; do
  for field in context 'criteria[0]' 'scope[0]'; do
    jq ".tasks[2].${field%%\[*} = (\"$form\" | if \"$field\" == \"context\" then . else [.] end)" "$demo" >"$tmp/bad.plan.json"
    refused "lone CR (local): $field = $form" "$tmp/bad.plan.json" \
      "task \`queue\`: $field carries \`Depends-on: #N\`"
  done
done
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
rm -f "$tmp/fail-push"
touch "$tmp/silent-push"
refused "a git push that exits 0 but creates no branch" "$demo" \
  "git push reported success but origin does not hold refs/heads/release/x"
eq "silent push: origin still has no release/x" "missing" \
  "$("$realgit" -C "$tmp/origin.git" rev-parse --verify --quiet refs/heads/release/x || echo missing)"
pushed=""
rm -f "$tmp/silent-push"
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
# Before #77 the github read path (backends/graph-github.jq) took the FIRST
# `Delivery-Plan:` / `Delivery-Target:` line of the body and every `#N` on any
# line containing `Depends-on:`. It now reads machine keys from the trailer
# block only and `Depends-on:` at line start only: the probes below show each
# old effect is gone at the backend (a body carrying the line, as apply wrote
# it before lint refused it), except a lone CR inside a line-start
# `Depends-on:` line, which still reads as an edge. Apply still refuses the
# plan text before any write (lint, then the composed-body check).
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
eq "fixed at the read (#77): a Delivery-Plan: line in the body no longer steals the plan_ref" \
  '"demo/probe"' "$(jq -c '[.[] | select(.title == "probe")][0].plan_ref' <<<"$board")"
gh_board
probe 'Delivery-Target: main'
eq "fixed at the read (#77): a Delivery-Target: line in the body no longer retargets the node" \
  '"release/x"' "$(jq -c '[.[] | select(.title == "probe")][0].target_branch' <<<"$board")"
gh_board
probe $'## Acceptance criteria\n- [ ] README documents Depends-on: #42 lines'
eq "fixed at the read (#77): a criterion mentioning Depends-on: #N adds no edge" \
  '[]' "$(jq -c '[.[] | select(.title == "probe")][0] | [.deps[].id]' <<<"$board")"

gh_board
probe $'Depends-on: x\r#42'
eq "reproduce: a lone CR inside a Depends-on: line still adds the edge (the reader splits on LF only)" \
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
  'task `user-guide`: criteria[0] carries `Depends-on: #N`'
marker_refused "epic goal naming another epic" '.epics[1].goal = "Follows epic #42"' \
  'epic `ui`: goal carries `epic #42`'
# A lone CR splits lint's lines but not the reader's: each form, in each field.
for form in 'Depends-on: x\r#1' 'Depends-on:\r#1' 'Depends-on: \r\r#1'; do
  for field in context 'criteria[0]' 'scope[0]'; do
    marker_refused "lone CR: $field = $form" ".tasks[0].${field%%\[*} = (\"$form\" | if \"$field\" == \"context\" then . else [.] end)" \
      "task \`store-schema\`: $field carries \`Depends-on: #N\`"
  done
done

# Drift no longer hides a marker line: a human inserting `Delivery-Target: main`
# above the trailer block is body drift. Since #77 it is prose to the reader, so
# target_branch is unchanged (no target_branch drift).
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
eq "marker drift: body reported; target_branch unchanged (a key line above the trailer block is prose, #77)" 'drift: queue body' \
  "$(printf '%s\n' "$err" | grep '^drift:' || true)"
eq "marker drift: nothing created" 0 "$(grep -c '^gh issue create' "$st/log" || true)"

# --- composed-body validation (#29): what create writes, read back by the reader --
# Lint checks each plan string on its own; apply joins some of them (`spec` +
# `spec_refs` into one `Spec:` line, criteria and scope into list items), and
# the reader accepts forms lint does not match (`**Depends-on**:`). So before
# any write apply renders each node body exactly as the backend's create
# writes it (gh_create_body, native and gh < 2.94 forms) and reads it back
# with the backend's own reader (gh_node, gh_migrate_plan; local: its create
# normalizer). The tests below check the outcome end to end: either refused
# with zero writes, or created with exactly the plan's metadata.

# meta: the created nodes' metadata, every id mapped to its plan_ref (an
# existing issue stays #N), so boards with different issue numbers compare.
meta() {
  jq -c '(map({key: .id, value: (.plan_ref // ("#" + .id))}) | from_entries) as $r
    | [ .[] | select(.plan_ref != null)
        | {plan_ref, epic: (if .epic == null then null else $r[.epic] end),
           deps: ([.deps[] | [$r[.id], .via]] | sort), checklist,
           target_branch, promote_to} ] | sort_by(.plan_ref)' <<<"$board"
}
fresh_repo release/x
gh_board
apply_gh "$here/fixtures/plan/valid.plan.json"
board_gh
gh_meta=$(meta)
jq '.tasks[1].deps |= map(select(.id != "#42"))' "$here/fixtures/plan/valid.plan.json" >"$tmp/lvalid.plan.json"
fresh_repo release/x
apply_local -- "$tmp/lvalid.plan.json"
eq "composed baseline (local): exit 0" 0 "$rc"
board_local
local_meta=$(meta)

# composed_refused <name> <jq edit of valid.plan.json> <expected error>: github
# apply exits 1 naming the node and field, and writes nothing.
composed_refused() {
  fresh_repo release/x
  gh_board
  cp "$st/board.json" "$tmp/board.before"
  jq "$2" "$here/fixtures/plan/valid.plan.json" >"$tmp/c.plan.json"
  : >"$st/log"
  run -- "$plan" lint "$tmp/c.plan.json"
  eq "$1: lint alone passes it (the gap)" 0 "$rc"
  apply_gh "$tmp/c.plan.json"
  eq "$1: exit 1" 1 "$rc"
  has "$1: names the node and field" "$err" "$3"
  has "$1: refused before any write" "$err" "apply refused (nothing written)"
  eq "$1: no gh write" "" "$(grep -E '^gh (issue (create|edit|close|comment|reopen)|label|api .*(mutation|--method|-X))' "$st/log" || true)"
  eq "$1: board unchanged" "$(cat "$tmp/board.before")" "$(cat "$st/board.json")"
  eq "$1: no push, ls-remote or fetch" "" "$(grep -E '^git (push|ls-remote|fetch)' "$tmp/git.log" || true)"
}
# composed_intact <name> <jq edit>: apply (github, then local) exits 0 and every
# node reads back with the baseline's metadata (no edge, epic or key injected).
composed_intact() {
  fresh_repo release/x
  gh_board
  jq "$2" "$here/fixtures/plan/valid.plan.json" >"$tmp/c.plan.json"
  apply_gh "$tmp/c.plan.json"
  eq "$1 (github): exit 0" 0 "$rc"
  board_gh
  eq "$1 (github): metadata read back as planned" "$gh_meta" "$(meta)"
  fresh_repo release/x
  jq "$2"' | .tasks[1].deps |= map(select(.id != "#42"))' "$here/fixtures/plan/valid.plan.json" >"$tmp/c.plan.json"
  apply_local -- "$tmp/c.plan.json"
  eq "$1 (local): exit 0" 0 "$rc"
  board_local
  eq "$1 (local): metadata stored as planned" "$local_meta" "$(meta)"
}
gh_reads='the github issue body apply would write reads back'
# The spec/spec_refs join: on one `Spec:` line (mid-line, prose to the reader
# since #77) it is harmless; a line break inside a ref puts `Depends-on:` at a
# line start, and the next ref's `#N` joins it.
composed_intact 'spec_refs ["see Depends-on:", "#1"] on one Spec: line' \
  '.epics[0].spec_refs = ["see Depends-on:", "#1"]'
composed_refused 'spec_refs ["see\nDepends-on:", "#1"] (the join)' \
  '.epics[0].spec_refs = ["see\nDepends-on:", "#1"]' "\`core\`: $gh_reads deps"
composed_intact 'spec "docs/x Depends-on:" + spec_refs "#2" on one Spec: line' \
  '.spec = ["docs/x Depends-on:"] | .epics[0].spec_refs = ["#2"]'
composed_refused 'spec "docs/x\nDepends-on:" + spec_refs "#2": the epic would depend on its own task' \
  '.spec = ["docs/x\nDepends-on:"] | .epics[0].spec_refs = ["#2"]' "\`core\`: $gh_reads deps"
composed_intact 'spec_refs ["Depends-on:", "#3 (via: q)"] on one Spec: line' \
  '.epics[0].spec_refs = ["Depends-on:", "#3 (via: q)"]'
composed_refused 'spec_refs ["x\nDepends-on:", "#3 (via: q)"]' \
  '.epics[0].spec_refs = ["x\nDepends-on:", "#3 (via: q)"]' "\`core\`: $gh_reads deps"
# The bold forms #78's reader accepts and lint's `Depends-on[ \t]*:` misses.
composed_refused 'context **Depends-on**: #2' '.tasks[0].context = "see\n**Depends-on**: #2"' \
  "\`store-schema\`: $gh_reads deps"
composed_refused 'context Depends-on**: #2' '.tasks[0].context = "Depends-on**: #2"' \
  "\`store-schema\`: $gh_reads deps"
composed_refused 'scope **Depends-on**: #2 (a list item)' '.tasks[0].scope = ["**Depends-on**: #2"]' \
  "\`store-schema\`: $gh_reads deps"
composed_refused 'goal **Depends-on**: #2' '.epics[0].goal = "**Depends-on**: #2"' \
  "\`core\`: $gh_reads deps"
composed_refused 'context **Part of epic** #4 (a migrate parent)' '.tasks[0].context = "**Part of epic** #4"' \
  "\`store-schema\`: $gh_reads migrate"
composed_intact 'a criterion **Depends-on**: #2 (a checklist item, not an edge)' \
  '.tasks[0].criteria = ["**Depends-on**: #2"]'

# --- create's own input check, before any write (#76 A1) --------------------------
# github create refuses a via gh_via_ok rejects (a form feed, VT, U+0085,
# U+2028, U+2029: no line break to the reader, so lint, preflight and the
# body read-back all pass it). apply runs create's own check
# (gh_create_errors) on every node first: refused with zero writes, never a
# plan half-applied with earlier nodes created. board-view's via is set, so
# without the check the epics and two tasks would be created first.
for v in 'x\fy' 'x\u000by' 'x\u0085y' 'x y' 'x y'; do
  for ver in 2.96.0 2.93.0; do
    name="via \"$v\" (gh $ver)"
    fresh_repo release/x
    gh_board
    cp "$st/board.json" "$tmp/board.before"
    jq ".tasks[2].deps[0].via = \"$v\"" "$here/fixtures/plan/valid.plan.json" >"$tmp/c.plan.json"
    : >"$st/log"
    run SHIM_GH_VERSION="$ver" -- "$plan" apply "$tmp/c.plan.json"
    eq "$name: exit 1" 1 "$rc"
    has "$name: names create's refusal" "$err" \
      "\`board-view\`: the github backend's create would refuse this node (create: a dep via must be"
    has "$name: refused before any write" "$err" "apply refused (nothing written)"
    eq "$name: no gh write" "" "$(grep -E '^gh (issue (create|edit|close|comment|reopen)|label|api .*(mutation|--method|-X))' "$st/log" || true)"
    eq "$name: board unchanged" "$(cat "$tmp/board.before")" "$(cat "$st/board.json")"
    eq "$name: no push, ls-remote or fetch" "" "$(grep -E '^git (push|ls-remote|fetch)' "$tmp/git.log" || true)"
  done
  # The local backend's create stores any string via, so its apply accepts the
  # plan whole (the via kept as written) and is never half-applied.
  name="via \"$v\" (local)"
  fresh_repo release/x
  jq ".tasks[2].deps[0].via = \"$v\" | .tasks[1].deps |= map(select(.id != \"#42\"))" \
    "$here/fixtures/plan/valid.plan.json" >"$tmp/c.plan.json"
  apply_local -- "$tmp/c.plan.json"
  eq "$name: exit 0, every node created" "0 7" "$rc $(created)"
  board_local
  eq "$name: the via stored as written" "$(jq -c -n "\"$v\"")" "$(byref demo/board-view '.deps[] | select(.id == "queue") | .via')"
done

# Generic guard: for a sample of nodes github create refuses, the composed
# check refuses them too (whatever create's check becomes, apply runs it).
# Each sample is a node as apply hands it to create (deps resolved to issue
# numbers); create runs against the shim and must refuse before any gh call.
fresh_repo
gh_board
guard_base='{"kind": "task", "title": "t", "body": "b", "status": "ready", "epic": "7",
  "deps": [{"id": "8", "via": "v"}], "module": "plan", "size": "S",
  "target_branch": "release/x", "plan_ref": "demo/t"}'
for edit in '.deps[0].via = "x\fy"' '.deps[0].via = "x\u000by"' '.deps[0].via = "x\u0085y"' \
            '.deps[0].via = "x y"' '.deps[0].via = "x y"' '.deps[0].via = " v"' \
            '.deps[0].via = "v "' '.deps[0].via = ""' '.deps[0].via = 5' \
            '.target_branch = "a b"' '.target_branch = "a b"' '.target_branch = "a​b"' \
            '.plan_ref = "demo/t x"' '.plan_ref = "demo/t/u"' '.plan_ref = "demo /t"' \
            '.kind = "promote" | .promote_to = "a　b"' '.kind = "promote" | .promote_to = null' \
            '.promote_to = "main"' '.kind = "external"' '.title = "a\nb"' '.title = ""' \
            '.status = "claimed"' '.size = "XL"' '.module = "module:plan"' '.module = ""' \
            '.body = 5' '.id = "3"' '.claim = null' '.deps[0].id = "x"' '.deps[0].id = "0"' \
            'del(.target_branch) | .base = "a\u00a0b"'; do
  jq -c "$guard_base | $edit" <<<'null' >"$tmp/g.json"
  base=$(jq -r '.base // "main"' "$tmp/g.json")
  jq -c 'del(.base)' "$tmp/g.json" >"$tmp/g.node.json"
  : >"$st/log"
  run BASE_BRANCH="$base" -- "$graph" create - <"$tmp/g.node.json"
  eq "guard [$edit]: create refuses it" 1 "$rc"
  eq "guard [$edit]: create makes no gh write" "" "$(grep -E '^gh issue create' "$st/log" || true)"
  got=$(jq -c -L "$scripts/lib" -L "$scripts/backends" --arg base "$base" --slurpfile n "$tmp/g.node.json" -n \
    'include "plan-verify";
     {steps: [{pid: "7", kind: "epic", exists: true, id: "7"}, {pid: "8", kind: "task", exists: true, id: "8"},
              {pid: "t", kind: $n[0].kind, exists: false, node: $n[0]}]}
     | plan_verify_github({base: $base, nodes: [{id: "7"}, {id: "8"}]}) | length > 0' 2>&1 || true)
  eq "guard [$edit]: the composed check refuses it too" true "$got"
done

# --- GitHub's hard limits (#81): refused by create's own check, before any write --
# GitHub refuses (HTTP 422) a title over 256 characters and a body over 65536;
# the shim does not, so these show the refusal is ours, before any gh call:
# github create refuses the node with no gh issue/api call, and apply (which
# runs the same gh_create_errors) refuses the plan with zero writes, on gh 2.96
# (native relations) and gh 2.93 (text edges). A NUL in a title is refused too
# (gh issue create's argv cannot carry it).
gwrite='^gh (issue (create|edit|close|comment|reopen)|label|api .*(mutation|--method|-X))'
# body_len <native> <node-json>: the body create writes for that node, in that form.
body_len() { jq -n -L "$scripts/lib" -L "$scripts/backends" --argjson n "$2" --argjson v "$1" \
  'include "graph-github"; $n | gh_create_body($v; "main") | length'; }
lim_base='{"kind": "task", "title": "t", "body": "", "status": "ready", "epic": "7",
  "deps": [{"id": "8", "via": "v"}, "9"], "target_branch": "release/x", "plan_ref": "demo/t"}'
# The contract length at which the longer (gh < 2.94 text-edge) body is exactly
# the limit, and at which only the native body still fits. The limit counts the
# body file create writes: the composed body + its final newline.
pad_text=$(( 65536 - 1 - $(body_len 0 "$(jq -c '.body = "x"' <<<"$lim_base")") + 1 ))
pad_native=$(( 65536 - 1 - $(body_len 1 "$(jq -c '.body = "x"' <<<"$lim_base")") + 1 ))
for ver in 2.96.0 2.93.0; do
  fresh_repo
  gh_board
  for case in "title 257 chars|.title = (\"t\" * 257)|create: title is 257 characters; GitHub's limit is 256" \
              "title 257 non-ASCII chars|.title = (\"é\" * 257)|create: title is 257 characters; GitHub's limit is 256" \
              "title with NUL|.title = \"a\\u0000b\"|create: title must not contain NUL" \
              "body over 65536|.body = (\"x\" * 65537)|GitHub's limit is 65536" \
              "native body fits, text-edge body does not|.body = (\"x\" * $pad_native)|GitHub's limit is 65536" \
              "text-edge body one over|.body = (\"x\" * ($pad_text + 1))|GitHub's limit is 65536"; do
    name="${case%%|*}" rest="${case#*|}"; edit="${rest%%|*}" want="${rest#*|}"
    jq -c "$lim_base | $edit" <<<'null' >"$tmp/l.node.json"
    : >"$st/log"
    run SHIM_GH_VERSION="$ver" -- "$graph" create - <"$tmp/l.node.json"
    eq "limits (gh $ver) create [$name]: exit 1" 1 "$rc"
    has "limits (gh $ver) create [$name]: says why" "$err" "$want"
    eq "limits (gh $ver) create [$name]: no gh issue/api call" "" "$(grep -E '^gh (issue|api)' "$st/log" || true)"
  done
  # At the limits exactly, create accepts (both body files <= 65536, title 256).
  for case in "title 256 chars|.title = (\"t\" * 256)" \
              "text-edge body file exactly 65536|.body = (\"x\" * $pad_text)"; do
    name="${case%%|*}" edit="${case#*|}"
    jq -c "$lim_base | $edit" <<<'null' >"$tmp/l.node.json"
    run SHIM_GH_VERSION="$ver" -- "$graph" create - <"$tmp/l.node.json"
    eq "limits (gh $ver) create [$name]: accepted" 0 "$rc"
  done
  eq "limits: the text-edge body at the boundary is 65535 (65536 with the final newline)" 65535 \
    "$(body_len 0 "$(jq -c ".body = (\"x\" * $pad_text)" <<<"$lim_base")")"
  eq "limits: the 'native fits' case: native body 65535 (+ newline: 65536), text-edge body longer" "65535 1" \
    "$(body_len 1 "$(jq -c ".body = (\"x\" * $pad_native)" <<<"$lim_base")") $(( pad_native > pad_text ))"

  # apply: board-view (created after both epics and two tasks) carries the
  # over-limit field, so a check after any write would leave a half-applied plan.
  for case in "title 257 chars|.tasks[2].title = (\"t\" * 257)|create: title is 257 characters" \
              "title with NUL|.tasks[2].title = \"a\\u0000b\"|create: title must not contain NUL" \
              "body over 65536|.tasks[2].context = (\"x\" * 65600)|GitHub's limit is 65536" \
              "epic goal over 65536|.epics[1].goal = (\"x\" * 65600)|GitHub's limit is 65536" \
              "promote_to node title over 256|.promote_to = (\"m\" * 250)|create: title is"; do
    name="limits apply [${case%%|*}] (gh $ver)" rest="${case#*|}"; edit="${rest%%|*}" want="${rest#*|}"
    fresh_repo release/x
    gh_board
    cp "$st/board.json" "$tmp/board.before"
    jq "$edit" "$here/fixtures/plan/valid.plan.json" >"$tmp/c.plan.json"
    : >"$st/log"
    run SHIM_GH_VERSION="$ver" -- "$plan" apply "$tmp/c.plan.json"
    eq "$name: exit 1" 1 "$rc"
    has "$name: names create's refusal" "$err" "the github backend's create would refuse this node ("
    has "$name: says why" "$err" "$want"
    has "$name: refused before any write" "$err" "apply refused (nothing written)"
    eq "$name: no gh write" "" "$(grep -E "$gwrite" "$st/log" || true)"
    eq "$name: board unchanged" "$(cat "$tmp/board.before")" "$(cat "$st/board.json")"
    eq "$name: no push, ls-remote or fetch" "" "$(grep -E '^git (push|ls-remote|fetch)' "$tmp/git.log" || true)"
  done
done

# --- the body limit holds for the issue numbers GitHub really assigns (#84 review) --
# Apply cannot know a new node's number before create, and GitHub's is often
# wider than `graph.sh list`'s highest + 1 (PRs share the sequence; list omits
# unlabelled issues). On gh_board, list's highest is #42, so a count made with
# list-based numbers sees 43.., while the shim assigns 100.. (after #99). Pad
# board-view (created 5th; 3 references to new nodes in the gh < 2.94 body:
# its epic and two deps) so that its longer composed body with 2-digit numbers,
# plus the body file's final newline, is exactly 65536: real 3-digit numbers
# push it over at create. Apply must refuse it before any write (no half-apply).
fresh_repo release/x
gh_board
jq '.tasks[2].context = "x"' "$here/fixtures/plan/valid.plan.json" >"$tmp/w.plan.json"
run SHIM_GH_VERSION=2.93.0 -- "$plan" apply "$tmp/w.plan.json"
eq "wide numbers: the probe apply succeeds" "0 7" "$rc $(created)"
# The body create wrote (the shim stores the body file, final newline included).
bvbody='[.[] | select(.title == "Board view")][0].body | rtrimstr("\n")'
wide_refs=$(jq "$bvbody"' | [match("#1[0-9][0-9](?![0-9])"; "g")] | length' "$st/board.json")
eq "wide numbers: board-view's text-edge body has 3 references to new (3-digit) issues" 3 "$wide_refs"
# Its length with each of those references one digit narrower (43.. instead of
# 100..); the pad makes that length + 1 (the final newline) exactly 65536.
small_len=$(( $(jq "$bvbody | length" "$st/board.json") - wide_refs ))
wpad=$(( 65536 - small_len ))
for ver in 2.96.0 2.93.0; do
  name="wide numbers (gh $ver)"
  fresh_repo release/x
  gh_board
  cp "$st/board.json" "$tmp/board.before"
  jq --argjson n "$wpad" '.tasks[2].context = ("x" * $n)' "$here/fixtures/plan/valid.plan.json" >"$tmp/w.plan.json"
  : >"$st/log"
  run SHIM_GH_VERSION="$ver" -- "$plan" apply "$tmp/w.plan.json"
  eq "$name: exit 1" 1 "$rc"
  eq "$name: 0 created" 0 "$(created)"
  has "$name: names create's refusal" "$err" "the github backend's create would refuse this node ("
  has "$name: refused before any write" "$err" "apply refused (nothing written)"
  eq "$name: no gh write" "" "$(grep -E "$gwrite" "$st/log" || true)"
  eq "$name: board unchanged" "$(cat "$tmp/board.before")" "$(cat "$st/board.json")"
  eq "$name: no push, ls-remote or fetch" "" "$(grep -E '^git (push|ls-remote|fetch)' "$tmp/git.log" || true)"
done

# --- GitHub's sub-issue cap (#81): 100 per parent issue, before any write ---------
# An epic the plan already created (plan_ref demo/core, issue 1) with 99
# existing children; the plan adds 2 more tasks under it -> 101.
cap_board() {  # cap_board <children>
  jq -n --argjson k "$1" "$B"' [ (i(1; "Core engine"; ["epic", "status:ready"];
      "Store and queue\n\nDelivery-Target: release/x\nDelivery-Plan: demo/core"; "OPEN")),
    (range(2; 2 + $k) as $n | i($n; "child \($n)"; ["task", "status:ready", "size:S"];
      "x\n\nDelivery-Target: release/x\nPart of epic #1"; (if $n % 2 == 0 then "OPEN" else "CLOSED" end))
      | .parent = {number: 1}) ]' >"$st/board.json"
}
jq '{schema, plan, target_branch, epics: [.epics[0]],
     tasks: [{id: "t1", epic: "core", title: "T1", module: "plan", size: "S", criteria: ["c"]},
             {id: "t2", epic: "core", title: "T2", module: "plan", size: "S", criteria: ["c"]}]}' \
  "$here/fixtures/plan/valid.plan.json" >"$tmp/cap.plan.json"
for ver in 2.96.0 2.93.0; do
  name="sub-issue cap (gh $ver)"
  fresh_repo release/x
  cap_board 99
  cp "$st/board.json" "$tmp/board.before"
  : >"$st/log"
  run SHIM_GH_VERSION="$ver" -- "$plan" apply "$tmp/cap.plan.json"
  eq "$name: 99 existing + 2 new: exit 1" 1 "$rc"
  has "$name: says why" "$err" "epic \`core\`: 101 sub-issues (99 existing + 2 to create) exceed GitHub's 100 per parent issue"
  has "$name: refused before any write" "$err" "apply refused (nothing written)"
  eq "$name: no gh write" "" "$(grep -E "$gwrite" "$st/log" || true)"
  eq "$name: board unchanged" "$(cat "$tmp/board.before")" "$(cat "$st/board.json")"
  eq "$name: no push, ls-remote or fetch" "" "$(grep -E '^git (push|ls-remote|fetch)' "$tmp/git.log" || true)"
done
# 98 existing + 2 new = 100: accepted (the cap is inclusive).
fresh_repo release/x
cap_board 98
apply_gh "$tmp/cap.plan.json"
eq "sub-issue cap: 98 existing + 2 new = 100: exit 0, 2 created" "0 2" "$rc $(created)"
# A new epic with 101 plan tasks (pure preflight: plan_apply on the normalized plan).
got=$(jq -c -L "$scripts/lib" 'include "plan-apply";
  .tasks = [range(101) as $k | .tasks[0] | .id = "t\($k)" | .deps = [] | .context = "" | .scope = []]
  | .spec = [] | .epics |= map(.goal = "" | .spec_refs = []) | .promote_to = null
  | plan_apply({backend: "github", nodes: []}).errors' "$tmp/cap.plan.json" 2>&1 || true)
has "sub-issue cap: a new epic with 101 plan tasks is refused" "$got" 'epic `core`: 101 sub-issues (0 existing + 101 to create)'
got=$(jq -c -L "$scripts/lib" 'include "plan-apply";
  .tasks = [range(101) as $k | .tasks[0] | .id = "t\($k)" | .deps = [] | .context = "" | .scope = []]
  | .spec = [] | .epics |= map(.goal = "" | .spec_refs = []) | .promote_to = null
  | plan_apply({backend: "local", nodes: []}).errors' "$tmp/cap.plan.json" 2>&1 || true)
hasnt "sub-issue cap: not a local limit" "$got" 'sub-issues'

# --- CR in plan text (#81): no false body drift on re-apply -----------------------
# The stored github body is compared line by line with CRs dropped; the plan's
# own CRs must be normalized the same way, or every re-apply reports body drift.
for ver in 2.96.0 2.93.0; do
  name="CRLF plan (gh $ver)"
  fresh_repo release/x
  gh_board
  jq '.tasks[0].context = "Define\r\nthe store.\r\n" | .tasks[0].criteria = ["passes\r\nall"]
      | .tasks[1].context = "a\rb" | .epics[0].goal = "Store and queue\r\n"' \
    "$here/fixtures/plan/valid.plan.json" >"$tmp/crlf.plan.json"
  run SHIM_GH_VERSION="$ver" -- "$plan" apply "$tmp/crlf.plan.json"
  eq "$name: first apply exit 0, 7 created" "0 7" "$rc $(created)"
  : >"$st/log"
  run SHIM_GH_VERSION="$ver" -- "$plan" apply "$tmp/crlf.plan.json"
  eq "$name: re-apply exit 0" 0 "$rc"
  eq "$name: re-apply reports 0 drift lines" 0 "$(printf '%s\n' "$err" | grep -c '^drift:' || true)"
  has "$name: re-apply summary" "$out" "applied (0 created, 7 existing, 0 drift)"
  eq "$name: re-apply makes no gh write" "" "$(grep -E "$gwrite" "$st/log" || true)"
done
# Real drift in a CRLF plan is still reported.
jq --argjson n "$(jq '[.[] | select(.title == "Store schema")][0].number' "$st/board.json")" \
  'map(if .number == $n then .body = "Edited by a human.\n\n" + .body else . end)' "$st/board.json" >"$st/b" \
  && mv "$st/b" "$st/board.json"
run -- "$plan" apply "$tmp/crlf.plan.json"
eq "CRLF plan: a human body edit is still drift" "drift: store-schema body" "$(printf '%s\n' "$err" | grep '^drift:' || true)"

# --- the local lock, held by a dead process (#81): when a re-run succeeds --------
# A holder killed while it held the lock leaves it behind; the backend breaks
# it only once it is older than LOCK_STALE_SECONDS. apply's message says so.
fresh_repo release/x
dead=$(sh -c 'exit 0' & p=$!; wait "$p" || true; echo "$p")
lockd="$repo/.git/delivery/lock"
mkdir -p "$lockd"
printf '%s %s %s %s\n' "$(uname -n)" "$dead" dead-run "$(( $(date +%s) - 5 ))" >"$lockd/owner"
jq '.tasks[1].deps |= map(select(.id != "#42"))' "$here/fixtures/plan/valid.plan.json" >"$tmp/lock.plan.json"
apply_local LOCK_WAIT_SECONDS=1 LOCK_STALE_SECONDS=120 -- "$tmp/lock.plan.json"
eq "dead holder's lock (5s old, LOCK_STALE_SECONDS=120): exit 1, 0 created" "1 0" "$rc $(created)"
has "dead holder's lock: says the lock is busy" "$err" "the local store's lock is busy (exit 75)"
has "dead holder's lock: says when a re-run succeeds" "$err" \
  "once the lock is older than LOCK_STALE_SECONDS (120s from when it was taken)"
has "dead holder's lock: names the manual remedy" "$err" "graph-local.sh unlock --force"
hasnt "dead holder's lock: not a bare re-run" "$err" "re-run plan.sh apply: it finds"
# Once the lock is older than LOCK_STALE_SECONDS, the same re-run succeeds.
apply_local LOCK_WAIT_SECONDS=1 LOCK_STALE_SECONDS=2 -- "$tmp/lock.plan.json"
eq "dead holder's lock older than LOCK_STALE_SECONDS: the re-run succeeds" "0 7" "$rc $(created)"

# --- usage --------------------------------------------------------------------------
run -- "$plan" apply
eq "usage: apply without a file -> exit 2" 2 "$rc"

if [ "$fails" -ne 0 ]; then
  echo "plan-apply tests FAILED" >&2
  exit 1
fi
echo "plan-apply tests passed"
