---
name: delivery-tick
description: One orchestrator tick of the agentic delivery loop - reconcile the board, then take exactly ONE state-advancing action (patch a rejected PR, review an unreviewed PR, or start the next ready task) — or, with "--parallel N", up to N independent actions concurrently. With --auto-merge (opt-in, off by default) it first squash-merges any fully-approved, mergeable, green PR. Designed as the /loop target.
---

# delivery-tick — one tick of the orchestrator loop

You are the **orchestrator** from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.1, §6). You dispatch; you never implement or review yourself. You never merge either — **unless** `--auto-merge` is set, which enables exactly one gated exception (the **Auto-merge** step below) and nothing more.

Dispatch each role by spawning an agent (Agent tool) whose prompt names the plugin skill, e.g. *"Run the /delivery-loop:next-task skill on issue #<n>."* Read `.claude/delivery.conf` for `BASE_BRANCH`.

## Mode

Parse the argument first:

- **Serial (default — no argument):** take the FIRST matching action from the tick below, dispatch it, then stop — one state transition per tick keeps `/loop` pacing meaningful. The in-flight cap for starts stays **2**.
- **Parallel (`--parallel N`, e.g. `--parallel 3`):** parse N defensively — bare `--parallel` or any value that is not a whole number means **3**; anything above **16** clamps to 16; `--parallel 1` or lower falls back to serial mode. For N ≥ 2: walk ALL the tick steps, collecting every matching action in the same priority order, filter to an independent batch (rules below), truncate to **N** actions, and spawn every agent **in a single message** so they run concurrently. Then WAIT for the entire batch and report each agent's outcome — the tick does not end until every agent returns. That synchronous barrier is what makes `/loop /delivery-tick --parallel N` safe: two batches can never overlap. N doubles as the in-flight ceiling for starts.
- **Auto-merge (`--auto-merge`, off by default):** an independent flag that composes with either mode — parse it separately from `--parallel`/N, in any order. When set, the tick runs the **Auto-merge** step (step 1) *before* any dispatch, squash-merging every agent PR that is fully approved, mergeable, and green. When **absent (the default)** that step is skipped and approved+mergeable PRs remain the human's queue — you never merge. The flag flows through `/loop` verbatim.

**Batch independence (parallel mode):**

- **At most one action per PR.** If a PR matches several steps, take only the highest-priority one (patch > rebase > review).
- **Starts fill remaining capacity:** in-flight count (open agent PRs — including approved-but-unmerged, which hold their module lock — plus `status:claimed` issues) + new starts ≤ N, and each start's `module:` must be distinct from every in-flight task's and from every other start's in the batch. Tasks with no `module:` label are exempt from the module filter (only the ≤ N ceiling bounds them).
- **One batch per tick.** Never dispatch a second wave after results return — the next tick replans from GitHub, which is exactly what picks up human merges, fresh issues, and label changes.

## The tick

0. **Reconcile.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh" --fix`. Note any `fix:` lines.
1. **Auto-merge?** *(Only when `--auto-merge` is set — otherwise skip this step entirely: approved+mergeable PRs stay the human's queue and you never merge.)* For each open agent PR whose linked issue is `status:approved`, read `gh pr view <pr> --json state,mergeable,mergeStateStatus,statusCheckRollup` and merge it **only if** it is `state:OPEN` **and** `mergeable:MERGEABLE` **and** `mergeStateStatus:CLEAN` **and every** check is `SUCCESS` **and** it is **not** labeled `needs-human`: `gh pr merge <pr> --squash`. After each merge, re-run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh" --fix` so dependents unblock before the Start step, and re-check `mergeable` on any remaining candidate (a merge can turn a sibling `DIRTY`). **Never** merge on `DIRTY`/`UNSTABLE`/`BLOCKED`, pending or failing checks, or a `needs-human` PR — CI is the backstop that stops a bad merge (a merge that breaks a test → CI red → not `CLEAN` → not merged). A conflicting-but-approved PR is left to the **Rebase** step, not merged here. In parallel mode these merges run **before** the dispatch batch and do **not** count against N. Ordered highest so freshly-merged work unblocks dependents before anything new starts.
2. **Patch?** `gh pr list --state open --label agent-authored --json number,title` cross-checked with issues labeled `status:changes-requested`. Each match is an action: spawn an agent whose prompt is: *"Run the /delivery-loop:patch-task skill on PR #<pr>."*
3. **Rebase?** An open agent PR whose linked issue is `status:approved` but which `gh pr view <pr> --json mergeable,mergeStateStatus` reports as non-`MERGEABLE` (`DIRTY`) — a sibling merged ahead of it and it now conflicts. **Skip** any such PR labeled `needs-human` or already at max patch iterations (a `Patch iteration: 3/3` comment). Each remaining match: spawn an agent — *"Run the /delivery-loop:patch-task skill on PR #<pr> as a rebase-only patch: it is approved but CONFLICTING behind a merged sibling. Rebase onto the base branch (`BASE_BRANCH`, default `main`), resolve conflicts in the worktree, and push with `--force-with-lease` only as the rebase requires. Keep the issue `status:approved` — do NOT send it back to review."* Ordered ahead of **Start**.
4. **Review?** An open agent PR whose linked issue is `status:in-review` and which has no completed review since its last push. Each match: spawn a **fresh** agent — *"Run the /delivery-loop:review-task skill on PR #<pr>. You have no prior context on this change — that independence is required."*
5. **Start?** If `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh"` is non-empty AND in-flight count < cap (serial: 2; parallel: N; in-flight = open agent PRs + issues labeled `status:claimed`), AND the task's `module:` has no other in-flight task (nor another start in this batch; no-module tasks exempt) → each such task is an action: spawn an implementer — *"Run the /delivery-loop:next-task skill on issue #<n>."* Serial mode considers **only the top task**; parallel mode fills remaining slots best-first in queue order.
6. **Idle.** Nothing to dispatch: render a one-line board summary (counts per bucket) and note what you're waiting on (human merges of approved PRs when `--auto-merge` is off, deps to close, empty queue → suggest `/delivery-loop:decompose`).

## Rules

- **Serial: one action per tick. Parallel: one batch per tick.** Never chain a second dispatch after results return — replanning belongs to the next tick.
- Approved **and mergeable** PRs: with `--auto-merge` **off** (the default) they are the human's queue, not yours — list them, don't touch them; with it **on**, step 1 squash-merges them. Either way, an approved PR that has gone *conflicting* is handled by the **Rebase** step, and a `needs-human` PR is never merged.
- `needs-human` items: mention them in every tick report; never act on them.
- If a spawned agent reports failure (lost claim, refused review), just report it — the next tick's reconcile handles the board. In a parallel batch, one agent's failure never aborts the others: wait for all, report all.
