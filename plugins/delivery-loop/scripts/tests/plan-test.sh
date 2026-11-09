#!/usr/bin/env bash
# Tests for plan.sh lint/render + lib/plan-lint.jq + lib/plan-render.jq
# (docs/delivery_graph_spec.md §8.1, §8.2, §8.4, §11): golden cases GC34, GC37,
# the lint assertions of GC6 and GC7, and the `plan.sh` part of GC59 (§12; §17
# row E1). Also: `#N` dep normalization, Mermaid-safe labels.
#
# Offline. Runs a copy of the scripts directory in a throwaway git repo (so the
# host repo's .claude/delivery.conf never leaks in), with graph.sh replaced by a
# stub that logs each call and answers `list` from $STUB_NODES.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fx="$here/fixtures/plan"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-plan-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done; fails=1; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
# has <name> <haystack> <needle>: fixed-string containment.
has() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"
  else fail "$1" "missing: $3" "in: $2"; fi
}

sd="$tmp/sd"
cp -R "$here/.." "$sd"
cat >"$sd/graph.sh" <<'EOF'
#!/usr/bin/env bash
echo "graph.sh $*" >>"$STUB_LOG"
[ "$1" = list ] && cat "$STUB_NODES"
EOF
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
echo '[{"id": "42"}, {"id": "7"}]' >"$tmp/nodes.json"

