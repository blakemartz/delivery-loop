---
name: init
description: Bootstrap the delivery loop in the current repo — pick or detect the graph backend and forge, scaffold .claude/delivery.conf, seed the gate and styleguides stub, gitignore .worktrees/, create the local store or the label taxonomy, and check forge auth. Run once per repo. Idempotent.
---

# init — bootstrap this repo for the delivery loop

One-time, idempotent setup. Runs the bundled bootstrap, then walks the human through the judgment calls the script can't make. Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`. The script header of `delivery-init.sh` is the authoritative contract for its steps, output, and exit codes.

## Protocol

1. **Choose the seams.** Two keys decide where the loop keeps its state: `GRAPH_BACKEND` (`github`: the backlog is GitHub Issues; `local`: JSON files in `STATE_DIR`, no issue tracker) and `FORGE` (`github` | `gitlab` | `gitea`, where the PRs live). `GRAPH_BACKEND=github` requires `FORGE=github`.
   - If `.claude/delivery.conf` exists, the script uses its resolved values: skip to step 2.
   - Otherwise the script takes `FORGE` from the environment or detects it from the `origin` remote's host, and defaults `GRAPH_BACKEND` to `github` on a github forge and `local` on any other. Ask the human only when that would be wrong for them (no remote yet, a self-hosted host, or GitHub without Issues → `local`), then pass the choice in the environment: `GRAPH_BACKEND=<b> FORGE=<f> bash "$S/delivery-init.sh" …`.
   - A gitlab or gitea forge needs `GITLAB_TOKEN` / `GITEA_TOKEN` in the environment (never in the conf file); a self-hosted one may also need `FORGE_URL` and `FORGE_REPO` set in the conf after the first run.
2. **Run:** `bash "$S/delivery-init.sh" $ARGUMENTS` (on the github backend, any arguments become extra `module:<name>` labels; on local, list modules in `MODULES` instead). It prints `==> seams: GRAPH_BACKEND=<b> FORGE=<f> (<source>)`, checks its requirements (jq always; git ≥ 2.31 for the local backend; an authenticated `gh` only when a seam is github, and gh ≥ 2.94 for the github backend), then:
   - local scaffolding first — `.gitignore`, a seeded `scripts/check.sh` (the gate `GATE_CMD` points at), `.claude/delivery.conf` with every key, a `STYLEGUIDES_DIR` stub, and on the local backend the `STATE_DIR` store (empty `STATE_DIR` = `<git-common-dir>/delivery`, shared by every worktree);
   - then, with a remote: forge auth via `forge.sh whoami` (`==> forge: <forge>, authenticated as <login>`), and on the github backend the label taxonomy (kind, status, claim, authorship, size, `promote`, `module:*`). The local backend creates no labels.
   Exit 1: a requirement or step failed (an invalid seam combination writes nothing); report the `ERROR:` / `config:` line and fix the cause with the human, then re-run.
3. **No remote connected (exit 2).** The PRs live on the forge, so this is a hard prerequisite. Ask the human which they want (outward-facing — never do it unasked):
   - a brand-new repo on the forge (on github: `gh repo create <name> --private --source=. --push`; confirm name and visibility first), or
   - connect an existing one: `git remote add origin <url>` and push the base branch.
   Then re-run the script — it's idempotent and finishes the forge steps.
4. **Issues disabled (github backend; the script warns).** Common on forks. Ask the human to confirm, then run `gh repo edit --enable-issues` — without Issues the github backend is inert. Or switch to `GRAPH_BACKEND=local` if they would rather not use Issues.
5. **Establish the gate — the thing that needs the most judgment.** Open the seeded `scripts/check.sh` and reconcile it with what the repo *actually* runs, preferring the repo's own declared commands over guessed ones. Check the package manifest's scripts, a `Makefile`/`justfile` `check`/`test` target, and the CI configuration for the real commands.
   - **Tooling detected:** show the human the seeded `check.sh`, note any declared command it should use instead (e.g. the repo has a `make check` that bundles more than init found), and adjust on their confirmation.
   - **No tooling detected** (the seed exits 1 by design — an undefined gate is a *failing* gate, never a green one): tell the human plainly that no linter/type-checker/test framework was found, and **suggest a sensible starter set** for the detected language (e.g. ruff + mypy + pytest for Python; eslint + tsc + vitest for TS; `go vet`/`build`/`test` for Go). Wire in whatever they approve; leave the failing guard if they defer.
6. Report what was created or changed (the seams, `.claude/delivery.conf`, `.gitignore`, `scripts/check.sh`, the styleguides stub, the local store or the labels, the forge login).
7. **Repo merge settings** — relay the script's advice; the human applies it (outward-facing). **Keep merge commits enabled**: task PRs merge with `TASK_MERGE_METHOD` (default squash), but promotion PRs merge with `PROMOTE_MERGE_METHOD` (default merge, which keeps the release branch's ancestry), and a forge refuses a merge style the repo disallows. On github the script prints the `gh repo edit` line (squash and merge commits enabled, rebase merges off, head branches deleted on merge); on gitlab and gitea it names the settings to change.
8. **Point at the next seam that's actually missing** — check, don't assume:
   - `STYLEGUIDES_DIR` empty or stub-only → `/delivery-loop:author-styleguides` (the conventions agents implement and review against — without them reviewers enforce an empty constitution).
   - Nothing matches `SPEC_SOURCES` → `/delivery-loop:author-spec` to author the first spec (decompose has nothing to read until one exists).
   - Both exist → `/delivery-loop:decompose` to propose a backlog.

## Exit condition

Bootstrap ran to exit 0 against a connected remote with forge auth confirmed (and, on the github backend, Issues enabled); `scripts/check.sh` runs the repo's real checks (or the human has a concrete plan to add them); the human has the merge-settings advice; and they know which seam comes next — styleguides, first spec, or straight to decompose.
