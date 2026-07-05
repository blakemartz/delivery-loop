---
name: init
description: Bootstrap the delivery loop in the current repo — create the GitHub label taxonomy, scaffold .claude/delivery.conf, and gitignore .worktrees/. Run once per repo. Idempotent.
---

# init — bootstrap this repo for the delivery loop

One-time, idempotent setup. Runs the bundled bootstrap, then tells the human the one thing they must edit.

## Protocol

1. Run: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-init.sh" $ARGUMENTS`
   (any arguments become extra `module:<name>` labels). It creates the labels, scaffolds `.claude/delivery.conf` + `.gitignore`, and — from detected tooling — seeds a starter `scripts/check.sh`, the gate `GATE_CMD` points at.

2. **Establish the gate — the one thing that needs your judgment.** Open the seeded `scripts/check.sh` and reconcile it with what the repo *actually* runs, preferring the repo's own declared commands over guessed ones. Check `package.json` scripts, a `Makefile`/`justfile` `check`/`test` target, and CI steps in `.github/workflows/` for the real commands.
   - **Tooling detected:** show the human the seeded `check.sh`, note any declared command it should use instead (e.g. the repo has a `make check` that bundles more than init found), and adjust on their confirmation.
   - **No tooling detected** (the seed exits 1 by design — an undefined gate is a *failing* gate, never a green one): tell the human plainly that no linter/type-checker/test framework was found, and **suggest a sensible starter set** for the detected language (e.g. ruff + mypy + pytest for Python; eslint + tsc + vitest for TS; `go vet`/`build`/`test` for Go). Wire in whatever they approve; leave the failing guard if they defer.

3. Report what was created/changed (labels, `.claude/delivery.conf`, `.gitignore`, `scripts/check.sh`).

4. Remind the human to enable squash-merge if they haven't:
   `gh repo edit --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge`.

5. Suggest the next step: `/delivery-loop:decompose` to propose a backlog.

## Exit condition

Bootstrap ran; `scripts/check.sh` runs the repo's real checks (or the human has a concrete plan to add them), and the loop can now decompose a backlog.
