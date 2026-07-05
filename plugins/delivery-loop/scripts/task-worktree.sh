#!/usr/bin/env bash
# task-worktree.sh <issue#>            — create (or reuse) the task's worktree, print its path
# task-worktree.sh --cleanup <issue#>  — remove the worktree + local branch after merge
#
# Convention: worktree .worktrees/task-<n>-<slug>, branch task/<n>-<slug>, both
# rooted at origin/$BASE_BRANCH. .worktrees/ is gitignored (see delivery-init.sh).
#
# Per-repo config (.claude/delivery.conf, resolved by lib/config.sh):
#   BASE_BRANCH         base branch worktrees fork from (default: main)
#   WORKTREE_SETUP_CMD  command run once inside a fresh worktree (default: none)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

if [ "${1:-}" = "--cleanup" ]; then
  N=${2:?usage: task-worktree.sh --cleanup <issue#>}
  wt=$(find .worktrees -maxdepth 1 -type d -name "task-${N}-*" 2>/dev/null | head -1 || true)
  if [ -n "$wt" ]; then
    branch="task/$(basename "$wt" | sed 's/^task-//')"
    git worktree remove "$wt" --force
    git branch -D "$branch" 2>/dev/null || true
    echo "removed $wt and branch $branch"
  else
    echo "no worktree found for task #$N"
  fi
  exit 0
fi

N=${1:?usage: task-worktree.sh <issue#>}

existing=$(find .worktrees -maxdepth 1 -type d -name "task-${N}-*" 2>/dev/null | head -1 || true)
if [ -n "$existing" ]; then
  echo "$existing"
  exit 0
fi

title=$(gh issue view "$N" --json title --jq .title)
slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
path=".worktrees/task-${N}-${slug}"
branch="task/${N}-${slug}"

git fetch origin
mkdir -p .worktrees
if git show-ref --verify --quiet "refs/heads/$branch"; then
  git worktree add "$path" "$branch"
else
  git worktree add "$path" -b "$branch" "origin/$BASE_BRANCH"
fi
if [ -n "${WORKTREE_SETUP_CMD:-}" ]; then
  ( cd "$path" && eval "$WORKTREE_SETUP_CMD" )
fi

echo "$path"
