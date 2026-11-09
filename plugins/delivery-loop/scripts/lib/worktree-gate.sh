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
#       output goes to stderr and to <log>.
#       The setup and gate run with every lib/config.sh key (_DL_VARS) unset,
#       so whatever in the tree sources config.sh resolves the TREE's own
#       .claude/delivery.conf (a PR that changes it included), not the values
#       the caller resolved and exported. The environment-only keys
#       (_DL_ENV_ONLY: tokens, LOCK_WAIT_SECONDS) pass through: the
#       environment is their only source.
#       The gate runs as a background job in its own process group, and the
#       caller waits on it, so a signal the caller traps is handled at once
#       rather than after the gate ends. Returns:
#         0 the gate passed
#         1 the gate (or WORKTREE_SETUP_CMD) failed
#         3 <merge-sha> does not merge cleanly into <ref> (no gate run)
#         4 the worktree could not be built (no gate run)
#       Sets DL_GATE_BASE to the commit <ref> resolved to.
#
#   dl_gate_cleanup
#       Stops a gate still running (TERM to its process group, captured PID;
#       KILL to it if anything in it outlives DL_GATE_TERM_WAIT tenths of a
#       second, so a gate that traps or ignores TERM cannot hold the caller's
#       exit), then removes a worktree dl_gate_tree left registered (an
#       interrupted run). Safe to call from an EXIT trap at any time; the
#       caller traps INT/TERM/HUP to `exit`, so the EXIT trap runs on a signal.
#
# The worktree is registered with the caller's repo only while the gate runs;
# a leftover registration is pruned. Do NOT `set -e` here: the functions run in
# the caller's shell options and check every status explicitly.

DL_GATE_WT=""
DL_GATE_BASE=""
DL_GATE_PID=""
DL_GATE_TERM_WAIT=50   # tenths of a second between TERM and KILL

dl_gate_cleanup() {
  local pid="$DL_GATE_PID" target i=0
  if [ -n "$pid" ]; then
    # The whole group (the gate's own children too); the PID alone if the
    # group was not created.
    target="-$pid"
    kill -TERM -- "$target" 2>/dev/null || { target="$pid"; kill -TERM "$pid" 2>/dev/null; } || true
    # Bounded: poll until nothing in the target is left, then KILL it. The
    # poll's own sleep lets bash reap the gate, so its zombie does not count.
    # `command -p`: the system sleep, whatever PATH holds. `2>/dev/null` on
    # the loop and the wait: bash 3.2 prints a job notice ("Terminated") for
    # the killed job when it reaps it.
    while kill -0 -- "$target" 2>/dev/null && [ "$i" -lt "$DL_GATE_TERM_WAIT" ]; do
      command -p sleep 0.1; i=$((i + 1))
    done 2>/dev/null
    if kill -0 -- "$target" 2>/dev/null; then
      echo "worktree-gate: the gate outlived TERM by $((DL_GATE_TERM_WAIT / 10))s; sending KILL" >&2
      kill -KILL -- "$target" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    DL_GATE_PID=""
  fi
  [ -n "$DL_GATE_WT" ] || return 0
  git worktree remove --force "$DL_GATE_WT" >/dev/null 2>&1 || rm -rf "$DL_GATE_WT"
  git worktree prune >/dev/null 2>&1 || true
  DL_GATE_WT=""
}

dl_gate_tree() {
  local dir="$1" ref="$2" gate="$3" log="$4" merge="${5:-}" rc=0
  local setup="${WORKTREE_SETUP_CMD:-}" monitor=""
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
  # set -m: the job gets its own process group, which dl_gate_cleanup can stop
  # as a whole; restored straight after the launch.
  case "$-" in *m*) monitor=1 ;; esac
  set -m
  ( cd "$dir" || exit 1
    # shellcheck disable=SC2086
    unset ${_DL_VARS:-}
    if [ -n "$setup" ]; then eval "$setup" || exit $?; fi
    eval "$gate" ) >>"$log" 2>&1 < /dev/null &
  DL_GATE_PID=$!
  [ -n "$monitor" ] || set +m
  wait "$DL_GATE_PID" || rc=1
  DL_GATE_PID=""
  cat "$log" >&2
  dl_gate_cleanup
  return "$rc"
}
