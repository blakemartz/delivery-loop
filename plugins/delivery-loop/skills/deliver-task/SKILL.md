---
name: deliver-task
description: Drive one READY task end-to-end — implement in a worktree, independent adversarial review, bounded 3-iteration patch loop, then hand to a human for merge. Pass the issue number, e.g. "/deliver-task 42". A single-command composition of next-task + review-task + patch-task.
---

# deliver-task — one issue → a reviewed PR

You drive a single task through the whole loop yourself by dispatching the other roles as subagents (the Agent tool). One task, one branch, one PR, reviewed by a **fresh** agent, merged by a human. This is the single-task, Level-0 path (runbook §3); for continuous operation use `delivery-tick`.

Read `.claude/delivery.conf` for `NOTIFY_ESCALATE_CMD`. The sub-skills read the rest of the config themselves.

## Input

The issue number to deliver (e.g. `/delivery-loop:deliver-task 42`). It must be a READY task. No argument → report that you need an issue number and stop.

## Independence (the reason this is a composition, not one long session)

The reviewer must be a **fresh agent with no implementer context**. You spawn it as a separate Agent call whose prompt carries only the PR number — never your implementation reasoning. Never review the change yourself. That structural independence is the whole point (spec §3.4).

## Protocol

1. **Implement.** Spawn an agent: *"Run the /delivery-loop:next-task skill on issue #<n>. Report the PR number if you opened one, or why you stopped (claim lost, needs-human filed, queue conflict)."*
   - If it did **not** open a PR (claim lost, blocked → needs-human, queue conflict), report that outcome and STOP — there is nothing to review.

2. **Review → patch loop, at most 3 iterations.** For round i = 1..3:
   1. Spawn a **fresh** agent: *"Run the /delivery-loop:review-task skill on PR #<pr>. You have NO prior context on this change — that independence is required and deliberate. Execute every acceptance criterion in a clean checkout, then approve or request changes via gh. Report the URL of the review you actually posted; if you could not post it, say so explicitly."*
   2. **Unposted verdict = escalate.** If the reviewer reached a verdict but could not post it to the PR, do not trust it (an unposted review did not happen — spec §11, runbook §7). Label the PR and issue `needs-human`, comment that the review could not be posted, run `NOTIFY_ESCALATE_CMD` if it is set, and STOP.
   3. **Approved** → report **"PR #<pr> ready for human merge"** (with round number and the review URL) and STOP. You never merge.
   4. **Unreviewable** (e.g. CI red) → treat like changes-requested; proceed to patch.
   5. If this was round 3, break to step 3 (escalation).
   6. **Patch.** Spawn an agent: *"Run the /delivery-loop:patch-task skill on PR #<pr>."* If it escalates (or dies), label `needs-human`, run `NOTIFY_ESCALATE_CMD` if set, report, and STOP. Otherwise continue to round i+1.

3. **Iterations exhausted.** No approval after 3 review/patch rounds: label the PR and issue `needs-human`, comment a concise summary of the remaining reviewer/patcher disagreement, run `NOTIFY_ESCALATE_CMD` if set, and STOP (spec §9).

## Exit condition

One of: **"ready for human merge"** (with PR + review URL); **"stopped"** (implementer never opened a PR); or **"needs-human"** (unposted verdict, patcher escalation, or 3 rounds without approval) — with the escalation persisted to GitHub, not just reported.
