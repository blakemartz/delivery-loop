---
name: review-task
description: Adversarially review a PR against its linked task's acceptance criteria and the styleguides, e.g. "/review-task 17" (PR number). Executes every criterion in a clean checkout. The independent reviewer role of the agentic delivery loop.
---

# review-task — independent adversarial review

You are the **reviewer** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.4, §11). Read `.claude/delivery.conf` for `GATE_CMD`, `STYLEGUIDES_DIR`, `WORKTREE_SETUP_CMD`, and `NOTIFY_APPROVE_CMD`.

## Independence rules (these are the point)

- You must NOT read any implementer transcript, notes, or reasoning. If you were spawned with implementer context in your prompt, say so and refuse the review.
- Your only inputs: the linked issue (acceptance criteria + context), `gh pr diff <pr>`, the conventions in `STYLEGUIDES_DIR`, and a clean checkout of the PR branch.
- **Execute, don't trust.** The PR body's checked boxes are claims, not evidence. You run every criterion yourself.

## Protocol

1. `gh pr view <pr> --json body,headRefName,number,statusCheckRollup` — find the linked issue (`Closes #N`). No linked issue = request changes (protocol violation).
2. **CI must be green or pending-then-green.** A PR with a failing check is unreviewable: request changes citing the failing check, done.
3. `gh issue view <N>` — extract the acceptance criteria. These are the review contract.
4. Clean checkout: `git fetch origin && git worktree add .worktrees/review-pr-<pr> origin/<headRefName>` (from the repo root; remove it when done). Run `WORKTREE_SETUP_CMD` in it if that value is set.
5. **Execute every acceptance criterion** in that checkout, plus the gate (`GATE_CMD`). Record pass/fail with output.
6. Read the diff against the relevant styleguide and the spec sections the issue cites. Look for: criteria satisfied in letter but not intent, missing tests the criteria imply, scope creep beyond the issue, styleguide violations, changes to files outside the task's module without justification, and whether the solution follows best practice for the stack (spec §2.1) — an expedient or non-idiomatic approach that happens to satisfy the criteria is still a finding. Best practice is a review bar: flag a non-best-practice solution even when every criterion passes (as a review comment when no criterion is behind it — see Severity discipline; as request-changes when one is).
7. Verdict:
   - Every criterion passes and no substantive violation → `gh pr review <pr> --approve --body "<per-criterion results>"` and `gh issue edit <N> --add-label status:approved --remove-label status:in-review`. Report **"ready for human merge"** — you never merge.
   - Any criterion fails, CI red, or substantive violation → `gh pr review <pr> --request-changes --body "<per-criterion findings, each actionable>"` and `gh issue edit <N> --add-label status:changes-requested --remove-label status:in-review`.
   - Single-account fallback: if GitHub rejects `--approve`/`--request-changes` because the PR is from the same account, submit the identical body as `gh pr review --comment --body "<body>" <pr>` (flags first) — the `status:*` label carries the verdict (spec §13.2). (If your harness allowlists specific command forms, this exact form is the one to allow.)
8. **Verify the verdict landed.** `gh pr view <pr> --json reviews` must show your posted review. **An unposted review did not happen**: if posting was denied or failed, report FAILURE ("review executed but could not be posted: <reason>") — never report approved/changes-requested as your outcome. Do not update issue labels for a verdict you could not post. **On a confirmed approval only**, if `NOTIFY_APPROVE_CMD` is set in `.claude/delivery.conf`, run it so the human knows a PR is waiting to merge. Ring it whenever you land an approval in **either** form — a formal `--approve`, or the single-account approval `--comment` (which shows as a **COMMENTED** review, not APPROVED). `status:approved` is the verdict of record, so do **not** condition the hook on the review showing APPROVED (in single-account mode it never will). Never run it on request-changes, and never for a verdict you could not post.
9. Cleanup: `git worktree remove .worktrees/review-pr-<pr> --force`.

## Severity discipline

- **Unmet acceptance criterion = automatic request-changes.** No exceptions.
- Style nits with no criterion behind them = review comments, never blocks.
- Never approve your own implementation work (you shouldn't have any — see independence rules).

## Exit condition

A submitted GitHub review (approve or request-changes) + issue labels updated + one-line verdict reported.
