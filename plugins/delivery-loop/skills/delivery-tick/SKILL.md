---
name: delivery-tick
description: One orchestrator tick of the agentic delivery loop - reconcile the board, ask tick-plan.sh for the action plan, and execute it in order (deterministic merges and promotions first, then exactly ONE agent action — or, with "--parallel N", one batch of up to N independent agent actions awaited together). With --auto-merge (opt-in, off by default) the plan may merge fully-approved, clean, green PRs through tick-merge.sh, which gates the merged result first. Designed as the /loop target.
---

# delivery-tick — one tick of the orchestrator loop

You are the **orchestrator** from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.1, §6, §8, §9). You dispatch; you never implement, review, or patch yourself, and you **decide nothing**: `tick-plan.sh` chooses every action, and you execute its plan in order. The only merges are `tick-merge.sh`'s, the only promotions are `promote.sh`'s.

Every graph read or write goes through `graph.sh`, every PR read through `forge.sh` (`pr-view <n>`, `pr-list --state open`). Never call the forge's CLI or API directly. The script headers under `${CLAUDE_PLUGIN_ROOT}/scripts/` are the authoritative contract for every flag, output, and exit code below. Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`.

Dispatch an agent role by spawning an agent (Agent tool) whose prompt names the plugin skill, e.g. *"Run the /delivery-loop:next-task skill on task <id>."* Keep each script's stderr in a scratch file under a private `TMPDIR`, never interleaved with the stdout you parse.

## Flags

Pass only these through to `tick-plan.sh`, verbatim and in any order; drop anything else:

- `--parallel [N]` (or `--parallel=N`) — parallel mode. `tick-plan.sh` parses N (bare or not a whole number → 3; above 16 → 16; 1 or lower → serial) and reports it as `mode`. Never re-parse it yourself.
- `--auto-merge` — off by default. Only with it does the plan carry `merge` actions. Without it approved PRs are the human's queue: list them, never touch them.

## The tick

1. **Reconcile.** `bash "$S/graph.sh" reconcile --fix`. Stdout is one `fix: <op> <id> <from> -> <to>: <reason>` line per applied record; `warn: …` lines go to stderr. Exit 4 (board changed) or 75 (backend busy): re-run, up to 3 passes in all, then carry on (the plan reads fresh state). Any other nonzero exit: report it and **stop the tick** — never plan over a board you could not reconcile. Note every `fix:` line for the report.
2. **Plan.** `plan=$(bash "$S/tick-plan.sh" [--parallel N] [--auto-merge])`. Exit 1 (invalid config or a failed read) or 2 (usage): report and stop. Stdout is one JSON object:
   - `mode` — `{name: "serial"|"parallel", n}`; `n` is the agent-action cap (serial 1).
   - `actions` — `[{action, pr?, id?, sha?, reason}]` in execution order: every `merge` (with `pr`, `id`, `sha`), then every `promote` (`id`), then the agent actions `patch` / `rebase` / `review` (with `pr`, `id`) and `start` (`id`).
   - `board` — `{<status>: count}` over task and promote nodes.
   - `waiting` — `[string]`: why nothing more is happening (needs-human items, approved PRs awaiting a human, caps, module locks, deferrals).
