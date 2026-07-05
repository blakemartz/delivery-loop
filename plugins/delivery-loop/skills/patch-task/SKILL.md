---
name: patch-task
description: Respond to review findings or failing CI on an existing agent PR, e.g. "/patch-task 17" (PR number). Bounded to 3 iterations, then escalates to a human. The patcher role of the agentic delivery loop.
---

# patch-task — fix a PR that got changes-requested

You are the **patcher** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.5, §9). Read `.claude/delivery.conf` for `GATE_CMD`, `BASE_BRANCH`, and `NOTIFY_ESCALATE_CMD`.

## Protocol

1. **Check the iteration budget.** `gh pr view <pr> --json comments` — find the latest `Patch iteration: n/3` comment. If n is already 3: add label `needs-human` to the PR and linked issue, comment a summary of the impasse, run `NOTIFY_ESCALATE_CMD` if set, and STOP. Do not patch.
2. **Gather findings.** The review: `gh pr view <pr> --json reviews,comments` (request-changes body + line comments). CI: `gh pr checks <pr>` — read the failing run logs via `gh run view <run-id> --log-failed` if red.
3. **Re-enter the task worktree.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-worktree.sh" <issue#>` returns the existing worktree (it re-creates it from the branch if it was cleaned up). Work only there.
4. **Fix every finding.** Address each review point and each failing check — and fix it toward the best-practice, idiomatic solution (spec §2.1), not just enough to silence the finding. If you disagree with a finding, don't silently ignore it — reply to the review comment with your reasoning and make the call visible.
5. **Rebase** onto `origin/$BASE_BRANCH` if behind. Resolve conflicts here in the worktree. **Never force-push over review history** (after a rebase, `--force-with-lease` is acceptable only if the rebase itself required it; prefer plain pushes of fixup commits).
6. **Re-verify.** Every acceptance criterion from the linked issue + the gate (`GATE_CMD`). Hooks fire on commit/push; never bypass the gate.
7. **Push**, then: comment `Patch iteration: <n+1>/3` plus a short change summary on the PR; flip the issue back: `gh issue edit <N> --add-label status:in-review --remove-label status:changes-requested`.
8. Report what changed and that the PR awaits re-review.

**Encode the lesson:** if the finding traces back to a harness gap (a criterion the gate should have caught, an ambiguous template), file a `module:infra` task.

## Rebase-only mode (approved-but-conflicting PRs)

The orchestrator (`delivery-tick` step 3, spec §8.2) dispatches this skill on an **already-approved** PR that went `CONFLICTING` after a sibling merged ahead of it. Same protocol, with three differences:

- **No review findings to fix** — the PR is approved, so steps 2/4 have nothing to address; the work *is* the rebase (step 5). Rebase onto `origin/$BASE_BRANCH`, resolve conflicts in the worktree, re-verify with `GATE_CMD`, and push with `--force-with-lease` only as the rebase requires (never a plain force over review history — spec §8).
- **Preserve the approval.** Step 7 does NOT flip labels: the approval still stands after a mechanical rebase, so keep the linked issue `status:approved` — do not add `status:in-review` or touch `status:changes-requested`. Comment `Patch iteration: <n+1>/3 (rebase)` so repeated re-conflicts stay bounded.
- **Same iteration budget** (step 1): at `3/3`, or if the PR is already `needs-human`, escalate and STOP instead of rebasing again — no rebase loop.

## Exit condition

Push + iteration comment + labels flipped (or, in rebase-only mode, approval preserved), or a `needs-human` escalation with summary.
