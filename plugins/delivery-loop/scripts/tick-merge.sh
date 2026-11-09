#!/usr/bin/env bash
# tick-merge.sh <pr> <sha> — the tick's `merge` action (docs/delivery_graph_spec.md
# §5 tick-plan rule 1, §10 `delivery-tick`): merge one agent task PR, but only
# if it is still eligible and its merged result is green.
#
# <sha> is the head the plan judged the PR at (the merge action's `sha`).
# Steps, each refusing with exit 1 and no merge request:
#   1. Re-read the PR (`forge.sh pr-view`), re-polling while its mergeability is
#      still `unknown` (§7.3, GC57). It must be open, its head still <sha>
#      (GC52), and it must not be a promotion PR (GC39: never auto-merged).
#   2. Re-apply the merge rule exactly as tick-plan does: lib/tick-plan.jq over
#      every node (`graph.sh list`) and the open PRs (`forge.sh pr-list`, this
#      PR's fresh read in place), with auto_merge on, must emit `merge` for this
#      PR at <sha>. So: an approved `task` node without needs_human, the PR
#      agent-authored, mergeable clean, checks success (or none), no
#      `needs-human` label, base == the node's target_branch, and the lowest
#      such PR of its task (GC70).
#   3. The merged result: a fresh detached worktree of origin/<base> with <sha>
#      merged in, WORKTREE_SETUP_CMD then GATE_CMD run there, the worktree
#      removed. Two PRs green on their own can be red together, and a forge
#      reports a behind PR as clean when nothing requires it to be up to date.
#      A conflicting or red merged result prints a `rebase` action on stdout
#      for the tick to dispatch and exits 1. At the patch budget it escalates
#      instead: flags the node needs-human, comments, runs
#      NOTIFY_ESCALATE_CMD, prints {pr, id, result: "needs-human", reason}
#      and exits 1.
#      The gate runs with lib/config.sh's keys unset, so the merged tree's own
#      .claude/delivery.conf governs it (lib/worktree-gate.sh).
#   4. origin/<base> must not have moved since the gate ran.
#      An inherent window remains: the base can still move between this check
#      and the merge in step 5, and no forge merge API pins the base sha (only
#      the head). The gate vouches for the merge onto the base it saw, not
#      for the exact tree that lands; the next gate on that base catches it.
#   5. `forge.sh pr-merge <pr> --method $TASK_MERGE_METHOD --sha <sha>` (the
#      forge refuses a moved head), then a re-read must show `merged`.
#   6. `graph.sh reconcile --fix`, so the task goes done (rule 3); a failure
#      there is a warning only, since the merge has landed.
# Promotion PRs (PROMOTE_MERGE_METHOD) are a human's to merge (§9): refused.
#
# Every graph and forge call goes through graph.sh / forge.sh (§3 rule 3). The
# config combination is validated once, before any I/O (§11).
#
# Stdout: one JSON line: {pr, result: "merged", sha}, or the rebase action
# {action: "rebase", pr, id, reason} for a red or conflicting merged result,
# or {pr, id, result: "needs-human", reason} for one at the patch budget.
# Reasons, gate output and progress go to stderr.
#
# Exit codes: 0 merged · 1 refused / not merged / invalid config · 2 usage ·
# 128+n killed by signal n (the running gate stopped, nothing merged).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() { echo "usage: tick-merge.sh <pr> <sha> (docs/delivery_graph_spec.md §10)" >&2; exit 2; }
[ $# -eq 2 ] || usage
pr="$1" sha="$2"
case "$pr" in ''|*[!0-9]*) usage ;; esac
case "$sha" in ''|-*) usage ;; esac

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/worktree-gate.sh
. "$SCRIPT_DIR/lib/worktree-gate.sh"

graph() { bash "$SCRIPT_DIR/graph.sh" "$@"; }
forge() { bash "$SCRIPT_DIR/forge.sh" "$@"; }
refuse() { echo "tick-merge: refusing PR #$pr: $*" >&2; exit 1; }

POLLS=3        # extra re-reads past the adapter's own re-polls (§7.3)
POLL_SLEEP=10
PATCH_BUDGET=3 # tick-plan.jq patch_budget: rebases stop here (§5 rule 3)

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-tick-merge.XXXXXX")"
trap 'dl_gate_cleanup; rm -rf "$tmp"' EXIT
# A signal exits through the EXIT trap, which stops the gate and drops its tree.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 1. A fresh read, past a still-computing mergeability.
forge pr-view "$pr" > "$tmp/pr.json" || refuse "cannot read it (forge.sh pr-view)"
i=0
while [ "$i" -lt "$POLLS" ] && [ "$(jq -r .mergeable "$tmp/pr.json")" = unknown ] \
      && [ "$(jq -r .state "$tmp/pr.json")" = open ]; do
  i=$((i + 1))
  sleep "$POLL_SLEEP"
  forge pr-view "$pr" > "$tmp/pr.json" || refuse "cannot read it (forge.sh pr-view)"
done
f() { jq -r "$1" "$tmp/pr.json"; }
state=$(f .state) head=$(f .head_sha) base=$(f .base) task=$(f '.task_id // empty')
[ "$state" = open ] || refuse "it is $state, not open"
[ "$head" = "$sha" ] || refuse "its head moved from $sha to $head (GC52); re-plan"
[ -n "$task" ] || refuse "it is linked to no node (no Delivery-Task)"