3. **Execute the plan's actions in order.** The plan already applies every priority, cap, and lock rule; do not add, drop, reorder, or re-derive actions — except as the merge results below direct.
   - **`merge`** — one at a time, in plan order, never concurrently (each merge moves the base the next one is gated against): `out=$(bash "$S/tick-merge.sh" <pr> <sha> 2>"$log")`, with `<sha>` the action's `sha`. It re-reads the PR (re-polling past a still-`unknown` mergeability), re-applies the §5 merge rule, runs `GATE_CMD` on the **merged result** in a fresh worktree, refuses if the base moved meanwhile, merges with `TASK_MERGE_METHOD` pinned to `<sha>`, verifies `merged`, then reconciles. Outcomes:
     - exit 0, stdout `{pr, result: "merged", sha}` → merged and confirmed. Only now: `bash "$S/task-worktree.sh" --cleanup <id>`.
     - exit 1, stdout `{action: "rebase", pr, id, reason}` → the merged result conflicts or is red. Add it to the agent actions at rebase priority (after patches, before reviews and starts).
     - exit 1, no stdout, and stderr says `is at patch iteration <k>/3: needs a human update` → the patch cap is reached: escalate (below).
     - any other exit 1 → refused (head moved, checks red, base moved, mergeability still `unknown`, no longer eligible): report the stderr reason and move on. The next tick re-plans; never retry the merge by hand.
   - **`promote`** — `bash "$S/promote.sh" <id>`. Exit 0, stdout `{id, result: "nothing-to-promote"|"promoted", pr?, url?}`: report it. Exit 1: report the stderr reason; a red gate has already flagged the node needs-human, commented, and run `NOTIFY_ESCALATE_CMD`, and any other failure released the claim for the next tick. A promotion PR is **never** merged by the tick, `--auto-merge` or not: a human merges it with `PROMOTE_MERGE_METHOD`.
   - **Agent actions** — after every merge and promote: take the plan's agent actions plus any rebase actions `tick-merge.sh` printed, truncate to `mode.n` (serial: the first one only), and dispatch them. In parallel mode spawn every agent **in a single message**, then WAIT for the whole batch and report each outcome. Anything truncated is picked up by a later tick, which re-plans it. Prompts:
     - `patch` → *"Run the /delivery-loop:patch-task skill on PR #<pr>."*
     - `rebase` → *"Run the /delivery-loop:patch-task skill on PR #<pr> as a rebase-only patch: it is approved but conflicts with (or is red against) its target branch after a sibling merged. Update it onto the node's target branch in its task worktree, resolve conflicts, re-run `GATE_CMD`, and push — with `--force-with-lease` only if a rebase requires it. Keep the node `approved`: do NOT send it back to review."*
     - `review` → spawn a **fresh** agent: *"Run the /delivery-loop:review-task skill on PR #<pr>. You have no prior context on this change — that independence is required."*
     - `start` → *"Run the /delivery-loop:next-task skill on task <id>."*
4. **Report.** One line per action taken and its outcome, every `fix:` line, the `board` counts, and every `waiting` line. When nothing ran, say what the board waits on: human merges of approved PRs (without `--auto-merge`), deps to close, needs-human items, or an empty queue (suggest `/delivery-loop:decompose`).

**Escalate (patch cap).** When `tick-merge.sh` reports the patch iteration at the cap, the PR can no longer be rebased by the loop: `bash "$S/graph.sh" flag <id> needs-human on`, `bash "$S/graph.sh" comment <id> "<the tick-merge reason>: the merged result is red or conflicting at the patch cap; a human must update PR #<pr>"`, then run `NOTIFY_ESCALATE_CMD` if it is set. Escalate once; the flag stops the plan from emitting it again.

## Rules

- **Serial: one agent action per tick. Parallel: one batch per tick.** Merges and promotes run first and do not count against `mode.n`. Never dispatch a second wave or re-plan after results return — the batch barrier is what makes `/loop` safe (two batches never overlap), and the next tick replans from the graph, which is what picks up human merges, new tasks, and status changes.
- **≤ 1 in-flight task per module** (per target branch). `tick-plan.sh` enforces it — open agent PRs, approved-but-unmerged ones included, hold their module's lock, and so do `claimed` nodes. Never start a task the plan did not emit, and never start one by hand to fill a slot.
- **Patch cap: 3.** At `Patch iteration: 3/3` the plan still emits `patch` once, and `patch-task` itself escalates (needs-human, `NOTIFY_ESCALATE_CMD`, stop). An approved, conflicting PR at the cap is only a `waiting` line; a red merged result at the cap is escalated by the tick (above). Never dispatch past the cap.
- **Never clean up a worktree before the merge is confirmed.** `task-worktree.sh --cleanup` force-removes the worktree and its branch, and patchers and rebases reuse it. Clean up only after `tick-merge.sh` exits 0 with `result: "merged"`, or for a task a reconcile `fix:` line moved to `done` because its PR merged. Never on a refusal, a `rebase` result, or a merely approved PR.
- **`unknown` mergeability is not a verdict.** A forge that is still computing mergeability (common right after a push or a sibling's merge) reports `unknown`; the forge adapter and `tick-merge.sh` re-poll past it. If it is still `unknown`, the PR is neither merged nor treated as conflicting: it is a `waiting` line or a refusal, and a later tick re-plans it. Never merge around it, and never dispatch a rebase the plan did not emit.
- `needs-human` items: mention them in every tick report; never act on them.
- If a spawned agent or a script reports failure (lost claim, refused review, refused merge), report it — the next tick's reconcile handles the board. In a parallel batch one agent's failure never aborts the others: wait for all, report all.
