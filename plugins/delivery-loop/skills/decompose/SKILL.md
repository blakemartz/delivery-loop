---
name: decompose
description: Destructure a repo's specs into a dependency-ordered backlog of epics and tasks, written as a plan file and applied to the work graph. Dry-run by default (plan file, table, and Mermaid graph); pass --create only after a human approves the printed backlog. Optional scope arg, e.g. "/decompose backend api loop".
---

# decompose — specs → plan file → backlog

You are the **decomposer** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.2, §7 method). Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`. Take `SPEC_SOURCES` (the files you decompose), `STYLEGUIDES_DIR` (conventions), `MODULES` (the allowed modules, plus `infra` and `docs`), `GATE_CMD` (the acceptance-criteria gate), `BASE_BRANCH`, `PLANS_DIR`, and `GRAPH_BACKEND` from `bash "$S/delivery-config.sh"` (the resolved `KEY=value` lines: defaults, `.claude/delivery.conf`, then environment) — never by reading the conf file yourself.

The backlog is a **plan file**, `PLANS_DIR/<plan>.plan.json`. `plan.sh` lints, renders, and applies it. Every graph read goes through `graph.sh`, every PR through `forge.sh`. You never create nodes one by one and never call the tracker's or forge's CLI or API directly. The script headers under `${CLAUDE_PLUGIN_ROOT}/scripts/` are the authoritative contract for every flag, output, and exit code below.

## Inputs

1. **The spec sources** — every file matched by `SPEC_SOURCES`. These are the primary source of tasks and their acceptance criteria. If a spec ends with a "decompose-ready cutline" (a dependency-ordered task list with module / size / command-checkable seams), translate it — don't re-derive it.
2. **The conventions** in `STYLEGUIDES_DIR` — read the ones relevant to what you're decomposing; tasks must fit them. If the directory is missing or holds no ratified guides, say so and suggest `/delivery-loop:author-styleguides` — then proceed against the stack's idiomatic best practice (spec §2.1).
3. **The existing backlog:** `bash "$S/graph.sh" list` (every node, open and closed: `id`, `kind`, `title`, `status`, `plan_ref`, …) and the plan files already in `PLANS_DIR` — never propose a duplicate of an open or closed task.
4. Any product/context docs the specs reference — consult for a task's **Context** section (the *why*); **never** source acceptance criteria from prose (Hard rule 1).
5. Optional scope argument narrowing what to decompose (default: the next unstarted slice of work in the specs).

## Method

- Epics ≈ major spec sections or modules. Tasks are children of exactly one epic.
- Dependency edges follow the natural build order: scaffold → models → repositories → services → endpoints → wiring/integration (adapt to the stack). Every edge names its **seam** in `via` — the artifact the dependent task consumes (`"lib/store.jq read_store"`).
- Every task gets: an id, title, exactly one module, size, a Context, command-shaped criteria, and its deps.
- **A task that introduces a tool, test suite, or build step must include extending the gate (`GATE_CMD`) to cover it as one of its acceptance criteria.** This is how the gate self-maintains — it grows with the repo instead of going stale.

## Hard rules (violating any of these means your backlog is wrong)

1. **Every acceptance criterion is a command that must exit 0, or a checkable artifact.** Good: `` `<GATE_CMD>` passes ``, `` `test -f path/to/file` ``, `` `<project test command>` passes ``. Bad: "code is clean", "works correctly", "follows best practices".
2. **Nothing bigger than size M.** If a piece of work doesn't comfortably fit one agent context, split it. Size `L` may only appear as an explicit "split me later" placeholder (lint warns; it is never claimed). Best-practice belongs in the *design* (the Context), never encoded as a workaround in the criteria (spec §2.1).
3. **Exactly one module per task** — the module is the concurrency unit. Use a value from `MODULES` (or `infra` / `docs`).
4. Every task's `context` references the spec sections it derives from.

## The plan file

One JSON object: `schema: 1`; `plan` (the plan id, unique across `PLANS_DIR`); `spec` (the spec paths); `target_branch` (omit it to target `BASE_BRANCH`) and, for a release or feature branch, `promote_to` (the branch a promotion PR merges it into); `epics: [{id, title, goal, spec_refs}]`; `tasks: [{id, epic, title, module, size, deps: [{id, via}], context, criteria: [..], scope: [paths]}]`. Ids are lowercase slugs (`a-z0-9` and single `-`). A dep `id` names a task of this plan or an existing node (`"#42"` on the github backend, a node id on local). Lint refuses any plan text carrying a line a backend would read back as a marker (`Delivery-Plan:`, `Depends-on: #N`, …), so never write those lines yourself: `plan.sh apply` derives them.

