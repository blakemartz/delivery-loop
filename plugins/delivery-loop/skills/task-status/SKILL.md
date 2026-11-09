---
name: task-status
description: Render the delivery board — needs-human / approved / changes-requested / in-review / claimed / ready / blocked — from the work graph and the forge's PRs. Pass --graph to also print the graph as Mermaid, --reclaim to reconcile the board first (repair statuses, release stale agent claims).
---

# task-status — board overview (+ reclamation)

You are the board renderer (and with `--reclaim`, the reclamation actuator) from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §5). Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`.

Every graph read or write goes through `graph.sh`, every PR read through `forge.sh`. Never call the tracker's or forge's CLI or API directly. The script headers under `${CLAUDE_PLUGIN_ROOT}/scripts/` are the authoritative contract for every flag, output, and exit code below. Keep each script's stderr in a scratch file under a private `TMPDIR` (`export TMPDIR=$(mktemp -d)`), never interleaved with the stdout you parse.

## Protocol

1. **`--reclaim` only:** `bash "$S/graph.sh" reconcile --fix`. It repairs the status cache from ground truth: a merged agent PR's task goes `done`, a fully delivered epic goes `done`, a node with an open agent PR goes `in-review`, `blocked` ↔ `ready` follows the deps, an agent claim idle >4h with no open PR is released (`RECLAIMED`), and a human claim idle >72h is pinged once (never released). Stdout is one `fix: <op> <id> <from> -> <to>: <reason>` line per applied record; `warn: …` lines (cycles, unknown or cancelled deps) go to stderr. Exit 4 (board changed) or 75 (backend busy): re-run, up to 3 passes in all. Any other nonzero exit: report it, then render the board unreconciled and say so. Report every `fix:` and `warn:` line.
2. **Gather the board** (read-only):
   - `bash "$S/graph.sh" list` — every node as one JSON array: `id`, `kind`, `title`, `status`, `needs_human`, `claim` (`{actor, run, at, by}` or null), `deps` (`[{id, via}]`), `epic`, `module`, `size`, `target_branch`, `updated_at`, …
   - `bash "$S/forge.sh" pr-list --state open` — the open PRs as one JSON array: `number`, `url`, `task_id`, `agent`, `base`, `checks`, `mergeable`, `patch_iteration`, `reviewed_at_head`, `labels`.
   - `bash "$S/graph.sh" ready` — the ready set, best first, one JSON line each.
   - `plan=$(bash "$S/tick-plan.sh")` — it reads the same state and changes nothing: `actions` is what one serial `delivery-tick` would do now, and `waiting` says what the board waits on.
   Exit 3 from `list` or `pr-list` = the list reached `LIST_LIMIT` (the stderr says so; raise it). Any nonzero exit: report it and stop — never render a partial board.
3. **Render** one compact table per bucket, in this order (most actionable first). Join a PR to its node by `task_id`. Kinds `task` and `promote` are the board; epics appear only as the `epic` column.
   - **needs-human** — every open node with `needs_human: true`: id, title, and what's stuck (the newest `comment` event from `bash "$S/graph.sh" show <id> --events`; if that read exits nonzero, say "notes unreadable").
   - **approved, awaiting human merge** — status `approved`: node, PR, `checks`, `mergeable`. A promotion PR (kind `promote`) is always a human's merge.
   - **changes-requested** — node, PR, `Patch iteration: <patch_iteration>/3`.
   - **in-review** — node, PR, `checks`, and whether a verdict exists at the current head (`reviewed_at_head`).
   - **claimed** — node, `claim.actor`, `claim.by` (human or agent), idle time since `updated_at`.
   - **ready** — `graph.sh ready`'s output, in order.
   - **blocked** — node, and its deps whose node is not `done`.
4. **`--graph` only:** print the live graph as a Mermaid `flowchart TD` in a `mermaid` code block, from the `graph.sh list` data: one subgraph per epic, one node per open task or promote node labeled `id: title [status]`, and one edge per dep, dep → dependent, labeled with its `via` when set. Quote every label, and replace each `"` in a label with `#quot;`, each `[` / `]` with `#91;` / `#93;`, each `|` with `#124;`, and each newline with a space, so a title can never break the graph. For a plan's own shape, `bash "$S/plan.sh" render <plan file>` prints it from the plan file.
5. **End with a one-line "next action"**: the first of `plan`'s `actions` (what a single `delivery-tick` would do right now), or, when `actions` is empty, its `waiting` lines.

Read-only apart from `--reclaim`. Never claim, review, transition, or edit anything else here.