# run [VAR=value …] -- <plan.sh args…>: sets $rc, $out, $err; the stub log is
# reset. MODULES defaults to "policy plan"; PLANS_DIR to the empty plans/.
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  : >"$tmp/log"
  # shellcheck disable=SC2086
  (cd "$repo" && env -u GRAPH_BACKEND -u FORGE -u GITLAB_TOKEN -u GITEA_TOKEN -u BASE_BRANCH \
     MODULES="policy plan" PLANS_DIR=plans/ STUB_LOG="$tmp/log" STUB_NODES="$tmp/nodes.json" $envs \
     bash "$sd/plan.sh" "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
errors() { printf '%s\n' "$err" | grep -c ': error: ' || true; }

# --- GC34: lint ---------------------------------------------------------------------
run -- lint "$fx/valid.plan.json"
eq "GC34 valid plan: exit 0" 0 "$rc"
eq "GC34 valid plan: no errors or warnings" "" "$err"
has "GC34 valid plan: ok line" "$out" "ok (2 epics, 4 tasks)"
eq "valid plan with a #42 dep reads graph.sh list once" "graph.sh list" "$(cat "$tmp/log")"

run -- lint "$fx/gc34-size-l.plan.json"
eq "GC34 size L: exit 0" 0 "$rc"
has "GC34 size L: warning names the task" "$err" "warning: task \`a\`: size L"
eq "GC34 size L: no errors" 0 "$(errors)"
eq "a plan with no external dep never reads the graph" "" "$(cat "$tmp/log")"

# One fixture per §8.2 bullet: <fixture>|<substring of the expected error>.
while IFS='|' read -r name want; do
  [ -n "$name" ] || continue
  run -- lint "$fx/gc34-$name.plan.json"
  eq "GC34 $name: exit 1" 1 "$rc"
  has "GC34 $name: names the error" "$err" "$want"
done <<'EOF'
schema|plan: `schema` must be 1 (got 2)
dup-id|plan: duplicate id `a`
malformed-id|task `Bad_Id`: malformed id "Bad_Id"
unresolved-dep|task `b`: dep `ghost`: unresolved dep: not a task in this plan or an existing node
cycle|plan: cycle: a -> b -> a
no-via|task `b`: dep `a` has no `via`
module|task `a`: module `frontend` is not in MODULES ∪ {infra, docs} (allowed: docs infra plan policy)
size|task `a`: size "XL" is not S/M/L
empty-criteria|task `a`: `criteria` is empty
EOF
run -- lint "$fx/gc34-schema.plan.json"
has "GC34 schema: a non-string title is an error" "$err" "\`title\` must be a non-empty string (got 7)"
eq "GC34 schema: both errors listed" 2 "$(errors)"

# GC6 / GC7 lint assertions.
run -- lint "$fx/gc34-cycle.plan.json"
eq "GC6 lint: exactly one error, the named cycle" "plan.sh: $fx/gc34-cycle.plan.json: error: plan: cycle: a -> b -> a" "$err"
# A 3-task SCC whose representative cycle skips one member: one error, naming
# the cycle and the members (graph.jq cycle_text).
jq '.tasks[1].deps += [{"id": "c", "via": "c.sh"}]
    | .tasks += [.tasks[0] | .id = "c" | .title = "Task C" | .deps = [{"id": "a", "via": "a.sh"}]]' \
  "$fx/gc34-cycle.plan.json" >"$tmp/scc.plan.json"
run -- lint "$tmp/scc.plan.json"
eq "GC6 lint: one error per SCC, naming its members" \
  "plan.sh: $tmp/scc.plan.json: error: plan: cycle: a -> b -> a (SCC: a, b, c)" "$err"
run -- lint "$fx/gc34-unresolved-dep.plan.json"
eq "GC7 lint: the unresolved dep is checked against graph.sh list" "graph.sh list" "$(cat "$tmp/log")"
eq "GC7 lint: one error" 1 "$(errors)"

# Cross-plan: two plans in PLANS_DIR share target_branch release/x with
# different promote_to.
mkdir -p "$repo/plans"
cp "$fx/valid.plan.json" "$repo/plans/valid.plan.json"
run -- lint plans/valid.plan.json
eq "GC34 cross-plan: a plan alone in PLANS_DIR is not compared with itself" 0 "$rc"
cp "$fx/gc34-cross-plan.plan.json" "$repo/plans/other.plan.json"
run -- lint plans/valid.plan.json
eq "GC34 cross-plan: exit 1" 1 "$rc"
has "GC34 cross-plan: names both promote_to values and the other file" "$err" \
  'plan: target_branch `release/x` has promote_to "main" here but "qa" in plans/other.plan.json'
# The same plan under another plan id (a shared plan id is its own error).
jq '.plan = "fx-third"' "$fx/gc34-cross-plan.plan.json" >"$tmp/cross.plan.json"
run -- lint "$tmp/cross.plan.json"
has "GC34 cross-plan: a plan outside PLANS_DIR is still checked against it" "$err" \
  'promote_to "qa" here but "main" in plans/valid.plan.json'
run PLANS_DIR=elsewhere -- lint plans/valid.plan.json
eq "GC34 cross-plan: PLANS_DIR is honored (an empty dir: no conflict)" 0 "$rc"
run BASE_BRANCH=release/x -- lint "$tmp/cross.plan.json"
eq "cross-plan: still compared when target_branch is explicit and equals BASE_BRANCH" 1 "$rc"
jq 'del(.target_branch)' "$tmp/cross.plan.json" >"$tmp/no-target.plan.json"
run BASE_BRANCH=release/x -- lint "$tmp/no-target.plan.json"
has "cross-plan: an absent target_branch defaults to BASE_BRANCH" "$err" 'target_branch `release/x` has promote_to "qa"'
run -- lint "$tmp/no-target.plan.json"
eq "cross-plan: default target main does not collide with release/x" 0 "$rc"
rm -rf "$repo/plans"

# Lint lists every error, not the first.
jq '.tasks[1].id = "a" | .tasks[0].module = "frontend" | .tasks[0].deps = [{"id": "b"}]
    | .tasks += [{"id": "c", "epic": "nope", "title": "C", "module": "plan", "size": "S",
                  "deps": [{"id": "d", "via": "x"}, {"id": "c", "via": "self"}], "criteria": [],
                  "extra": 1}]' \
  "$fx/gc34-cycle.plan.json" >"$tmp/many.plan.json"
run -- lint "$tmp/many.plan.json"
eq "every error is listed: exit 1" 1 "$rc"
for want in "duplicate id \`a\`" "module \`frontend\`" "dep \`b\` has no \`via\`" \
            "task \`c\`: epic \`nope\` is not an epic in this plan" "task \`c\`: \`criteria\` is empty" \
            "task \`c\`: unexpected field \`extra\`" "dep \`d\`: unresolved dep" "cycle: c -> c"; do
  has "every error is listed: $want" "$err" "$want"
done

# More schema checks.
for case in 'del(.tasks)|plan: missing field `tasks`' \
            '.tasks = []|plan: `tasks` must be a non-empty array' \
            '.plan = "Demo Plan"|plan: malformed plan id "Demo Plan"' \
            '.promote_to = "release/x"|promote_to must differ from target_branch' \
            '.target_branch = 3|plan: `target_branch` must be a non-empty string' \
            '.tasks[0].deps = [{"id": "b", "via": 3}]|`via` must be a string' \
            '.tasks[0].deps = "b"|`deps` must be an array' \
            '.tasks[0].deps = [{"id": "store-schema", "via": "x"}]|dep `store-schema`: unresolved dep' \
            '.tasks[0].deps = [{"id": "e", "via": "x"}]|dep `e`: unresolved dep: names an epic' \
            '.tasks[0].deps = [{"id": "a--b", "via": "x"}]|dep `a--b`: malformed dep id' \
            '.epics[0].id = "e-"|epic `e-`: malformed id' \
            '.tasks[1].size = null|size null is not S/M/L' \
            '.epics = [7]|epics[0]: must be an object'; do
  filter="${case%%|*}" want="${case#*|}"
  jq "$filter" "$fx/gc34-size-l.plan.json" >"$tmp/case.plan.json"
  run -- lint "$tmp/case.plan.json"
  if [ "$rc" = 1 ] && printf '%s\n' "$err" | grep -qF -- "$want"; then pass "schema: $filter -> $want"
  else fail "schema: $filter -> $want" "rc=$rc" "err: $err"; fi
done

printf '{"schema": 1,' >"$tmp/broken.plan.json"
run -- lint "$tmp/broken.plan.json"
eq "not JSON: exit 1" 1 "$rc"
has "not JSON: says so" "$err" "plan: not valid JSON"
printf '{}\n{}\n' >"$tmp/two.plan.json"
run -- lint "$tmp/two.plan.json"
has "two JSON documents: refused" "$err" "expected one JSON document, found 2"
run -- lint "$tmp/missing.plan.json"
eq "missing file: exit 1" 1 "$rc"

# Gaps closed for apply (it runs lint first): blank via/criteria/titles,
# duplicate deps, duplicate JSON keys, two plan files sharing a plan id.
for case in '.tasks[1].deps[0].via = " \t"|dep `store-schema` has no `via`' \
            '.tasks[0].criteria = ["ok", "  "]|`criteria` must hold non-empty strings' \
            '.tasks[0].title = "   "|task `store-schema`: `title` must be a non-empty string' \
            '.epics[0].title = "\n"|epic `core`: `title` must be a non-empty string'; do
  filter="${case%%|*}" want="${case#*|}"
  jq "$filter" "$fx/valid.plan.json" >"$tmp/case.plan.json"
  run -- lint "$tmp/case.plan.json"
  if [ "$rc" = 1 ] && printf '%s\n' "$err" | grep -qF -- "$want"; then pass "blank text: $filter -> $want"
  else fail "blank text: $filter -> $want" "rc=$rc" "err: $err"; fi
done
jq '.tasks[2].deps += [{"id": "queue", "via": "again"}, {"id": "#42", "via": "x"}]
    | .tasks[1].deps += [{"id": "#42", "via": "again"}]' "$fx/valid.plan.json" >"$tmp/dup-deps.plan.json"
run -- lint "$tmp/dup-deps.plan.json"
eq "duplicate deps: still valid (exit 0)" 0 "$rc"
has "duplicate deps: warned" "$err" 'warning: task `board-view`: duplicate dep `queue` (kept the first)'
has "duplicate deps: #42 twice is a duplicate" "$err" 'warning: task `queue`: duplicate dep `42` (kept the first)'
jq -L "$here/../lib" --argjson ctx '{"backend": "github", "base_branch": "main", "modules": ["policy", "plan"], "nodes": ["42"], "others": []}' \
  -c 'include "plan-lint"; plan_lint($ctx) | .plan.tasks[] | select(.id == "queue") | [.deps[] | .via]' \
  "$tmp/dup-deps.plan.json" >"$tmp/deps.json"
eq "duplicate deps: normalized to the first of each" '["lib/store.jq read_store","the existing config loader"]' "$(cat "$tmp/deps.json")"
sed 's/"plan": "demo",/"plan": "demo", "plan": "demo-two",/' "$fx/valid.plan.json" >"$tmp/dupkey.plan.json"
run -- lint "$tmp/dupkey.plan.json"
eq "duplicate JSON key: exit 1" 1 "$rc"
has "duplicate JSON key: says so" "$err" "duplicate JSON object key"
mkdir -p "$repo/plans"
cp "$fx/valid.plan.json" "$repo/plans/a.plan.json"
cp "$fx/valid.plan.json" "$repo/plans/b.plan.json"
run -- lint plans/a.plan.json
eq "shared plan id: exit 1" 1 "$rc"
has "shared plan id: names the other file" "$err" 'plan: plan id `demo` is also the plan id of plans/b.plan.json'
rm -rf "$repo/plans"

# --- §8.1: existing-node deps ("#42" on github) -----------------------------------
echo '[{"id": "7"}]' >"$tmp/nodes-no42.json"
run STUB_NODES="$tmp/nodes-no42.json" -- lint "$fx/valid.plan.json"
has "#42 with no node 42 is unresolved" "$err" "task \`queue\`: dep \`#42\`: unresolved dep: no existing node 42"
jq '.tasks[0].deps = [{"id": "7", "via": "bare existing id"}]' "$fx/gc34-size-l.plan.json" >"$tmp/bare.plan.json"
run -- lint "$tmp/bare.plan.json"
eq "a bare id that is an existing node resolves" 0 "$rc"
run GRAPH_BACKEND=local -- lint "$fx/valid.plan.json"
has "on the local backend #42 is a malformed dep id" "$err" "dep \`#42\`: malformed dep id"
cp "$sd/graph.sh" "$tmp/graph.sh.ok"
printf '#!/usr/bin/env bash\necho "graph.sh $*" >>"$STUB_LOG"\nexit 4\n' >"$sd/graph.sh"
run -- lint "$fx/valid.plan.json"
eq "a failed graph read: exit 1" 1 "$rc"
has "a failed graph read: says which deps it could not resolve" "$err" 'cannot resolve deps ["42"]'
jq '.tasks[0].size = "XL"' "$fx/valid.plan.json" >"$tmp/xl.plan.json"
run -- lint "$tmp/xl.plan.json"
has "a failed graph read still lists the other errors" "$err" 'size "XL" is not S/M/L'
cp "$tmp/graph.sh.ok" "$sd/graph.sh"

jq -L "$here/../lib" --argjson ctx '{"backend": "github", "base_branch": "main", "modules": ["policy", "plan"], "nodes": ["42"], "others": []}' \
  -c 'include "plan-lint"; plan_lint($ctx) | .plan.tasks[] | select(.id == "queue") | .deps' \
  "$fx/valid.plan.json" >"$tmp/deps.json"
eq "normalized deps: #42 -> {id: \"42\", ref: node}; plan tasks ref: task" \
  '[{"id":"store-schema","via":"lib/store.jq read_store","ref":"task"},{"id":"42","via":"the existing config loader","ref":"node"}]' \
  "$(cat "$tmp/deps.json")"

# --- GC37: render -------------------------------------------------------------------
run -- render "$fx/valid.plan.json"
eq "GC37 render: exit 0" 0 "$rc"
eq "GC37 render: golden Mermaid (fixtures/plan/valid.mmd)" "$(cat "$fx/valid.mmd")" "$out"
eq "GC37 render: one labeled edge per dep" \
  "$(jq '[.tasks[].deps // [] | length] | add' "$fx/valid.plan.json")" \
  "$(printf '%s\n' "$out" | grep -cE -- '-->\|"[^"]+"\|')"
eq "GC37 render: one node per task" 4 "$(printf '%s\n' "$out" | grep -cE '^    t_[a-z0-9_]+\["')"
has "GC37 render: epic subgraph" "$out" '  subgraph e_core["core: Core engine"]'
has "GC37 render: the promote node" "$out" '  promote{{"promote: release/x → main"}}'
has "GC37 render: each epic feeds the promote node" "$out" '  e_ui --> promote'
eq "render never reads the graph" "" "$(cat "$tmp/log")"
jq '.promote_to = null' "$fx/valid.plan.json" >"$tmp/no-promote.plan.json"
run -- render "$tmp/no-promote.plan.json"
eq "render without promote_to: no promote node" 0 "$(printf '%s\n' "$out" | grep -c promote || true)"
run -- render "$fx/gc34-cycle.plan.json"
eq "render refuses a plan with lint errors" 1 "$rc"
has "render says why" "$err" "render needs a plan that passes lint"

# Mermaid safety: titles, epic titles and vias carrying quotes, brackets,
# pipes, braces, angle brackets, backticks, entity look-alikes and newlines.
evil_title='He said "hi" [x] | y {z} <b>b</b> #quot; `c` end
second line'
jq --arg t "$evil_title" '.tasks[0].title = $t | .epics[0].title = "E \"q\" ]) | p\nnl"
    | .tasks[1].deps[0].via = "a|b \"c\" [d] -->|x| e\r\nf"' \
  "$fx/valid.plan.json" >"$tmp/evil.plan.json"
run -- render "$tmp/evil.plan.json"
eq "Mermaid safety: exit 0" 0 "$rc"
eq "Mermaid safety: newlines never split a statement (same line count as the clean plan)" \
  "$(wc -l <"$fx/valid.mmd" | tr -d ' ')" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
lab='[^]["|{}<>`]*'
grammar="^(flowchart TD|  end|  subgraph e_[a-z0-9_]+\[\"$lab\"\]|    t_[a-z0-9_]+\[\"$lab \[[a-z0-9]+/[SML]\]\"\]|  n_[a-z0-9_]+\[\"$lab\"\]|  promote\{\{\"$lab\"\}\}|  [tn]_[a-z0-9_]+ -->\|\"$lab\"\| t_[a-z0-9_]+|  e_[a-z0-9_]+ --> promote)$"
bad="$(printf '%s\n' "$out" | grep -vE "$grammar" || true)"
eq "Mermaid safety: every line matches the statement grammar (no raw syntax char in a label)" "" "$bad"
decode() {
  jq -Rr 'gsub("#quot;"; "\"") | gsub("#91;"; "[") | gsub("#93;"; "]") | gsub("#124;"; "|")
          | gsub("#123;"; "{") | gsub("#125;"; "}") | gsub("#lt;"; "<") | gsub("#gt;"; ">")
          | gsub("#96;"; "`") | gsub("#35;"; "#")'
}
eq "Mermaid safety: the task label decodes to the title, newline as a space" \
  'store-schema: He said "hi" [x] | y {z} <b>b</b> #quot; `c` end second line [policy/S]' \
  "$(printf '%s\n' "$out" | grep '^    t_store_schema\[' | sed 's/^    t_store_schema\["//; s/"\]$//' | decode)"
eq "Mermaid safety: the edge label decodes to the via" 'a|b "c" [d] -->|x| e f' \
  "$(printf '%s\n' "$out" | grep -- '| t_queue$' | head -n 1 | sed 's/^  t_store_schema -->|"//; s/"| t_queue$//' | decode)"
eq "Mermaid safety: the epic title decodes" 'core: E "q" ]) | p nl' \
  "$(printf '%s\n' "$out" | grep '^  subgraph e_core\[' | sed 's/^  subgraph e_core\["//; s/"\]$//' | decode)"

# --- usage --------------------------------------------------------------------------
run -- lint
eq "usage: missing file -> exit 2" 2 "$rc"
run -- frobnicate "$fx/valid.plan.json"
eq "usage: unknown op -> exit 2" 2 "$rc"

# --- GC59 (plan.sh part): an invalid config exits 1 before any I/O -----------------
for envs in "FORGE=gitlab GRAPH_BACKEND=local" "GRAPH_BACKEND=github FORGE=gitlab GITLAB_TOKEN=x" \
            "GRAPH_BACKEND=sqlite"; do
  for op in lint render; do
    # shellcheck disable=SC2086
    run $envs -- "$op" "$fx/valid.plan.json"
    eq "GC59 $envs: plan.sh $op exits 1" 1 "$rc"
    eq "GC59 $envs: plan.sh $op makes no graph call (stub log empty)" "" "$(cat "$tmp/log")"
    eq "GC59 $envs: plan.sh $op prints nothing on stdout" "" "$out"
    has "GC59 $envs: plan.sh $op stderr carries the config error" "$err" "config:"
  done
done

if [ "$fails" -ne 0 ]; then
  echo "plan tests FAILED" >&2
  exit 1
fi
echo "plan tests passed"
