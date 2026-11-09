#!/usr/bin/env bash
# Tests for task-worktree.sh (docs/delivery_graph_spec.md §4.1 target_branch, §9
# targets): golden cases GC38 and GC55, plus fork-from-target, reuse, legacy
# v0.1.4 naming and --cleanup for both schemes — §17 row E3.
#
# Offline: a throwaway repo under ${TMPDIR:-/tmp} clones a bare "origin" with
# branches trunk and release/x. The github backend answers through the
# recording gh shim (fixtures/graph-github/gh-shim.sh) over
# fixtures/task-worktree/issues.json; slug ids run with GRAPH_BACKEND=local
# against a stub backend installed into a private copy of the engine.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fx="$here/fixtures/task-worktree"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-task-worktree-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# A private engine copy, so the stub local backend never touches the real tree.
mkdir -p "$tmp/engine"
cp -R "$here/.." "$tmp/engine/scripts"
cp "$fx/graph-local-stub.sh" "$tmp/engine/scripts/backends/graph-local.sh"
tw="$tmp/engine/scripts/task-worktree.sh"

mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$here/fixtures/graph-github/gh-shim.sh" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

# Isolated git: no host config, hooks or signing.
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$tmp/gitconfig" user.name test
git config --file "$tmp/gitconfig" user.email test@example.invalid
git config --file "$tmp/gitconfig" init.defaultBranch trunk

git init -q --bare "$tmp/origin.git"
git init -q "$tmp/seed"
(
  cd "$tmp/seed"
  git checkout -q -b trunk
  echo base > f; git add f; git commit -q -m base
  git checkout -q -b release/x
  echo rel > f; git commit -q -am release
  git remote add origin "$tmp/origin.git"
  git push -q origin trunk release/x
)
git clone -q "$tmp/origin.git" "$tmp/repo"
repo="$tmp/repo"
mkdir -p "$repo/.claude"
echo 'BASE_BRANCH=trunk' > "$repo/.claude/delivery.conf"
trunk_sha=$(git -C "$repo" rev-parse origin/trunk)
rel_sha=$(git -C "$repo" rev-parse origin/release/x)

