---
name: next-task
description: Claim the next ready task off the work graph (or a specific one, e.g. "/next-task 42" — a node id), implement it in an isolated worktree to its acceptance criteria, pass the gate, and open a PR. The implementer role of the agentic delivery loop.
---

# next-task — claim → implement → gate → PR

You are the **implementer** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.3, §6). Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`. Take `GATE_CMD`, `STYLEGUIDES_DIR`, `GRAPH_BACKEND`, and `NOTIFY_ESCALATE_CMD` from `bash "$S/delivery-config.sh"` (the resolved `KEY=value` lines: defaults, `.claude/delivery.conf`, then environment) — never by reading the conf file yourself.

Every graph read or write goes through `graph.sh`, every PR operation through `forge.sh`. Never call the tracker's or forge's CLI or API directly. The script headers under `${CLAUDE_PLUGIN_ROOT}/scripts/` are the authoritative contract for every flag, output, and exit code below.

**You never write a free-text note on the node.** The reviewer treats every node comment that is not a script-written marker as the orchestrator's or a human's contract (`review-task` step 2), so implementer reasoning must not land there: your findings go in the PR body (step 9), and a blocker's reason goes in the release reason (**If blocked**).

**Private scratch.** Before anything else, `export TMPDIR=$(mktemp -d)` and keep every scratch file (PR body, script stderr, gate log) under it. Never write to a shared fixed path: other agents run beside you.

## Protocol (in order; scripts own the mechanics — never re-derive them)

1. **Pick.** `bash "$S/graph.sh" ready` — one JSON line per ready node, best first: `{id, title, unblocks, size, started, epic, module, target_branch}`. Take the first line, or the node id given as an argument if it is in the ready set. Empty ready set → report and stop. **Module cap:** skip a node if another node with the same `module` and `target_branch` is `claimed` (`bash "$S/graph.sh" list`), or is linked (`task_id`) to an open agent PR (`bash "$S/forge.sh" pr-list --state open`, entries with `agent: true`). A node with no module (`module: null`) is exempt: it never waits and never blocks another (GC18).
2. **Claim — BEFORE any worktree.** `actor=agent-$(date +%s)`, then `bash "$S/graph.sh" claim <id> "$actor"`. Exit 0 = you own it. Exit 1 = lost the race or not claimable; exit 75 = backend busy: report and stop. Never work on a node claimed by anyone else.
3. **Worktree.** `path=$(bash "$S/task-worktree.sh" <id>)` — stdout is only the path; it forks from `origin/<target_branch>`. Exit 1 (unknown node, target branch missing on origin) → **If blocked**. Do ALL work inside `$path`. Never touch the main checkout.
4. **Read.** `bash "$S/graph.sh" show <id> --format md` — the Context and Acceptance criteria are the contract. The orchestrator's and humans' notes on the node are part of it too: `bash "$S/graph.sh" show <id> --events` is the only way to read them; which events count, and what each backend returns, is defined in `review-task` step 2. Exit 1 = the read failed, and exit 3 = the comment thread reached `LIST_LIMIT` (stderr `… >= LIST_LIMIT (<n>); refusing to truncate`); either way nothing was printed. Retry an exit 1 once; then work from the body alone and say so in the PR body's **Implementer findings**, naming the exit (for 3, that raising `LIST_LIMIT` would let the notes be read). On the local backend, if the window came back full (10 events), say there that older notes were not visible. Read the relevant styleguide in `STYLEGUIDES_DIR` before writing code. Match existing patterns.
5. **Implement** to the acceptance criteria, and implement it *well*: among the solutions that satisfy the criteria, pick the best-practice, idiomatic one for the stack (spec §2.1). Nothing more — scope creep in an agent loop is a merge-conflict machine. If satisfying a criterion seems to *require* a non-best-practice solution (a workaround, an anti-pattern), don't silently ship it — record it for the PR body's **Implementer findings** section (step 9) and, if it blocks a clean solution, escalate per **If blocked**. **Keep the gate honest:** if your change introduces a linter, test suite, or build step, extend the gate (`GATE_CMD`) to cover it — this is how "correct" grows with the repo.
6. **Verify.** Run EVERY acceptance criterion literally, plus `GATE_CMD`, from `$path`. Send the gate's output to a log unique to this run (e.g. `"$TMPDIR/gate-<id>-$(date +%s).log"`), never a shared path. All must pass. Capture the passing output lines — they're your PR evidence. If you start a background process, capture its PID (`$!`) and kill only that PID; never kill by pattern (`pkill -f`, `killall`).
7. **Re-verify claim.** `bash "$S/graph.sh" show <id>` — `.status` must still be `claimed` and `.claim.actor` must be your `$actor`. If not, stop and report (someone reclaimed it).
8. **Commit & push** from `$path`. If the repo installs git hooks, they fire — **never bypass the gate** (`--no-verify`). If a hook fails, fix the cause. If `origin/<target_branch>` moved, catch up by **merging** it into your branch (`git fetch origin <target_branch> && git merge origin/<target_branch>`), never by rebasing; re-run step 6 after a merge that changed anything. Push with a plain `git push -u origin HEAD`. **Never force-push.**
9. **PR.** Write the body to `"$TMPDIR/pr-body.md"`, following the repo's PR template if present: summary, acceptance-criteria checklist **with evidence per criterion**, gate status, an **Implementer findings** section (step 5's findings, or "none"), `Agent-authored (model: <your model>)`. On `GRAPH_BACKEND=github` its first line is `Closes #<id>`. On any other backend, include the full task contract (the step 4 markdown): the PR is the only place a reviewer on the forge sees it. End the body with the trailer line `Delivery-Task: <id>` at column 0, on every backend — it is how the PR links to its node. Then:
   `bash "$S/forge.sh" pr-create --head <your branch> --base <target_branch> --title "<task title> (#<id>)" --body-file "$TMPDIR/pr-body.md" --label agent-authored`
   `<target_branch>` is the node's (`graph.sh show <id>` → `.target_branch`), never the repo default. Stdout `{number, url}`.
   - **Exit 1 naming a PR URL** (the github adapter's `… opened <url> but failed to apply its labels` message) = the PR exists without the `agent-authored` label. Recover; do not stop, and never open a duplicate. `bash "$S/forge.sh" pr-find --head <your branch>` gives that PR (its `number` and `url` must match the printed URL). Carry on with step 10, then escalate the missing label, since no seam adds one and the loop ignores an unlabelled PR (`agent: false`). Write "PR #<n> is missing the `agent-authored` label: add it, then clear needs-human" to `"$TMPDIR/label.md"`, then `bash "$S/forge.sh" pr-comment <n> --body-file "$TMPDIR/label.md"` and `bash "$S/graph.sh" flag <id> needs-human on`. Run `NOTIFY_ESCALATE_CMD` if it is set. Report the PR and the escalation.
   - **Any other exit 1** = no PR created: report and stop.
10. **Status.** `bash "$S/graph.sh" transition <id> in-review`. Exit 2 = the move is illegal from the node's current status: report it (reconcile repairs drift from an open agent PR).
11. Report the PR number and URL.

## If blocked

Cannot satisfy a criterion (contradictory spec, missing dependency, environment problem): do NOT push partial work as if complete. Instead:

1. `bash "$S/graph.sh" flag <id> needs-human on`.
2. `bash "$S/graph.sh" release <id> "blocked: <exactly what you found and why it blocks you, one line>"`. This clears your claim and records the reason as a script-written release (local: a `release` event; github: a `CLAIM-WITHDRAWN … (released: …)` comment), never a free-text note. `needs_human` stays set, so no agent re-claims the node until a human clears the flag.
3. Run `NOTIFY_ESCALATE_CMD` if it is set, so the operator hears a task needs them. Stop.

**Encode the lesson:** if the blocker was caused by the harness (ambiguous criteria, template gap, missing gate check), also file a `module:infra` task describing the fix (`graph.sh create`).

## Exit condition

PR number + URL printed, or a clear report of why you stopped (claim lost / queue empty / needs-human filed).
