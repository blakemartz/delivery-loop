# delivery-loop (plugin)

The plugin implementation. See the [repo README](../../README.md) for install,
configuration, and the full walkthrough.

- `skills/` — the seven `/delivery-loop:*` skills (init, decompose, next-task,
  review-task, patch-task, delivery-tick, task-status).
- `scripts/` — the engine the skills drive:
  - `task-queue.sh` — compute the ready set; `--fix` reconciles labels, reaps
    stale claims, and closes delivered epics.
  - `claim-task.sh` + `lib/*.jq` — comment-ordered claim arbitration (unit-tested
    in `tests/`).
  - `task-worktree.sh` — create / reuse / clean up a task's isolated worktree.
  - `delivery-init.sh` — one-time repo bootstrap (labels + config + gitignore).
  - `lib/config.sh` / `delivery-config.sh` — resolve `.claude/delivery.conf`.
- `docs/` — `agentic_delivery_spec.md` (design) and `delivery_runbook.md`
  (operator manual), which the skills cite by section.

Scripts reference themselves via `${CLAUDE_PLUGIN_ROOT}` so they resolve wherever
the plugin is installed; per-repo behavior comes entirely from
`.claude/delivery.conf` in the consuming repo.