## Output

**Dry-run (default):**
1. Write `PLANS_DIR/<plan>.plan.json` to the working tree. Do not commit it.
2. `bash "$S/plan.sh" lint <file>`. Exit 0 prints `… ok (<n> epics, <m> tasks)`; warnings (a size-`L` placeholder) go to stderr. Exit 1 lists every error on stderr: fix the file and re-lint until it passes. Never print a backlog that fails lint.
3. `bash "$S/plan.sh" render <file>` — a Mermaid `flowchart TD`: epic subgraphs, one node per task labeled `id: title [module/size]`, one edge per dep labeled with its `via`, and the promote node when `promote_to` is set.
4. Print the backlog as a markdown table — `id | title | module | size | deps | acceptance criteria` — grouped by epic, then the Mermaid graph in a `mermaid` code block, and the plan file's path. STOP. Do not commit or create anything. Ask the human to review the graph itself.

**`--create` (only after human approval of the printed backlog):**
1. On `GRAPH_BACKEND=github`, every module the plan uses needs its `module:<m>` label: `/delivery-loop:init` creates one for `infra`, `docs`, and every `MODULES` entry, so re-run it after adding a module to `MODULES`. The local backend needs no labels.
2. Re-run `bash "$S/plan.sh" lint <file>`; it must exit 0.
3. **Commit the plan file** to the current branch and push it. If the repo only accepts changes by PR, commit it on a branch instead, push, and open a PR into the current branch: `bash "$S/forge.sh" pr-create --head <branch> --base <current branch> --title "Plan <plan>" --body-file "$TMPDIR/plan-pr.md"` (stdout `{number, url}`). A human merges it. On this route, STOP until the plan PR is merged, then pull the current branch and run step 4 from the merged commit. `plan.sh apply` does not wait for the PR or check that the plan file is committed. Never bypass hooks (`--no-verify`).
4. `bash "$S/plan.sh" apply <file>` from that commit. Idempotent: it lints again, creates only what is missing (epics, then tasks in dependency order, then the plan's promote node), and runs `graph.sh reconcile --fix`. Stdout: one `created: <kind> <plan id> <node id>` or `exists: <kind> <plan id> <node id>` line per node, reconcile's `fix:` lines, then `…: applied (<c> created, <e> existing, <d> drift)`. If `target_branch` is missing on origin, apply first prints `target branch <T> is missing on origin; creating it from origin/<promote_to or BASE_BRANCH>:` and the exact `git push`, then runs it.
   - `drift: <id> <field>` on stderr: an existing node differs from the plan. It is reported, never overwritten: report it to the human.
   - Exit 1: read the `plan.sh: <file>: error: apply: …` line on stderr. Apply stops at the failing step, and whatever it created before that step stays. A re-run finds those nodes by `plan_ref`.
     - Lint errors, or `apply refused (nothing written)`: nothing was written. Fix the plan file and re-run apply.
     - `every node exists (<c> created), but graph.sh reconcile --fix …`: every node is in the graph; only the final reconcile failed. Do not edit the plan. Once the cause is fixed (for a busy local lock, the stderr says when a re-run succeeds), re-run `bash "$S/plan.sh" apply <file>` or `bash "$S/graph.sh" reconcile --fix`.
     - `graph.sh create failed for …`, a failed or unconfirmed target-branch `git push`, or an unreadable origin: the plan is not at fault. Fix the cause the stderr names, then re-run apply.
5. `bash "$S/graph.sh" ready` — print the created node ids (from the `created:` lines) and the resulting ready set.

## Exit condition

Dry-run: plan file written (uncommitted) and linted, backlog table + Mermaid graph printed, awaiting human approval. Create: plan file committed, `plan.sh apply` exited 0, created node ids and the ready set printed.
