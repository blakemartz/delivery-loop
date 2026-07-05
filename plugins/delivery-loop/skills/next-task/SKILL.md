---
name: next-task
description: Claim the next ready task off the GitHub Issues queue (or a specific one, e.g. "/next-task 42"), implement it in an isolated worktree to its acceptance criteria, pass the gate, and open a PR. The implementer role of the agentic delivery loop.
---

# next-task — claim → implement → gate → PR

You are the **implementer** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.3, §6). Read `.claude/delivery.conf` for `GATE_CMD` (default `bash scripts/check.sh`), `STYLEGUIDES_DIR`, and `BASE_BRANCH`.

## Protocol (in order; scripts own the mechanics — never re-derive them)

1. **Pick.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh"` — take the first line (or the issue number given as an argument, if it's in the ready set). Empty ready set → report and stop. **Module cap:** skip a task if another open PR or claimed task carries the same `module:` label.
2. **Claim.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/claim-task.sh" <n> agent-$(date +%s)`. Nonzero exit = you lost the race or it's not claimable: report and stop. Never work on an issue assigned to anyone else.
3. **Worktree.** `path=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-worktree.sh" <n>)` — do ALL work inside `$path`. Never touch the main checkout.
4. **Read.** `gh issue view <n>` — the Context and Acceptance criteria are the whole contract. Read the relevant styleguide in `STYLEGUIDES_DIR` before writing code. Match existing patterns.
5. **Implement** to the acceptance criteria, and implement it *well*: among the solutions that satisfy the criteria, pick the best-practice, idiomatic one for the stack (spec §2.1). Nothing more — scope creep in an agent loop is a merge-conflict machine. If satisfying a criterion seems to *require* a non-best-practice solution (a workaround, an anti-pattern), don't silently ship it — comment on the issue and, if it blocks a clean solution, escalate per **If blocked**. **Keep the gate honest:** if your change introduces a linter, test suite, or build step, extend the gate (`GATE_CMD` / `scripts/check.sh`) to cover it — this is how "correct" grows with the repo.
6. **Verify.** Run EVERY acceptance criterion literally, plus the gate (`GATE_CMD`). All must pass. Capture the passing output lines — they're your PR evidence.
7. **Re-verify claim.** `gh issue view <n> --json assignees` — you must still be the sole assignee. If not, stop and report (someone reclaimed it).
8. **Commit & push** from the worktree. If the repo installs git hooks, they fire — **never bypass the gate** (`--no-verify`). If a hook fails, fix the cause. Rebase onto `origin/$BASE_BRANCH` first if behind.
9. **PR.** `gh pr create --title "<task title> (#<n>)" --body ...` following the repo's PR template if present: `Closes #<n>`, summary, acceptance-criteria checklist **with evidence per criterion**, gate status, `Agent-authored (model: <your model>)`. Add label `agent-authored`.
10. **Labels.** `gh issue edit <n> --add-label status:in-review --remove-label status:claimed`.
11. Report the PR URL.

## If blocked

Cannot satisfy a criterion (contradictory spec, missing dependency, environment problem): do NOT push partial work as if complete. Instead:

1. Comment on the issue with exactly what you found and why it blocks you.
2. `gh issue edit <n> --add-label needs-human --remove-label status:claimed --remove-label claim:agent --remove-assignee @me`, then run `NOTIFY_ESCALATE_CMD` if it is set in `.claude/delivery.conf` so the operator hears a task needs them.
3. Stop. (The task deliberately does NOT go back to `status:ready` — a human must look before anyone re-claims it.)

**Encode the lesson:** if the blocker was caused by the harness (ambiguous criteria, template gap, missing gate check), also file a `module:infra` task describing the fix.

## Exit condition

PR URL printed, or a clear report of why you stopped (claim lost / queue empty / needs-human filed).
