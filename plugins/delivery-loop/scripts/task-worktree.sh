#!/usr/bin/env bash
# task-worktree.sh <id>            — create (or reuse) the task's worktree, print its path
# task-worktree.sh --cleanup <id>  — remove the worktree + local branch after merge
#
# <id> is a graph node id (docs/delivery_graph_spec.md §4.1): an issue number on
# the github backend, a slug on local. The node is read through `graph.sh show`
# (§3: never `gh issue` directly) and its worktree forks from
# origin/<target_branch> (§9; target_branch defaults to BASE_BRANCH).
#
# Naming: worktree .worktrees/task-<id>--<slug>, branch task/<id>--<slug>. Ids
# never contain `--` (§4.1), so the text before the first `--` of a directory
# name is exactly its id: an id never matches another id's directory (GC55).
# Legacy v0.1.4 worktrees .worktrees/task-<n>-<slug> (branch task/<n>-<slug>,
# whose slug has no `--`) are still reused, and cleaned up, for numeric ids.
# .worktrees/ is gitignored (see delivery-init.sh).
#
# Only the worktree path goes to stdout (callers capture it); git's chatter and
# WORKTREE_SETUP_CMD's output go to stderr.
#
# Exit codes: 0 ok · 1 failed (unknown node, unreachable origin, or the target
# branch is missing on origin, GC38) · 2 usage.
#
# Per-repo config (.claude/delivery.conf, resolved by lib/config.sh):
#   BASE_BRANCH         default target_branch (default: main)
#   WORKTREE_SETUP_CMD  command run once inside a fresh worktree (default: none)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

usage() {
  echo "usage: task-worktree.sh <id> | --cleanup <id>" >&2
  exit 2
}
die() { echo "task-worktree: $*" >&2; exit 1; }

# A node id (§4.1): a slug of [a-z0-9] runs joined by single dashes, <= 40
# chars. Issue numbers fit it too. Anything else is refused before it can reach
# a path or a ref name.
id_re='^[a-z0-9]+(-[a-z0-9]+)*$'
valid_id() { [[ $1 =~ $id_re ]] && [ "${#1}" -le 40 ]; }

# find_wt <id>: print the id's existing worktree directory, if any. The new
# scheme wins; the legacy scheme is tried only for a numeric id.
find_wt() {
  local id="$1" d name rest
  for d in .worktrees/task-*; do
    [ -d "$d" ] || continue
    name="${d#.worktrees/task-}"
    case "$name" in
      *--*) [ "${name%%--*}" = "$id" ] && { echo "$d"; return 0; } ;;
    esac
  done
  case "$id" in *[!0-9]*) return 0 ;; esac
  for d in .worktrees/task-"$id"-*; do
    [ -d "$d" ] || continue
    rest="${d#.worktrees/task-"$id"-}"
    case "$rest" in *--*|-*) continue ;; esac   # a new-scheme dir, not legacy
    echo "$d"; return 0
  done
}

if [ "${1:-}" = "--cleanup" ]; then
  [ $# -eq 2 ] || usage
  id="$2"
  valid_id "$id" || die "invalid node id '$id'"
  wt=$(find_wt "$id")
  if [ -n "$wt" ]; then
    branch="task/${wt#.worktrees/task-}"
    git worktree remove "$wt" --force >&2
    git branch -D "$branch" >/dev/null 2>&1 || true
    echo "removed $wt and branch $branch"
  else
    echo "no worktree found for task $id"
  fi
  exit 0
fi

[ $# -eq 1 ] || usage
id="$1"
case "$id" in -*) usage ;; esac
valid_id "$id" || die "invalid node id '$id'"

existing=$(find_wt "$id")
if [ -n "$existing" ]; then
  echo "$existing"
  exit 0
fi

node=$(bash "$SCRIPT_DIR/graph.sh" show "$id") || die "cannot read node $id (graph.sh show)"
title=$(jq -r '.title' <<<"$node")
target=$(jq -r '.target_branch // empty' <<<"$node")
[ -n "$target" ] || target="$BASE_BRANCH"
git check-ref-format --branch "$target" >/dev/null 2>&1 \
  || die "node $id has an invalid target_branch '$target'"

slug=$(printf '%s\n' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
[ -n "$slug" ] || slug=task
path=".worktrees/task-${id}--${slug}"
branch="task/${id}--${slug}"
# A cleaned-up legacy worktree whose branch survives is re-created under its
# legacy name, keeping its commits.
case "$id" in
  *[!0-9]*) : ;;
  *) if ! git show-ref --verify --quiet "refs/heads/$branch" \
        && git show-ref --verify --quiet "refs/heads/task/${id}-${slug}"; then
       path=".worktrees/task-${id}-${slug}"
       branch="task/${id}-${slug}"
     fi ;;
esac

# GC38: the target must already exist on origin; plan.sh apply creates it.
rc=0
git ls-remote --exit-code --heads origin "refs/heads/$target" >/dev/null || rc=$?
case "$rc" in
  0) : ;;
  2) die "target branch '$target' of node $id does not exist on origin; create it with plan.sh apply (docs/delivery_graph_spec.md §8.3, §9)" ;;
  *) die "cannot reach origin to look up target branch '$target' (git ls-remote exit $rc)" ;;
esac
git fetch --quiet origin "+refs/heads/$target:refs/remotes/origin/$target" >&2 \
  || die "git fetch of origin/$target failed"

mkdir -p .worktrees
if git show-ref --verify --quiet "refs/heads/$branch"; then
  git worktree add "$path" "$branch" >&2
else
  git worktree add "$path" -b "$branch" "origin/$target" >&2
fi
if [ -n "${WORKTREE_SETUP_CMD:-}" ]; then
  ( cd "$path" && eval "$WORKTREE_SETUP_CMD" ) >&2
fi

echo "$path"
