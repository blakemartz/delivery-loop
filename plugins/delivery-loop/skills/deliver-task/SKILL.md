---
name: deliver-task
description: Drive one READY task end-to-end — implement in a worktree, independent adversarial review, bounded 3-iteration patch loop, then hand to a human for merge. Pass the node id, e.g. "/deliver-task 42". A single-command composition of next-task + review-task + patch-task.
---

# deliver-task — one task → a reviewed PR

You drive a single task through the whole loop yourself by dispatching the other roles as subagents (the Agent tool). One task, one branch, one PR, reviewed by a **fresh** agent, merged by a human. This is the single-task, Level-0 path (runbook §3); for continuous operation use `delivery-tick`.

Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`. Take `NOTIFY_ESCALATE_CMD` from `bash "$S/delivery-config.sh"` (the resolved `KEY=value` lines: defaults, `.claude/delivery.conf`, then environment) — never by reading the conf file yourself. The sub-skills resolve the rest of the config themselves. Every graph read or write goes through `graph.sh`, every PR read or post through `forge.sh`; never call the tracker's or forge's CLI or API directly. Keep scratch files under a private `TMPDIR` (`export TMPDIR=$(mktemp -d)`).

## Input

The node id to deliver (e.g. `/delivery-loop:deliver-task 42`; on a local backend a slug such as `auth-3`). It must be a READY node (`bash "$S/graph.sh" ready` lists it). No argument → report that you need a node id and stop.

## Independence (the reason this is a composition, not one long session)

The reviewer must be a **fresh agent with no implementer context**. You spawn it as a separate Agent call whose prompt carries only the PR number — never your implementation reasoning. Never review the change yourself. That structural independence is the whole point (spec §3.4).

## Protocol

1. **Implement.** Spawn an agent: *"Run the /delivery-loop:next-task skill on task <id>. Report the PR number if you opened one, or why you stopped (claim lost, needs-human filed, queue conflict)."*
   - If it did **not** open a PR (claim lost, blocked → needs-human, queue conflict), report that outcome and STOP — there is nothing to review.

2. **Review → patch loop, at most 3 iterations.** For round i = 1..3:
   1. Spawn a **fresh** agent: *"Run the /delivery-loop:review-task skill on PR #<pr>. You have NO prior context on this change — that independence is required and deliberate. Run the gate on a clean checkout of the head AND on the merged result (base + head), execute every acceptance criterion, then post the verdict with forge.sh pr-review --sha set to the head_sha you read yourself from forge.sh pr-view <pr>. Report the URL of the verdict you actually posted; if you could not post it, say so explicitly."* Pass no SHA of your own: the reviewer pins the head it read and reviewed.
   2. **Checks still pending** (the reviewer posted nothing because it would approve while CI is `pending`, `review-task` step 7): this is not a failed post. Wait until `bash "$S/forge.sh" pr-view <pr>` shows `checks` other than `pending`, then re-run sub-step 1 for this same round.
   3. **Unposted verdict = escalate.** If the reviewer reached a verdict but could not post it to the PR, do not trust it (an unposted review did not happen — spec §11, runbook §7). **Escalate** (below) with "the review could not be posted", and STOP.
   4. **Approved** — confirm with `bash "$S/graph.sh" show <id>` that `.status` is `approved` → report **"PR #<pr> ready for human merge"** (with round number and the verdict URL) and STOP. You never merge.
   5. **Unreviewable** (e.g. CI red) → treat like changes-requested; proceed to patch.
   6. If this was round 3, break to step 3 (escalation).
   7. **Patch.** Spawn an agent: *"Run the /delivery-loop:patch-task skill on PR #<pr>."* If it escalates (or dies), **escalate** if it has not already, report, and STOP. Otherwise continue to round i+1.

3. **Iterations exhausted.** No approval after 3 review/patch rounds: **escalate** with a concise summary of the remaining reviewer/patcher disagreement, and STOP (spec §9).

**Escalate** = persist it, don't just report it: write the summary to `"$TMPDIR/escalation.md"`, post it with `bash "$S/forge.sh" pr-comment <pr> --body-file "$TMPDIR/escalation.md"`, then `bash "$S/graph.sh" flag <id> needs-human on` and `bash "$S/graph.sh" comment <id> "Escalated to needs-human: see PR #<pr>"`, and run `NOTIFY_ESCALATE_CMD` if it is set. The summary lives only on the PR. The node gets just that pointer, never the summary, because a later reviewer reads every free-text node comment as contract (`review-task` step 2) and would take one side of the disagreement as the orchestrator's instruction.

## Exit condition

One of: **"ready for human merge"** (with PR + verdict URL); **"stopped"** (implementer never opened a PR); or **"needs-human"** (unposted verdict, patcher escalation, or 3 rounds without approval) — with the escalation persisted to the graph and the PR, not just reported.
