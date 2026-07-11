---
name: init
description: Bootstrap the delivery loop in the current repo — create/connect the GitHub repo if needed, create the label taxonomy, scaffold .claude/delivery.conf, seed the gate and styleguides stub, gitignore .worktrees/. Run once per repo. Idempotent.
---

# init — bootstrap this repo for the delivery loop

One-time, idempotent setup. Runs the bundled bootstrap, then walks the human through the judgment calls the script can't make.

## Protocol

1. Run: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-init.sh" $ARGUMENTS`
   (any arguments become extra `module:<name>` labels). Local scaffolding runs first — `.claude/delivery.conf`, `.gitignore`, a seeded `scripts/check.sh` (the gate `GATE_CMD` points at), and a `STYLEGUIDES_DIR` stub — then the GitHub steps (labels).

2. **No GitHub repo connected (script exits 2).** The backlog lives in GitHub Issues, so this is a hard prerequisite. Ask the human which they want (outward-facing — never do it unasked):
   - a brand-new repo: `gh repo create <name> --private --source=. --push` (confirm name and visibility first), or
   - connect an existing one: `git remote add origin <url>` and push the base branch.
   Then re-run the script — it's idempotent and will finish the labels.

3. **Issues disabled (script warns).** Common on forks. Ask the human to confirm, then run `gh repo edit --enable-issues` — without Issues the loop is inert.

4. **Establish the gate — the thing that needs the most judgment.** Open the seeded `scripts/check.sh` and reconcile it with what the repo *actually* runs, preferring the repo's own declared commands over guessed ones. Check `package.json` scripts, a `Makefile`/`justfile` `check`/`test` target, and CI steps in `.github/workflows/` for the real commands.
   - **Tooling detected:** show the human the seeded `check.sh`, note any declared command it should use instead (e.g. the repo has a `make check` that bundles more than init found), and adjust on their confirmation.
   - **No tooling detected** (the seed exits 1 by design — an undefined gate is a *failing* gate, never a green one): tell the human plainly that no linter/type-checker/test framework was found, and **suggest a sensible starter set** for the detected language (e.g. ruff + mypy + pytest for Python; eslint + tsc + vitest for TS; `go vet`/`build`/`test` for Go). Wire in whatever they approve; leave the failing guard if they defer.

5. Report what was created/changed (labels, `.claude/delivery.conf`, `.gitignore`, `scripts/check.sh`, the styleguides stub).

6. Remind the human to enable squash-merge if they haven't:
   `gh repo edit --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge`.

7. **Point at the next seam that's actually missing** — check, don't assume:
   - `STYLEGUIDES_DIR` empty or stub-only → `/delivery-loop:author-styleguides` (the conventions agents implement and review against — without them reviewers enforce an empty constitution).
   - Nothing matches `SPEC_SOURCES` → `/delivery-loop:author-spec` to author the first spec (decompose has nothing to read until one exists).
   - Both exist → `/delivery-loop:decompose` to propose a backlog.

## Exit condition

Bootstrap ran against a connected GitHub repo with Issues enabled; `scripts/check.sh` runs the repo's real checks (or the human has a concrete plan to add them); and the human knows which seam comes next — styleguides, first spec, or straight to decompose.
