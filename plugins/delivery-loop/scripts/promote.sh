#!/usr/bin/env bash
# promote.sh <id> — the tick's `promote` action (docs/delivery_graph_spec.md §9):
# promote a plan's target branch T into its promote_to branch P, without model
# judgment.
#
# <id> is a promote node (kind "promote", created by `plan.sh apply`) carrying
# target_branch T and promote_to P. Steps (§9):
#   1. Claim the node (actor `promote`). Lost or not claimable: exit 1.
#   2. Fetch T and P. Identical trees (`git diff --quiet origin/P origin/T`):
#      comment `nothing to promote`, set the node done, open no PR (GC49).
#   3. Otherwise build a fresh detached worktree of origin/T and run
#      PROMOTE_GATE_CMD (empty -> GATE_CMD) there, after WORKTREE_SETUP_CMD;
#      the worktree is removed afterwards.
#   4. Red: set needs-human, comment with the failing output, run
#      NOTIFY_ESCALATE_CMD, release the claim, exit 1; no PR (GC50).
#   5. Green: open the promotion PR (head T, base P, title `Promote T → P`, a
#      body listing the plan's done tasks and `Delivery-Task: <id>`) through
#      `forge.sh pr-create --label agent-authored`, or reuse the open PR
#      already on head T into P, then set the node in-review (GC51).
# A failure that is not the gate's (git, forge, graph) releases the claim and
# exits 1 without setting needs-human, so the next tick retries. So does any
# other exit while the claim is held and no PR exists: a signal (INT, TERM,
# HUP: exit 128+n, the running gate stopped) or an unplanned `set -e` exit,
# through the EXIT trap. Once the PR exists the claim is left for reconcile
# (rule 4: claimed + an open agent PR -> in-review).
# Signals: one that arrives while `graph claim`, the PR find/create, or the
# in-review transition runs is held until that step's outcome is known, then
# honoured (exit 128+n). A signal sent to the whole process group (Ctrl-C, a
# terminal hangup, `kill -- -pgid`) also kills that step's child, so its
# outcome is re-read: a claim carrying this run's id is released; once the
# gate has passed, an open promotion PR (head T into P, `forge.sh pr-find`)
# keeps the claim. A PR that was opened is still reported on stdout.
# SIGINT cannot be trapped when a non-interactive shell without job control
# starts this script in the background (`promote.sh … &`): POSIX has such a
# child ignore INT at entry, so INT is then a no-op. Use TERM, or start it
# with job control (`set -m`).
#
# The promotion PR is never auto-merged (GC39): a human merges it with
# PROMOTE_MERGE_METHOD, and reconcile marks the node done (§9, rule 3). The
# `agent-authored` label is what makes it an agent PR to reconcile.
#
# Every graph and forge call goes through graph.sh / forge.sh (§3 rule 3). The
# config combination is validated once, before any I/O (§11, GC59).
#
# Stdout: one JSON line, {id, result: "nothing-to-promote"|"promoted", pr?,
# url?}. Progress, gate output and errors go to stderr.
#
# Exit codes: 0 done or promoted · 1 refused / red gate / failed / invalid
# config · 2 usage · 128+n killed by signal n (claim released unless the PR
# exists).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() { echo "usage: promote.sh <id> (a promote node, docs/delivery_graph_spec.md §9)" >&2; exit 2; }
[ $# -eq 1 ] && [ -n "$1" ] && [ "${1#-}" = "$1" ] || usage
id="$1"

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/worktree-gate.sh
. "$SCRIPT_DIR/lib/worktree-gate.sh"

graph() { bash "$SCRIPT_DIR/graph.sh" "$@"; }
forge() { bash "$SCRIPT_DIR/forge.sh" "$@"; }
die()   { echo "promote: $*" >&2; exit "${pending_sig:-1}"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-promote.XXXXXX")"
run="promote-$(uname -n)-$$-$(date +%s)"   # this run's claim id, computed once
held=""        # set while the claim is held and nothing settles it
gated=""       # set once the gate passed: from here a promotion PR may exist
defer=""       # set while a step whose outcome must be known runs
pending_sig=""

# pr_open: an open promotion PR on head T into P exists (a failed read: no).
pr_open() {
  local j
  j=$(forge pr-find --head "$T" 2>/dev/null) || return 1
  [ -n "$j" ] && [ "$(jq -r .base <<<"$j")" = "$P" ]
}

# release_claim <reason>: hand back a claim nothing settled, unless the gate
# passed and the promotion PR is open (then reconcile rule 4 owns it).
release_claim() {
  [ -n "$held" ] || return 0
  held=""
  if [ -n "$gated" ] && pr_open; then
    echo "promote: the promotion PR ($T into $P) is open: $id keeps its claim for reconcile (rule 4)" >&2
    return 0
  fi
  graph release "$id" "promote.sh: $1" >&2 || echo "promote: could not release $id" >&2
}

# on_exit: stop the gate and drop its worktree, then hand back a claim no
# planned path settled (a signal, or an unplanned `set -e` exit).
on_exit() {
  local st=$?
  trap '' INT TERM HUP
  dl_gate_cleanup
  release_claim "interrupted (exit $st) before opening a PR"
  rm -rf "$tmp"
  exit "$st"
}
on_signal() { if [ -n "$defer" ]; then pending_sig="$1"; else exit "$1"; fi; }
# honour: leave a deferred step, then act on a signal it held.
honour() { defer=""; [ -z "$pending_sig" ] || exit "$pending_sig"; }
trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

graph show "$id" > "$tmp/node.json" || die "cannot read node $id (graph.sh show)"
kind=$(jq -r .kind "$tmp/node.json")
[ "$kind" = promote ] || die "node $id is a $kind node, not a promote node"
T=$(jq -r '.target_branch // empty' "$tmp/node.json")
P=$(jq -r '.promote_to // empty' "$tmp/node.json")
[ -n "$P" ] || die "promote node $id has no promote_to branch"
[ -n "$T" ] || T="$BASE_BRANCH"
for b in "$T" "$P"; do
  git check-ref-format --branch "$b" >/dev/null 2>&1 || die "promote node $id names an invalid branch '$b'"
done
[ "$T" != "$P" ] || die "promote node $id promotes $T into itself"

# 1. Claim. graph.sh runs the policy pre-check (ready, unclaimed, not
# needs-human) before the backend's atomic test-and-set.
# A signal during the claim is held until its outcome is known, so a claim
# that lands is released rather than leaked. A group signal kills graph.sh
# too, possibly after the backend claim landed: re-read whose claim it is.
defer=1
if graph claim "$id" promote --run "$run" >&2; then
  held=1
elif [ -n "$pending_sig" ]; then
  if graph show "$id" 2>/dev/null | jq -e --arg run "$run" '(.claim // {}).run == $run' >/dev/null; then
    held=1
  fi
  exit "$pending_sig"
else
  die "could not claim $id (lost the race, or not claimable)"
fi
honour

# release_fail <message>: a failure that is not the gate's. Hand the node back
# for the next tick (unless its promotion PR is open) and exit 1.
release_fail() {
  echo "promote: $1" >&2
  release_claim "$1"
  exit "${pending_sig:-1}"
}

# 2. Identical trees: nothing to promote (GC49).
for b in "$T" "$P"; do
  git fetch --quiet origin "+refs/heads/$b:refs/remotes/origin/$b" >&2 \
    || release_fail "cannot fetch origin/$b"
done
if git diff --quiet "origin/$P" "origin/$T"; then
  graph comment "$id" "nothing to promote: origin/$T and origin/$P have identical trees." >&2 \
    || release_fail "cannot comment on $id"
  graph transition "$id" done --actor promote >&2 || release_fail "cannot set $id done"
  held=""
  jq -cn --arg id "$id" '{id: $id, result: "nothing-to-promote"}'
  exit 0
fi

# 3. The gate on a fresh worktree of origin/T.
gate="${PROMOTE_GATE_CMD:-$GATE_CMD}"
rc=0
dl_gate_tree "$tmp/tree" "origin/$T" "$gate" "$tmp/gate.log" || rc=$?
case "$rc" in
  0) : ;;
  1) # 4. Red (GC50).
     {
       echo "PROMOTE-GATE-RED: \`$gate\` failed on origin/$T at ${DL_GATE_BASE}; the promotion of $T into $P needs a human."
       echo
       echo '```'
       tail -n 60 "$tmp/gate.log"
       echo '```'
     } > "$tmp/red.md"
     graph flag "$id" needs-human on >&2 || echo "promote: could not flag $id needs-human" >&2
     graph comment "$id" - < "$tmp/red.md" >&2 || echo "promote: could not comment on $id" >&2
     if [ -n "${NOTIFY_ESCALATE_CMD:-}" ]; then
       ( eval "$NOTIFY_ESCALATE_CMD" ) >&2 || echo "promote: NOTIFY_ESCALATE_CMD failed" >&2
     fi
     graph release "$id" "promote.sh: gate red on origin/$T; needs a human" >&2 \
       || echo "promote: could not release $id" >&2
     held=""
     die "gate red on origin/$T: $id flagged needs-human, no PR opened" ;;
  *) release_fail "cannot run the gate on origin/$T (worktree-gate exit $rc)" ;;
