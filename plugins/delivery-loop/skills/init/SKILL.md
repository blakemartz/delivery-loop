---
name: init
description: Bootstrap the delivery loop in the current repo — create the GitHub label taxonomy, scaffold .claude/delivery.conf, and gitignore .worktrees/. Run once per repo. Idempotent.
---

# init — bootstrap this repo for the delivery loop

One-time, idempotent setup. Runs the bundled bootstrap, then tells the human the one thing they must edit.

## Protocol

1. Run: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-init.sh" $ARGUMENTS`
   (any arguments become extra `module:<name>` labels).
2. Report what it created/changed (labels, `.claude/delivery.conf`, `.gitignore`).
3. Remind the human to **edit `.claude/delivery.conf`** — at minimum set `GATE_CMD` to the repo's check command — and to enable squash-merge if they haven't:
   `gh repo edit --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge`.
4. Suggest the next step: `/delivery-loop:decompose` to propose a backlog.

## Exit condition

Bootstrap ran; the human knows to set `GATE_CMD` and can now decompose a backlog.