# 2. The merge rule, re-applied by tick-plan.jq itself.
graph list > "$tmp/nodes.json" || refuse "cannot list nodes (graph.sh list)"
forge pr-list --state open > "$tmp/open.json" || refuse "cannot list open PRs (forge.sh pr-list)"
kind=$(jq -r --arg id "$task" 'first(.[] | select(.id == $id) | .kind) // empty' "$tmp/nodes.json")
[ -n "$kind" ] || refuse "its node $task does not exist"
[ "$kind" != promote ] \
  || refuse "it is the promotion PR of $task: a human merges it with PROMOTE_MERGE_METHOD, never the tick (GC39)"
jq -n -L "$SCRIPT_DIR/lib" --slurpfile nodes "$tmp/nodes.json" \
  --slurpfile open "$tmp/open.json" --slurpfile pr "$tmp/pr.json" \
  --argjson now "$(date -u +%s)" 'include "tick-plan";
  {nodes: $nodes[0],
   prs: ([$open[0][] | select(.number != $pr[0].number)] + $pr),
   flags: {parallel: null, auto_merge: true}, now: $now}
  | tick_plan' > "$tmp/plan.json" || refuse "cannot plan over the board (tick-plan.jq)"
if ! jq -e --argjson n "$pr" --arg sha "$sha" \
     'any(.actions[]; .action == "merge" and .pr == $n and .sha == $sha)' "$tmp/plan.json" >/dev/null; then
  why=$(jq -r --arg ref "PR #$pr " '[.waiting[] | select(startswith($ref))] | join("; ")' "$tmp/plan.json")
  [ -n "$why" ] || why=$(jq -r --arg id "$task" --slurpfile pr "$tmp/pr.json" '
    first(.[] | select(.id == $id)) as $x | $pr[0] as $p
    | "not eligible under the merge rule (§5 rule 1): node \($id) is \($x.kind) \($x.status)\(if $x.needs_human then ", needs-human" else "" end); PR agent=\($p.agent), mergeable=\($p.mergeable), checks=\($p.checks), base \($p.base) vs target \($x.target_branch)"' \
    "$tmp/nodes.json")
  refuse "$why"
fi

# 3. The merged result must pass the gate.
git fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base" >&2 \
  || refuse "cannot fetch origin/$base"
git cat-file -e "$sha^{commit}" 2>/dev/null \
  || git fetch --quiet origin "+refs/heads/$(f .head):refs/remotes/origin/$(f .head)" >&2 \
  || refuse "cannot fetch its head $(f .head)"
git cat-file -e "$sha^{commit}" 2>/dev/null || refuse "its head $sha is not on origin/$(f .head)"

# rebase_action <reason>: under the patch budget, a rebase action for the tick;
# at it, a structural escalation (needs-human, comment, notify), as promote.sh
# does on a red gate. Exits 1 either way.
rebase_action() {
  local it
  echo "tick-merge: PR #$pr: $1" >&2
  it=$(f .patch_iteration)
  if [ "$it" -lt "$PATCH_BUDGET" ]; then
    jq -cn --argjson pr "$pr" --arg id "$task" --arg r "$1" \
      '{action: "rebase", pr: $pr, id: $id, reason: $r}'
    refuse "$1"
  fi
  {
    echo "MERGE-NEEDS-HUMAN: PR #$pr is at patch iteration $it/$PATCH_BUDGET and still cannot merge: $1"
    if [ -s "$tmp/gate.log" ]; then
      echo
      echo '```'
      tail -n 60 "$tmp/gate.log"
      echo '```'
    fi
  } > "$tmp/escalate.md"
  graph flag "$task" needs-human on >&2 || echo "tick-merge: could not flag $task needs-human" >&2
  graph comment "$task" - < "$tmp/escalate.md" >&2 || echo "tick-merge: could not comment on $task" >&2
  if [ -n "${NOTIFY_ESCALATE_CMD:-}" ]; then
    ( eval "$NOTIFY_ESCALATE_CMD" ) >&2 || echo "tick-merge: NOTIFY_ESCALATE_CMD failed" >&2
  fi
  jq -cn --argjson pr "$pr" --arg id "$task" --arg r "$1" \
    '{pr: $pr, id: $id, result: "needs-human", reason: $r}'
  refuse "$1 (patch budget $PATCH_BUDGET reached: $task flagged needs-human)"
}

rc=0
dl_gate_tree "$tmp/tree" "origin/$base" "$GATE_CMD" "$tmp/gate.log" "$sha" || rc=$?
gated_base="$DL_GATE_BASE"
case "$rc" in
  0) : ;;
  1) rebase_action "GATE_CMD is red on origin/$base (${gated_base}) merged with $sha: update it onto $base" ;;
  3) rebase_action "$sha does not merge cleanly into origin/$base (${gated_base}): rebase it onto $base" ;;
  *) refuse "cannot build the merged result (worktree-gate exit $rc)" ;;
esac

# 4. The gate vouches for this base only.
now_base=$(git ls-remote origin "refs/heads/$base" | cut -f1) || now_base=""
[ "$now_base" = "$gated_base" ] \
  || refuse "origin/$base moved from $gated_base to ${now_base:-?} while the gate ran; re-plan"

# 5. Merge, pinned to the head, then verify.
forge pr-merge "$pr" --method "$TASK_MERGE_METHOD" --sha "$sha" >&2 \
  || refuse "forge.sh pr-merge failed (not merged)"
forge pr-view "$pr" > "$tmp/after.json" || refuse "merged, but the re-read failed: verify it by hand"
after=$(jq -r .state "$tmp/after.json")
[ "$after" = merged ] || refuse "the forge reports it $after after the merge, not merged"

# 6. The task goes done (reconcile rule 3).
graph reconcile --fix >&2 || echo "tick-merge: warn: reconcile --fix failed after merging PR #$pr; the next tick reconciles" >&2
jq -cn --argjson pr "$pr" --arg sha "$sha" '{pr: $pr, result: "merged", sha: $sha}'