# run [VAR=value …] -- <task-worktree.sh args…>: sets $rc, $out, $err.
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  : > "$tmp/state/log"
  # shellcheck disable=SC2086
  (cd "$repo" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REPO -u GH_HOST \
     -u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u BASE_BRANCH \
     -u WORKTREE_SETUP_CMD -u STATE_DIR -u SHIM_BOARD -u SHIM_GH_VERSION \
     PATH="$tmp/bin:$PATH" SHIM_FX="$fx" SHIM_BOARD=issues.json \
     SHIM_STATE="$tmp/state" STUB_NODES="$fx/local-nodes.json" $envs \
     bash "$tw" "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
log_has() { grep -qF -- "$1" "$tmp/state/log"; }
head_of() { if [ -n "$1" ]; then git -C "$repo/$1" rev-parse HEAD 2>/dev/null || echo none; else echo none; fi; }
has_branch() { git -C "$repo" show-ref --verify --quiet "refs/heads/$1"; }

# --- fork from target_branch, new naming --------------------------------------------
printf '%s\n' 'BASE_BRANCH=trunk' "WORKTREE_SETUP_CMD='echo setup-ran; touch .setup-done'" > "$repo/.claude/delivery.conf"
run -- 30
echo 'BASE_BRANCH=trunk' > "$repo/.claude/delivery.conf"
expect "default target: exits 0" '[ "$rc" = 0 ]'
eq "new naming task-<id>--<slug>; stdout is only the path" ".worktrees/task-30--v0-2-e3-branch-targets" "$out"
eq "no Delivery-Target -> forks from origin/BASE_BRANCH (from .claude/delivery.conf)" "$trunk_sha" "$(head_of "$out")"
expect "branch task/<id>--<slug>" 'has_branch "task/30--v0-2-e3-branch-targets"'
expect "the node is read via graph.sh show (gh issue view on github)" 'log_has "gh issue view 30 --json"'
expect "WORKTREE_SETUP_CMD ran in the worktree, its output on stderr" \
  '[ -f "$repo/$out/.setup-done" ] && grep -q setup-ran <<<"$err"'

run -- 31
eq "Delivery-Target: release/x -> named by id" ".worktrees/task-31--release-work" "$out"
eq "forks from origin/<target_branch>, not BASE_BRANCH" "$rel_sha" "$(head_of "$out")"

run -- 30
eq "an existing worktree is reused" ".worktrees/task-30--v0-2-e3-branch-targets" "$out"
expect "reuse reads no node" '[ "$rc" = 0 ] && ! log_has "gh "'

# --- GC38: missing target branch ---------------------------------------------------
run -- 38
expect "GC38: a missing target branch exits 1" '[ "$rc" = 1 ]'
expect "GC38: the message names plan.sh apply" 'grep -q "plan.sh apply" <<<"$err"'
expect "GC38: the message names the branch" 'grep -q "release/missing" <<<"$err"'
expect "GC38: no worktree, branch or stdout left behind" \
  '[ -z "$out" ] && ! ls -d "$repo"/.worktrees/task-38* >/dev/null 2>&1 && ! has_branch "task/38--missing-target"'

# --- GC55: no false match; legacy reuse ---------------------------------------------
git -C "$repo" worktree add -q "$repo/.worktrees/task-12-old" -b task/12-old origin/trunk
mkdir -p "$repo/.worktrees/task-ready-policy-extra--x" "$repo/.worktrees/task-13-foo--x"

run GRAPH_BACKEND=local -- ready-policy
expect "GC55: slug id exits 0" '[ "$rc" = 0 ]'
eq "GC55: ready-policy does not match task-ready-policy-extra--x; creates its own" \
  ".worktrees/task-ready-policy--ready-policy" "$out"
eq "GC55: slug node forks from its target_branch" "$rel_sha" "$(head_of "$out")"
expect "GC55: the node is read from the configured backend" 'log_has "graph-local show ready-policy"'

run GRAPH_BACKEND=local -- ready
eq "GC55: id ready matches neither task-ready-policy--… nor task-ready-policy-extra--x" \
  ".worktrees/task-ready--ready" "$out"

run -- 12
eq "GC55: numeric id 12 reuses the legacy dir task-12-old" ".worktrees/task-12-old" "$out"
expect "GC55: legacy reuse reads no node" '[ "$rc" = 0 ] && ! log_has "gh "'

run -- 1
eq "id 1 does not match task-12-old" ".worktrees/task-1--one" "$out"

run -- 13
eq "a new-scheme dir of slug id 13-foo is not a legacy dir of id 13" ".worktrees/task-13--thirteen" "$out"

run GRAPH_BACKEND=local -- 12
eq "legacy reuse precedes the backend (any GRAPH_BACKEND)" ".worktrees/task-12-old" "$out"
run -- 13
eq "numeric id: an existing new-scheme dir is reused" ".worktrees/task-13--thirteen" "$out"

# A cleaned-up legacy worktree whose branch survives keeps its branch and name.
git -C "$repo" branch -q task/14-legacy-thing origin/release/x
run -- 14
eq "legacy branch without a dir is re-checked-out under its legacy name" ".worktrees/task-14-legacy-thing" "$out"
eq "…on its existing commits" "$rel_sha" "$(head_of "$out")"

# --- --cleanup, both schemes ----------------------------------------------------------
run -- --cleanup 30
expect "cleanup (new scheme) removes worktree and branch" \
  '[ "$rc" = 0 ] && [ ! -d "$repo/.worktrees/task-30--v0-2-e3-branch-targets" ] && ! has_branch "task/30--v0-2-e3-branch-targets"'
eq "cleanup reports what it removed" "removed .worktrees/task-30--v0-2-e3-branch-targets and branch task/30--v0-2-e3-branch-targets" "$out"

run -- --cleanup 12
expect "cleanup (legacy scheme) removes task-12-old and task/12-old" \
  '[ "$rc" = 0 ] && [ ! -d "$repo/.worktrees/task-12-old" ] && ! has_branch "task/12-old"'
expect "cleanup of 12 leaves other ids alone" '[ -d "$repo/.worktrees/task-13--thirteen" ]'

run -- --cleanup 3
eq "cleanup of an id with no worktree" "no worktree found for task 3" "$out"
expect "…and matches neither task-31--… nor task-38" '[ "$rc" = 0 ] && [ -d "$repo/.worktrees/task-31--release-work" ]'

# --- usage ----------------------------------------------------------------------------
run -- '../x'
expect "an invalid id exits 1 before any I/O" '[ "$rc" = 1 ] && ! log_has "gh "'
run --
expect "no id: usage, exit 2" '[ "$rc" = 2 ]'
run -- --cleanup
expect "--cleanup without an id: usage, exit 2" '[ "$rc" = 2 ]'

if [ "$fails" = 0 ]; then echo "task-worktree-test: all passed"; else echo "task-worktree-test: FAILED" >&2; exit 1; fi
