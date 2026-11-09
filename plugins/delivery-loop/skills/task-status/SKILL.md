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
   - `bash "$S/graph.sh" list > "$TMPDIR/nodes.json"` — every node as one JSON array: `id`, `kind`, `title`, `status`, `needs_human`, `claim` (`{actor, run, at, by}` or null), `deps` (`[{id, via}]`), `epic`, `module`, `size`, `target_branch`, `updated_at`, …
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
4. **`--graph` only:** print the live graph as Mermaid in a `mermaid` code block: the stdout of exactly this command, run on the saved `graph.sh list` output. Never hand-write the chart or re-derive its escaping.
   ```bash
   jq -r -L "$S/lib" '
     include "plan-render";
     def mid($p): $p + gsub("-"; "_");
     def caption: ("\(.id): \(.title)" | mermaid_text) + " [\(.status)]";
     INDEX(.id) as $by
     | map(select((.kind == "task" or .kind == "promote")
                  and (.status | IN("done", "cancelled") | not))) as $open
     | ($open | map(.epic | select(. != null and $by[.] != null)) | unique) as $subs
     | ($open | map(.id)) as $ids
     | def ref: if IN($ids[]) then mid("t_") elif IN($subs[]) then mid("e_") else mid("n_") end;
     "flowchart TD",
     ( $subs[] as $e
       | "  subgraph \($e | mid("e_"))[\"\($by[$e] | caption)\"]",
         ( $open[] | select(.epic == $e) | "    \(.id | mid("t_"))[\"\(caption)\"]" ),
         "  end" ),
     ( $open[] | select(.epic == null or $by[.epic] == null) | "  \(.id | mid("t_"))[\"\(caption)\"]" ),
     ( [$open[].deps[].id | select(IN($ids[], $subs[]) | not)] | unique[]
       | "  \(mid("n_"))[\"\(if $by[.] then $by[.] | caption else "\(.): not in the graph" | mermaid_text end)\"]" ),
     ( $open[] | (.id | mid("t_")) as $to | .deps[]
       | "  \(.id | ref) -->\(if .via then "|\"\(.via | mermaid_text)\"|" else "" end) \($to)" )
   ' "$TMPDIR/nodes.json"
   ```
   Every label goes through `lib/plan-render.jq`'s `mermaid_text`, the tested rule (GC37). Node ids take plan-render's role prefixes, with `-` mapped to `_`, so ids such as `end` or `graph` never reach id position: `t_` for each open task or promote node, `e_` for each epic subgraph, `n_` for each other node. The chart draws:
   - one subgraph per epic that holds at least one open task or promote node, labeled `id: title [status]`;
   - each open task or promote node (status other than `done` or `cancelled`), labeled `id: title [status]`, inside its epic's subgraph, or at top level when it has no epic;
   - each dep target that is not drawn above (a done or cancelled node, an epic with no open member, an external issue) once, as a plain top-level `n_` node with the same label. A dep id missing from `graph.sh list` is drawn as `id: not in the graph`. No edge ever names an undeclared node;
   - one edge per dep of an open node, dep → dependent, labeled with its `via` when set. A dep on a drawn epic links from its subgraph.
   If `jq` exits nonzero, report its stderr and print no chart. For a plan's own shape, `bash "$S/plan.sh" render <plan file>` prints it from the plan file.
5. **End with a one-line "next action"**: the first of `plan`'s `actions` (what a single `delivery-tick` would do right now), or, when `actions` is empty, its `waiting` lines.

Read-only apart from `--reclaim`. Never claim, review, transition, or edit anything else here.
