---
name: decompose
description: Destructure a repo's specs into a dependency-ordered backlog of epics and tasks as GitHub Issues. Dry-run by default; pass --create only after a human approves the printed backlog. Optional scope arg, e.g. "/decompose backend api loop".
---

# decompose — specs → backlog

You are the **decomposer** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.2, §7 method).

**Config** — read `.claude/delivery.conf` at the repo root first (defaults in parens): `SPEC_SOURCES` (`docs/*_spec.md`) — the files you decompose; `STYLEGUIDES_DIR` (`styleguides/`) — conventions; `MODULES` — the allowed `module:` set; `GATE_CMD` (`bash scripts/check.sh`) — the acceptance-criteria gate.

## Inputs

1. **The spec sources** — every file matched by `SPEC_SOURCES`. These are the primary source of tasks and their acceptance criteria. If a spec ends with a "decompose-ready cutline" (a dependency-ordered task list with module / size / command-checkable seams), translate it — don't re-derive it.
2. **The conventions** in `STYLEGUIDES_DIR` — read the ones relevant to what you're decomposing; tasks must fit them. If the directory is missing or holds no ratified guides, say so and suggest `/delivery-loop:author-styleguides` — then proceed against the stack's idiomatic best practice (spec §2.1).
3. **The existing backlog:** `gh issue list --label task --state all --limit 500 --json number,title,labels` — never propose a duplicate of an open or closed task.
4. Any product/context docs the specs reference — consult for a task's **Context** section (the *why*); **never** source acceptance criteria from prose (Hard rule 1).
5. Optional scope argument narrowing what to decompose (default: the next unstarted slice of work in the specs).

## Method

- Epics ≈ major spec sections or modules. Tasks are children of exactly one epic.
- Dependency edges follow the natural build order: scaffold → models → repositories → services → endpoints → wiring/integration (adapt to the stack).
- Every task gets: title, exactly one module, size, command-shaped acceptance criteria, and its `Depends-on:` edges.
- **A task that introduces a tool, test suite, or build step must include extending the gate (`GATE_CMD` / `scripts/check.sh`) to cover it as one of its acceptance criteria.** This is how the gate self-maintains — it grows with the repo instead of going stale.

## Hard rules (violating any of these means your backlog is wrong)

1. **Every acceptance criterion is a command that must exit 0, or a checkable artifact.** Good: `` `<GATE_CMD>` passes ``, `` `test -f path/to/file` ``, `` `<project test command>` passes ``. Bad: "code is clean", "works correctly", "follows best practices".
2. **Nothing bigger than size:M.** If a piece of work doesn't comfortably fit one agent context, split it. `size:L` may only appear as an explicit "split me later" placeholder, clearly marked. Best-practice belongs in the *design* (the Context section), never encoded as a workaround in the criteria (spec §2.1).
3. **Exactly one `module:` label per task** — the module is the concurrency unit. Use a value from `MODULES` (or `infra` / `docs`).
4. Every task body must include a Context section referencing the spec sections it derives from.

## Output

**Dry-run (default):** print the proposed backlog as a markdown table — `title | module | size | depends-on | acceptance criteria` — grouped by epic, and STOP. Do not create anything. Ask the human to review.

**`--create` (only after human approval of the printed backlog):**
1. Ensure every `module:` label you use exists (run `/delivery-loop:init <modules>` or `gh label create module:<m>` first).
2. Create epics first: `gh issue create --title ... --label epic --body ...` (goal, spec references). Record their numbers.
3. Create tasks: `gh issue create --title ... --label "task,module:<m>,size:<s>,status:blocked,agent-authored" --body ...` where the body contains Context, an Acceptance-criteria checklist, a `Depends-on: #N #M` line using the real issue numbers created earlier (dependency-order the creation so numbers exist before they're referenced), and a `Part of epic #E` line so the epic auto-closes when its children do.
4. Update each epic body's task-list with the child issue numbers.
5. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh" --fix` to promote dependency-free tasks to `status:ready`.
6. Print the created issue numbers and the resulting ready set.

## Exit condition

Dry-run: backlog table printed, awaiting human approval. Create: issues exist, ready set printed.
