---
name: task-status
description: Render the delivery board — ready / claimed / in-review / changes-requested / approved / blocked / needs-human — from GitHub Issues and PRs. Pass --reclaim to also reconcile labels and release stale agent claims.
---

# task-status — board overview (+ reclamation)

You are the board renderer (and with `--reclaim`, the reclamation actuator) from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §5).

## Protocol

1. If invoked with `--reclaim`: run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh" --fix` (reconciles blocked/ready labels, releases stale agent claims >4h idle with no PR, pings stale human claims >72h, and auto-closes fully-delivered epics). Report every `fix:` line it emits. Otherwise run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh"` (read-only).
2. Gather the rest of the board:
   - `gh issue list --label task --state open --limit 200 --json number,title,labels,assignees,updatedAt`
   - `gh issue list --label needs-human --state open --json number,title`
   - `gh pr list --state open --json number,title,labels,statusCheckRollup,reviewDecision`
3. Render one compact table per bucket, in this order (most actionable first):
   - **needs-human** — issue, what's stuck (from the latest comment)
   - **approved, awaiting human merge** — PR, linked issue
   - **changes-requested** — PR, iteration count
   - **in-review** — PR, CI status, review state
   - **claimed** — issue, assignee, human-or-agent, idle time
   - **ready** — the queue output, in order
   - **blocked** — issue, which unmet deps
4. End with a one-line "next action" suggestion: what a single `delivery-tick` would do right now.

Read-only apart from `--reclaim`. Never claim, review, or edit anything else here.