esac
gated=1

# 5. Green (GC51): open (or reuse) the promotion PR, then in-review. A signal
# from the PR find on is held: the PR's existence decides the claim
# (release_claim), and an opened PR is still reported.
defer=1
pr_json=$(forge pr-find --head "$T") || release_fail "forge pr-find --head $T failed"
if [ -n "$pr_json" ] && [ "$(jq -r .base <<<"$pr_json")" = "$P" ]; then
  held=""   # the PR exists: from here reconcile (rule 4) repairs the status
  echo "promote: reusing open PR #$(jq -r .number <<<"$pr_json") ($T into $P)" >&2
else
  honour    # no PR yet: a held signal releases the claim
  graph list > "$tmp/nodes.json" || release_fail "cannot list nodes (graph.sh list)"
  # The plan's done tasks: tasks sharing this node's plan (plan_ref prefix),
  # or children of its dep epics.
  jq -r --slurpfile n "$tmp/node.json" '
    $n[0] as $p
    | (($p.plan_ref // "") | split("/")[0]) as $plan
    | [$p.deps[].id] as $epics
    | [.[] | select(.kind == "task" and .status == "done"
                    and ((($plan != "") and ((.plan_ref // "") | startswith($plan + "/")))
                         or (.epic as $e | $e != null and any($epics[]; . == $e))))]
    | sort_by(.id)
    | if length == 0 then "- (none recorded)" else .[] | "- \(.id): \(.title)" end' \
    "$tmp/nodes.json" > "$tmp/tasks.md" || release_fail "cannot list the plan's done tasks"
  {
    echo "Promotes \`$T\` into \`$P\` (promote node \`$id\`)."
    echo
    echo "Done tasks:"
    cat "$tmp/tasks.md"
    echo
    echo "Gate \`$gate\` passed on origin/$T at ${DL_GATE_BASE}."
    echo "Never auto-merged: a human merges this PR with \`$PROMOTE_MERGE_METHOD\` (PROMOTE_MERGE_METHOD)."
    echo
    echo "Delivery-Task: $id"
  } > "$tmp/body.md"
  # agent-authored: reconcile (rule 3) closes the node once a human merges it.
  defer=1
  pr_json=$(forge pr-create --head "$T" --base "$P" --title "Promote $T → $P" \
              --body-file "$tmp/body.md" --label agent-authored) \
    || release_fail "forge pr-create ($T into $P) failed"
  held=""   # the PR exists: from here reconcile (rule 4) repairs the status
fi
graph transition "$id" in-review --actor promote >&2 \
  || die "PR opened but $id could not be set in-review; reconcile repairs it (rule 4)"
jq -c --arg id "$id" '{id: $id, result: "promoted", pr: .number, url: .url}' <<<"$pr_json"
honour
