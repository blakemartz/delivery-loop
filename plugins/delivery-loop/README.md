# delivery-loop (plugin)

The plugin implementation. See the [repo README](../../README.md) for install,
configuration, and the full walkthrough.

- `skills/` — the ten `/delivery-loop:*` skills (init, author-styleguides,
  author-spec, decompose, next-task, review-task, patch-task, deliver-task,
  delivery-tick, task-status). They call the scripts below and never an issue
  tracker's or forge's CLI or API directly.
- `scripts/` — the engine the skills drive. Each script's header is its
  authoritative contract (ops, output, exit codes).
  - **Seams**
    - `graph.sh` — the work graph: `ready`, `list`, `show [--format md]
      [--events]`, `export`, `create`, `update`, `link`, `flag`, `claim`,
      `release`, `comment`, `transition`, `reconcile [--fix]`, `migrate
      [--apply]`. Validates every node and applies the policy core.
    - `forge.sh` — PRs: `whoami`, `pr-create`, `pr-view`, `pr-list`, `pr-find`,
      `pr-review`, `pr-reviews`, `pr-comment(s)`, `pr-merge`, `pr-set-base`,
      `pr-files`, `pr-diff`, `ci-failures`.
    - `backends/graph-github.sh` (+ `graph-github.jq`) and
      `backends/graph-local.sh` — the graph backends (`GRAPH_BACKEND`).
    - `backends/forge-{github,gitlab,gitea}.sh` (+ `.jq`) and
      `backends/forge-verdict.jq` — the forge adapters (`FORGE`) and the shared
      comment-form verdict rule.
  - **Loop actions**
    - `tick-plan.sh` — the orchestrator tick's action plan (`--parallel [N]`,
      `--auto-merge`); changes nothing.
    - `tick-merge.sh` — the tick's `merge` action: re-check eligibility, gate
      the merged result, merge pinned to the head.
    - `promote.sh` — the tick's `promote` action: gate the target branch, open
      the promotion PR.
    - `plan.sh` — plan files: `lint`, `render` (Mermaid), `apply`.
    - `task-worktree.sh` — create / reuse / clean up a task's isolated worktree,
      forked from its target branch.
  - **Compatibility wrappers (v0.1.4 interface)**
    - `task-queue.sh` — the ready set in v0.1.4's format; `--fix` reconciles
      first.
    - `claim-task.sh` — claim a task (`graph.sh claim`).
  - **Setup and config**
    - `delivery-init.sh` — one-time repo bootstrap (seams, config, gate seed,
      styleguides stub, gitignore, labels or local store, forge auth check).
    - `lib/config.sh` / `delivery-config.sh` — resolve `.claude/delivery.conf`
      (defaults < file < environment); `delivery-config.sh --check` validates
      the combination and the jq version.
  - **Policy core (`lib/*.jq`, pure, unit-tested)** — `node.jq`, `pr.jq`,
    `shape.jq` (shapes); `graph.jq`, `ready.jq`, `transitions.jq`,
    `reconcile.jq`, `tick-plan.jq` (policy); `claim-winner.jq`,
    `orphan-claims.jq`, `claim-ledger.jq` (the github claim lock);
    `plan-lint.jq`, `plan-render.jq`, `plan-apply.jq`, `plan-verify.jq` (plan
    files). `lib/worktree-gate.sh` runs a gate in a throwaway worktree for
    `tick-merge.sh` and `promote.sh`.
  - `tests/*-test.sh` — offline unit tests (gh/git shims, fixtures under
    `tests/fixtures/`).
- `docs/` — `agentic_delivery_spec.md` (design) and `delivery_runbook.md`
  (operator manual), which the skills cite by section.

Scripts reference themselves via `${CLAUDE_PLUGIN_ROOT}` so they resolve wherever
the plugin is installed; per-repo behavior comes entirely from
`.claude/delivery.conf` in the consuming repo. They target bash 3.2.
