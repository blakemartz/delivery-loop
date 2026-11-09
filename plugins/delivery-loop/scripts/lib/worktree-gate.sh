# worktree-gate.sh — run a gate on a throwaway tree (docs/delivery_graph_spec.md
# §9 promote step 3, §10 `tick-merge.sh`).
#
# Sourced (never executed) by promote.sh and tick-merge.sh, after lib/config.sh
# and from the repo's toplevel. Defines:
#
#   dl_gate_tree <dir> <ref> <gate-cmd> <log> [<merge-sha>]
#       Builds a detached worktree of <ref> at <dir> (an empty or absent path),
#       merges <merge-sha> into it when given (a throwaway merge commit, never
#       pushed), runs WORKTREE_SETUP_CMD (if set) and then <gate-cmd> inside it,
#       and removes the worktree again, whatever happened. The setup and gate
#       output goes to stderr and to <log>. Returns:
#         0 the gate passed
#         1 the gate (or WORKTREE_SETUP_CMD) failed
#         3 <merge-sha> does not merge cleanly into <ref> (no gate run)
#         4 the worktree could not be built (no gate run)
#       Sets DL_GATE_BASE to the commit <ref> resolved to.
#
#   dl_gate_cleanup
#       Removes a worktree dl_gate_tree left registered (an interrupted run).
#       Safe to call from an EXIT trap at any time.
#
# The worktree is registered with the caller's repo only while the gate runs;
# a leftover registration is pruned. Do NOT `set -e` here: the functions run in
# the caller's shell options and check every status explicitly.

DL_GATE_WT=""
DL_GATE_BASE=""

dl_gate_cleanup() {
  [ -n "$DL_GATE_WT" ] || return 0
  git worktree remove --force "$DL_GATE_WT" >/dev/null 2>&1 || rm -rf "$DL_GATE_WT"
  git worktree prune >/dev/null 2>&1 || true
  DL_GATE_WT=""
}

dl_gate_tree() {
  local dir="$1" ref="$2" gate="$3" log="$4" merge="${5:-}" rc=0
  : > "$log"
  DL_GATE_BASE="$(git rev-parse --verify --quiet "$ref^{commit}")" || {
    echo "worktree-gate: cannot resolve $ref" >&2; return 4; }
  git worktree add --detach --quiet "$dir" "$DL_GATE_BASE" >&2 || {
    echo "worktree-gate: cannot create a worktree of $ref at $dir" >&2; return 4; }
  DL_GATE_WT="$dir"
  if [ -n "$merge" ]; then
    # A fixed identity and no signing: the merge commit is local and discarded.
    git -C "$dir" -c user.name=delivery-loop -c user.email=delivery-loop@localhost \
        -c commit.gpgsign=false merge --no-ff --no-edit --quiet "$merge" >"$log" 2>&1 || rc=3
    if [ "$rc" -ne 0 ]; then
      cat "$log" >&2
      dl_gate_cleanup
      return 3
    fi
  fi
  ( cd "$dir" || exit 1
    if [ -n "${WORKTREE_SETUP_CMD:-}" ]; then eval "$WORKTREE_SETUP_CMD" || exit $?; fi
    eval "$gate" ) >>"$log" 2>&1 < /dev/null || rc=1
  cat "$log" >&2
  dl_gate_cleanup
  return "$rc"
}
