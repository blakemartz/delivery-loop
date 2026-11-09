# Agentic Delivery Spec (delivery-loop) v0.2

## 1. Purpose

This document defines the agentic delivery system implemented by the
**delivery-loop** plugin.

The specs in your repository (whatever `SPEC_SOURCES` in `.claude/delivery.conf`
points at — architecture, domain model, feature specs) are the product
blueprint. This spec defines the machinery that converts that blueprint into
merged code, task by task, using coordinated agent loops with humans as the
merge authority.

The system must support:

* Decomposing specs into a dependency-ordered task backlog
* A shared task queue that agents and humans both pull from
* Isolated parallel implementation via git worktrees
* Deterministic verification gates on every change
* Independent adversarial review of every change
* Bounded patch iteration with human escalation
* Human approval of every merge
* Full provenance of who (or what) produced each change

Sections §1–§14 are the loop itself. §15–§18 describe the seams added in v0.2:
graph backends (§15), forges (§16), branch flow and promotion (§17), and plan
files (§18).

## 2. Delivery Thesis

The **work graph** is the single source of truth for work state. It lives in a
**graph backend** behind one script, `graph.sh` (§15): GitHub Issues
(`GRAPH_BACKEND=github`, the default) or JSON files on the machine
(`GRAPH_BACKEND=local`, no issue tracker). PRs live on a **forge** behind
`forge.sh` (§16): GitHub, GitLab, or Gitea/Forgejo (`FORGE`). Git worktrees
isolate parallel implementers. Deterministic scripts own every mechanic —
computing the ready set, claiming, reconciling, planning the tick, merging,
promoting, worktree setup — so agents never re-reason about them, and a single
per-repo gate command owns verification. Model reasoning owns only judgment:
decomposition, implementation, review, and patching. A human owns every merge
(unless auto-merge is opted into, §8.2), and always owns promotion merges (§17).

Corollaries:

* Any state that matters survives the death of every agent session, because it lives in the graph backend and on the forge — never in an agent's context.
* Any actor — agent or human — can pick up any ready task through the same protocol.
* The gate is one command, called identically by git hooks, CI, and agents, so it cannot drift.
* Policy is computed once. The ready predicate, legal transitions, reconciliation and the tick's action plan are pure `jq` over one normalized node shape (`scripts/lib/*.jq`). Backends store; they never decide. So every backend gets the same behavior by construction.

## 2.1 Engineering Principles

These bind every role — decomposer, implementer, reviewer, patcher — not just the loop mechanics:

* **Pursue best-practice solutions.** When more than one approach satisfies the acceptance criteria, choose the idiomatic, standard one for the language and framework over the cleverest or most expedient. Match the styleguides and existing patterns.
* **Solve each problem in its own layer.** Do not distort runtime architecture to work around a process or tooling problem — a merge conflict, a CI quirk, a claim race. Fix those in the layer where they belong (git, hooks, the harness). Load-bearing example: benign "both sides appended a line" merge conflicts are solved by merge automation and a `.gitattributes` merge driver (§8.1), not by reshaping how the application wires itself together.
* **Best practice is a quality bar, not an acceptance criterion.** Acceptance criteria stay concrete and command-checkable (§7; decompose Hard Rule 1) — "follows best practices" is never itself a criterion. The bar is upheld by implementers choosing the idiomatic solution and reviewers flagging non-idiomatic ones, even when every criterion passes.
* **Flag, don't silently comply.** If a task's prescribed approach or criteria force a non-best-practice solution (a workaround, an anti-pattern), raise it — note it in the PR's implementer findings, or escalate `needs-human` — rather than ship the anti-pattern to satisfy the letter of the task.

## 2.2 Per-repo configuration

Everything project-specific lives in one file, `.claude/delivery.conf` at the
repo root (scaffolded by `delivery-init.sh`, resolved by `scripts/lib/config.sh`:
built-in defaults < the file < environment variables). The engine and skills
read it; nothing else needs editing to adopt the loop. `delivery-config.sh`
prints the resolved `KEY=value` lines; skills read config through it, never by
parsing the file.

| Key | Default | Role |
|---|---|---|
| `GATE_CMD` | `bash scripts/check.sh` | THE gate (§11) — one command that exits 0 iff the repo is correct. |
| `BASE_BRANCH` | `main` | Default `target_branch` of every node (§17): worktrees fork from it and PRs target it unless a plan names another branch. |
| `WORKTREE_SETUP_CMD` | (empty) | Command run once in a fresh worktree (install deps). `init` may seed it. |
| `SPEC_SOURCES` | `docs/*_spec.md` | Files the decomposer reads (§3.2). |
| `STYLEGUIDES_DIR` | `styleguides/` | Coding conventions implementers/reviewers consult. |
| `MODULES` | (empty) | Allowed `module:` values — the concurrency unit (§8). `infra` and `docs` are always allowed. |
| `NOTIFY_APPROVE_CMD` / `NOTIFY_ESCALATE_CMD` | (empty) | Optional hooks on approval / escalation. |
| `GRAPH_BACKEND` | `github` | Where the task graph lives: `github` \| `local` (§15). `github` requires `FORGE=github`. |
| `STATE_DIR` | (empty → `<git-common-dir>/delivery`) | Local backend store, shared by every worktree of the clone. |
| `LOCK_STALE_SECONDS` | `120` | Local backend: age after which a dead holder's lock may be broken. |
| `LIST_LIMIT` | `5000` | Fetch ceiling for graph and forge lists; reaching it is an error (exit 3), never a silent truncation. |
| `FORGE` | `github` | Where PRs live: `github` \| `gitlab` \| `gitea` (§16). |
| `FORGE_URL` | (derived from origin) | Forge API base host, e.g. `https://gitlab.example.com`. |
| `FORGE_REPO` | (derived from origin) | `owner/repo`, or GitLab `group/subgroup/project`. |
| `PLANS_DIR` | `docs/plans/` | Where plan files live (§18). |
| `TASK_MERGE_METHOD` | `squash` | Merge method for task PRs. |
| `PROMOTE_MERGE_METHOD` | `merge` | Merge method for promotion PRs (§17). |
| `PROMOTE_GATE_CMD` | (empty → `GATE_CMD`) | Gate run on the target branch before a promotion PR. |

Environment only — never in `.claude/delivery.conf` (a checked-in file; values
set there are discarded): `GITLAB_TOKEN` / `GITEA_TOKEN` (forge auth),
`GH_REVIEW_TOKEN` / `GITLAB_REVIEW_TOKEN` / `GITEA_REVIEW_TOKEN` (optional
reviewer identity, §13.2), `LOCK_WAIT_SECONDS` (local lock wait, default 30).

`delivery-config.sh --check` validates the combination and exits 1 with one
`config: …` line per problem: an unknown `GRAPH_BACKEND` or `FORGE` value;
`GRAPH_BACKEND=github` with a non-github forge; a gitlab/gitea forge without its
token; and an unsupported jq (jq ≥ 1.7 is required, and exactly 1.8.2 is refused
because of upstream bug jqlang/jq#3597; a version string that does not parse as a
release is accepted). `graph.sh`, `forge.sh`, `tick-plan.sh`, `plan.sh`,
`promote.sh` and `tick-merge.sh` run the same check once at start-up, before any
I/O.

`delivery-init.sh` does more than scaffold the config: it picks or detects the
two seams (`GRAPH_BACKEND`, `FORGE`), scans the repo for linters,
type-checkers, and test frameworks and seeds a starter `scripts/check.sh` (the
file `GATE_CMD` points at by default) from what it finds — preferring the
repo's own declared commands. If it finds no tooling, the seeded gate *fails*
until a human defines the checks (an undefined gate must never report green).
On the local backend it creates the `STATE_DIR` store; on the github backend it
creates the label taxonomy. The `init` skill surfaces the seed for human review
and suggests a starter toolset when none is present.

## 3. Roles

### 3.1 Orchestrator

The loop driver. Typically a local Claude Code session running `/loop` against the `delivery-tick` skill. Each tick reconciles the graph, asks `tick-plan.sh` for the action plan, and executes it: deterministic merges and promotions first, then exactly one agent action (patch a rejected PR, rebase an approved-but-conflicting PR, review an unreviewed PR, or start the next ready task) — or, with `--parallel N`, one bounded batch of up to N independent agent actions the tick waits out (§6, §12).

The orchestrator never implements, reviews, or merges by judgment. It dispatches, and it decides nothing: the plan is computed by `lib/tick-plan.jq`, and the only merges are `tick-merge.sh`'s.

### 3.2 Decomposer

Reads the spec sources (`SPEC_SOURCES`) and the conventions (`STYLEGUIDES_DIR`), and writes a **plan file** (§18) of epics and tasks. Runs dry by default (lint + Mermaid render, nothing committed); creates nodes only after a human approves the proposed backlog, by committing the plan file and running `plan.sh apply`. For subsystems covered by a focused sub-spec, the sub-spec's decompose-ready cutline is the primary source (authored upstream by the spec author, §3.7) — translate it, don't re-derive it.

### 3.3 Implementer

Claims one ready task, works in a dedicated worktree, satisfies every acceptance criterion, passes the gate, opens a PR. One task, one branch, one PR.

### 3.4 Reviewer

A fresh agent with no access to the implementer's context. Inputs are only: the task's contract (the node body plus the orchestrator's and humans' notes on the node, never the implementer's), the PR diff, the styleguides, and two clean checkouts it builds itself — the PR head and the merged result (base + head). It **executes** every acceptance criterion on the head and runs the gate on both. Approves or requests changes, pinned to the head SHA it reviewed. Never reviews its own work — reviewer and implementer are always different agent instances.

### 3.5 Patcher

Responds to review findings or failing CI on an existing PR. Usually the implementer role resumed in the same worktree. Bounded to 3 iterations per PR (§9).

### 3.6 Human

Approves proposed backlogs, pins spec-level design decisions and nods on spec drafts before they become PRs, merges every PR (or opts into auto-merge, §8.2), always merges promotion PRs (§17), breaks ties, handles `needs-human` escalations, and may claim any task off the same queue on equal footing with agents.

### 3.7 Spec author

Upstream of the decomposer: turns a subsystem into a merged, decompose-ready sub-spec (`/delivery-loop:author-spec`). Collects operator pins before drafting, grounds every claim against the repo and primary sources, drafts to a house template, and lands the spec through a fresh-agent adversarial **docs review** (grounding, consistency, and buildability instead of executable criteria; verdict as a single comment-form review per round, `forge.sh pr-review <pr> comment --sha <head>`, whose body's first line is the plain-text `Docs-review verdict: APPROVE` or `Docs-review verdict: REQUEST_CHANGES` — the adapter adds the `## Adversarial review — verdict: COMMENT` heading and the `Reviewed-Head:` trailer, §10, §13.2, runbook §7). Docs-review fix rounds resume the *same* reviewer — its grounding context is the asset — a deliberate deviation from §3.4's fresh-reviewer rule, scoped to docs reviews only. Two human gates: the draft nod before any PR, and the `/decompose` backlog approval after merge. The spec PR's merge follows the same authority model as every other PR (§3.6, §8.2): human by default, agent only under the operator's explicit standing authorization, and then only after gating the merged result. The spec author never implements tasks — it hands the merged cutline to the decomposer and stops. Sequencing is deliberate: decomposition always runs against the **merged** spec, because review rounds change cutlines.

## 4. Task Model

A task is a **node** of kind `task` in the work graph (§15). On the github
backend it is a GitHub Issue with the `task` label; on the local backend it is a
JSON record in `STATE_DIR`. Every backend emits the same normalized node shape,
validated on every read (`lib/node.jq` `validate_node`).

Required fields (written by `plan.sh apply` from the plan file, §18; on github
also encoded in the issue template for hand-filed tasks):

* Context — what and why, with spec references
* Acceptance criteria — see determinism rule below
* Depends on — blocking edges, each naming the seam it consumes (`via`). On github these are native blocked-by links plus legacy `Depends-on: #N #M` body lines (a line counts only when the keyword starts it); on local, the node's `deps`.
* Module — exactly one module (`module:<name>` label on github)
* Size — `S` or `M` (`L` exists only as a marker meaning "split me; not claimable")
* Target branch — the branch its PR merges into (§17); defaults to `BASE_BRANCH`

Rules:

* **Determinism rule.** Every acceptance criterion is a command that must exit 0, or a checkable artifact ("`<GATE_CMD>` passes", "`test -d src/parser`", "`curl -s localhost:PORT/health` returns 200"). Never "works well" or "is clean".
* **Sizing rule.** Every task must fit comfortably in one agent context. `M` is the maximum claimable size.
* **One module per task.** The module is the concurrency unit (§8).

### 4.1 Worked criterion examples

The determinism rule in practice — criteria a reviewer can execute verbatim vs. criteria that cannot be enforced:

| Good (command-shaped) | Bad (unenforceable) | Why the good one wins |
|---|---|---|
| `<GATE_CMD>` passes | "code is clean and follows best practices" | The gate is executable; "clean" is a vibe. Best practice is a quality bar upheld in design and review, never a criterion (§2.1). |
| `<test runner> path/to/module_test` passes, including the golden cases from the spec | "the parser works correctly" | Golden-case tables pin behavior to specific inputs → expected outputs; "correctly" is undefined. |
| `test -f migrations/<name>` exists and `<migrate command>` exits 0 | "the database schema is updated" | A checkable artifact plus a command that must exit 0. |
| `curl -s -o /dev/null -w '%{http_code}' localhost:PORT/health` prints `200` | "the service runs reliably" | Observable behavior at a seam, not an aspiration. |

Design-shaped work (an algorithm, a wire format, a workflow) is specced **before** it is decomposed: the spec document supplies golden-case tables and concrete seams so that every derived task's criteria can be command-shaped. A task whose criteria cannot be made command-shaped is a signal that a spec is missing — write the spec; don't ship the mushy criterion.

An epic is a node of kind `epic` (the `epic` label on github): a goal, spec references, and its child tasks (on github: native sub-issues, the legacy `Part of epic #E` / `[Ee]pic #E` body convention, and the epic's own `- [ ] #N` checklist). Epics are trackers only — never claimed, never in the ready queue. Two more kinds exist: `promote` (one per plan with a `promote_to` branch, §17), and `external` — a non-delivery issue the graph references as a dep or an epic child. An external node is inert: never claimable, never started, takes no transition; as a dep it is satisfied only when its issue is closed as completed.

## 5. Task Lifecycle State Machine

A node has exactly one **status**: `blocked`, `ready`, `claimed`, `in-review`,
`changes-requested`, `approved`, `done`, or `cancelled`. On github, `done` /
`cancelled` come from the issue's state (closed as completed / closed as not
planned or duplicate) and the open statuses are `status:*` labels; on local they
are stored fields. `needs-human` is an orthogonal **flag**, not a status
(`graph.sh flag <id> needs-human on|off`; the `needs-human` label on github).

```
blocked ──deps done──▶ ready ──claim──▶ claimed
                                          │ PR opened
                                          ▼
           ┌───────────── in-review ◀─────┘
           │ review rejects     │ review approves
           ▼                    ▼
  changes-requested          approved ──PR merged into target_branch──▶ done
           │ patch pushed
           └──────────▶ in-review   (≤3 patch iterations, then needs-human)
```

The complete transition table (`lib/transitions.jq`; `graph.sh transition`
validates every move against it and exits 2 on an illegal one without writing,
and reconcile's own fix records are validated against it before being applied):

| From | To | Actor kind | When |
|---|---|---|---|
| blocked | ready | reconcile | every dep `done`, not `needs_human` |
| ready | blocked | reconcile | a dep is not `done` |
| ready | claimed | agent \| human \| promote | `claim` (promote only on `kind=="promote"` nodes) |
| claimed | ready | reconcile \| agent \| promote | stale reclaim; claimant releases (promote: red gate) |
| in-review \| changes-requested \| approved \| ready | ready | reconcile | stale agent claim, no open PR (the PR closed unmerged, or claim drift on a `ready` node): the reclaim clears the claim |
| claimed | in-review | agent \| reconcile \| promote | PR opened (reconcile: an open agent PR exists; promote: promotion PR opened) |
| ready \| blocked | in-review | reconcile | `task` / `promote` only. Status drift: an open agent PR linked to the node while the claim was cleared or the status relabelled |
| in-review | changes-requested | agent (reviewer) | verdict REQUEST_CHANGES |
| changes-requested | in-review | agent (patcher) | fixes pushed |
| in-review | approved | agent (reviewer) | verdict APPROVE |
| any open status | done | reconcile | an agent PR linked to the node merged into the node's `target_branch` |
| ready | done | reconcile | `epic` only: an open epic with ≥ 1 child, every child `done` or `cancelled` |
| claimed | done | promote | promote node whose target and promote-to branches have identical trees (§17) |
| in-review | done | reconcile | promotion PR merged (§17) |
| any open status | cancelled | human | `graph.sh transition <id> cancelled --human <name>`; any other actor gets exit 2 |
| any | needs-human flag | any actor | an impasse (`graph.sh flag <id> needs-human on`) |

An `external` node takes no transition: its status changes only when its issue
is closed or reopened outside the loop.

### 5.1 Ground-truth precedence

Stored status (labels, on github) is a derived cache, not ground truth. Precedence when they disagree:

closed issue (github) > forge PR merged > forge PR open > stored status.

`graph.sh reconcile --fix` (wrapped by `task-queue.sh --fix`) reconciles the
stored status to ground truth at the start of every orchestrator tick. It reads
every node plus the forge's open PRs and the PRs merged since the oldest open
node was created (`forge.sh pr-list`), computes fix records with
`lib/reconcile.jq`, and applies each through the backend as a compare-and-set
against the node as the plan saw it. Records cascade, so applying stops at the
first record not applied (exit 4: the board changed; re-run). The rules:

1. `blocked → ready` when every dep is `done` (never while `needs_human`); `ready → blocked` when a dep is not.
2. **Merged PR → done, on every backend and every target branch.** An agent PR linked to node X (§10 linkage), merged into X's `target_branch`, sets X to `done`. On github the backend closes the issue as completed with an `AUTO-CLOSE: PR #<pr>` comment — GitHub's closing keywords only act on PRs into the default branch. The rule acts once per (node, PR): a PR already applied (recorded by that marker, or GitHub's own closing-keyword close) is skipped, so a human reopen is never overridden by the same merge; a newer merged PR still closes it.
3. **Open PR → in-review.** An open agent PR linked to a `claimed` node, or to a `ready`/`blocked` task or promote node (status drift), sets it `in-review`. This is applied before the deps rules, so an open PR outranks them.
4. **Stale claims** (§5.2).
5. **Fully delivered epics.** An open epic is a tracker: once it has ≥ 1 child and every child is `done` or `cancelled`, it is set `done` (closed on github). The `≥ 1` guard keeps a freshly created epic whose tasks are not filed yet from closing itself vacuously.
6. **Warnings, never mutations**, on stderr: a dep that is cancelled or unknown, and one `cycle: <id> → … → <id>` per dependency cycle.

### 5.2 Claims: human vs agent, and staleness

* Agent claim = `graph.sh claim <id> <actor>` (wrapped by `claim-task.sh`, §7.2): a policy pre-check, then the backend's atomic test-and-set. On github the claim is an assignee + `status:claimed` + `claim:agent`; on local it is the node's `claim` field (`by: "agent"`).
* Human claim = self-assignment in the GitHub UI (no `claim:agent` label), or `graph.sh claim <id> --human <name>` on any backend (`by: "human"`). Scripts fix status up around it.
* Agents treat **any existing claim or assignee** as an absolute stop. Agents never touch a node claimed by someone else and never review, patch, or merge a PR without the `agent-authored` label: only agent PRs produce loop actions.
* Stale agent claim: an agent claim on an open node, no linked open PR, no activity for 4 hours, not `needs_human` → reclaimed (claim cleared, back to `ready`, a `RECLAIMED` note). This applies from every open status the claim can be left in (`claimed`, `in-review`, `changes-requested`, `approved` after the PR closed unmerged, and `ready` with claim drift).
* Stale human claim: flagged at 72 hours with exactly one `STALE-CLAIM-PING` note. **Never auto-reclaimed.** A human decides.

## 6. The Loop Protocol

One orchestrator tick (`delivery-tick`):

1. **Reconcile.** `graph.sh reconcile --fix` (§5.1). Exit 4 (board changed) or 75 (local backend busy) is re-run, up to 3 passes; any other failure stops the tick — never plan over a board that could not be reconciled.
2. **Plan.** `tick-plan.sh [--parallel N] [--auto-merge]` reads every node and the open PRs and prints `{mode, actions, board, waiting}` (`lib/tick-plan.jq`). It changes nothing. Its rules, in priority order, only ever act on open agent PRs linked to a node, and never on a `needs-human` node or PR (those become `waiting` lines):
   1. **merge** (only with `--auto-merge`) — an `approved` task whose PR is mergeable-clean, with checks `success` or `none`, based on the node's `target_branch`; at most one merge per task (the lowest PR number). Promotion PRs never merge.
   2. **patch** — a `changes-requested` task.
   3. **rebase** — an `approved` task whose PR conflicts, under the patch budget (§8.2).
   4. **review** — an `in-review` task with no verdict at the PR's current head.
   5. **promote** — a `ready` promote node (§17).
   6. **start** — the ready set (§7.1) in order, never a node that already has an open agent PR, filling `cap − in-flight` (serial: only the top ready task, cap 2), with at most one in-flight task per `(target_branch, module)` (§8).
3. **Execute the plan in order.** Every `merge` runs `tick-merge.sh <pr> <sha>`, one at a time (§8.2); every `promote` runs `promote.sh <id>` (§17). These are deterministic scripts and do not count against N. Then the agent actions (plus any `rebase` a refused merge printed) are truncated to `mode.n` and dispatched: `patch`/`rebase` → `patch-task`, `review` → a **fresh** `review-task` agent, `start` → `next-task`.
4. **Report** every action and outcome, every `fix:` line, the board counts, and every `waiting` line, ending with what the board waits on.

One state-advancing agent action per tick keeps `/loop` pacing meaningful: the loop self-paces against how fast the board actually changes. In parallel mode (`--parallel N`, §12) a tick instead dispatches up to N agent actions as one independent batch (each PR matches at most one rule by construction; one in-flight task per module per target branch) and awaits the whole batch before ending — a single bounded dispatch, so the pacing property is preserved. `tick-plan.sh` parses N: bare or not a whole number → 3; above 16 → 16; 1 or lower → serial.

The implementer's inner loop for one task:

claim (before any worktree) → worktree forked from `origin/<target_branch>` → read the contract (`graph.sh show <id> --format md` and the node's notes, `--events`) → implement to acceptance criteria (consulting the module's styleguide) → run every criterion + the gate (`GATE_CMD`) → commit (any pre-commit hooks fire) → if the target branch moved, **merge** it in (never rebase) → plain push (any pre-push gate fires; never force) → `forge.sh pr-create --base <target_branch> --label agent-authored` with a body ending in `Delivery-Task: <id>` (§10) → `graph.sh transition <id> in-review`.

The review/patch loop: reviewer executes criteria on the head and the gate on the head and the merged result → posts a verdict pinned to the head SHA (`forge.sh pr-review … --sha`), verifies it landed, and records the verdict of record (`graph.sh transition <id> approved|changes-requested`; report "ready for human merge" on approval) → patcher fixes, merges in the target branch if it moved, and pushes → repeat, at most 3 times → `needs-human`.

The `deliver-task` skill runs this whole implement → review → patch sequence for a single task in one invocation — the Level-0 counterpart to the loop. The reviewer is always spawned as a fresh agent, so review independence (§3.4) holds by construction; the loop (`delivery-tick`) instead spreads the same roles across ticks so it stays crash-recoverable and replans from the graph each tick.

A merge (human, or `tick-merge.sh` under auto-merge) is turned into `done` by the next reconcile (§5.1 rule 2), which also promotes any dependents whose last dependency just finished.

## 7. Queue Mechanics (deterministic scripts)

All queue mechanics are `bash` + `jq` scripts shipped with the plugin (`scripts/`): the policy core in `scripts/lib/*.jq`, the seams `graph.sh` and `forge.sh`, and the backends and adapters under `scripts/backends/`. Agents call them via `${CLAUDE_PLUGIN_ROOT}/scripts/…`; they never re-derive the logic, and skills never call an issue tracker's or forge's CLI or API directly. The v0.1.4 entry points `task-queue.sh` and `claim-task.sh` remain as compatibility wrappers with unchanged arguments and output.

### 7.1 Ready set — `graph.sh ready` (wrapper: `scripts/task-queue.sh`)

A node is **ready** iff (`lib/ready.jq`):

* `kind` is `task` (epics, promote nodes, and external nodes are never ready);
* its status is not `done` or `cancelled`;
* every dep exists and is `done`. A dep that is **cancelled** (closed as not planned or duplicate) or **unknown** (no such node) never satisfies readiness, and reconcile warns about it;
* it has no claim and no assignee;
* its size is not `L`;
* it is not `needs-human`.

Ordering, best first:

1. tasks under a **started epic** first. An epic is started when at least one of its children is `done` or `cancelled`, so work on an epic already under way finishes before a fresh one begins;
2. tasks that unblock the most open dependents;
3. `S` before `M`;
4. oldest first.

`graph.sh ready` prints `{id, title, unblocks, size, started, epic, module, target_branch}` per line. `task-queue.sh` prints v0.1.4's exact shape, `{number, title, unblocks, size, started, epic, module: "module:<m>"|"none"}`; `task-queue.sh --fix` runs `graph.sh reconcile --fix` first (§5.1), retrying a pass that stopped on exit 4 or 75, with its `fix:` and `warn:` lines on stderr.

Dependency encoding on github: native blocked-by links (gh ≥ 2.94), unioned with legacy `Depends-on: #N` lines in the issue body. A `Depends-on:` line counts only when the keyword starts the line (after optional indentation, one list bullet, and an optional `**` bold opener); a mention mid-line or in a blockquote adds no edge. `graph.sh migrate --apply` turns the text edges into native links (§15). On local, edges are the node's `deps`.

### 7.2 Claiming — `graph.sh claim` (wrapper: `scripts/claim-task.sh`)

`graph.sh claim <id> <actor>` first runs a policy pre-check: the node is valid, `ready → claimed` is legal for the actor kind, it has no claim, and an agent never claims a `needs-human` node. Then it calls the backend's atomic claim. Exit 0 = owned; 1 = lost or not claimable; 75 = the local backend's lock was busy.

**github.** `gh issue edit --add-assignee` is not test-and-set, but GitHub comments are server-ordered, so comment ordering arbitrates:

1. Pre-check: issue open, `status:ready`, zero assignees. Fail fast otherwise.
2. Post a claim comment: `CLAIM <actor> <run-id> <timestamp>`.
3. Re-read all `CLAIM` comments. Earliest *live* wins (a claim voided by a later `RECLAIMED` or a matching `CLAIM-WITHDRAWN` is skipped — `lib/claim-winner.jq`): apply assignee, `status:claimed`, `claim:agent`, remove `status:ready`. Loser posts `CLAIM-WITHDRAWN` and exits nonzero.
3b. Orphan reap: a claimant that dies between step 2 and converting its win to `status:claimed` leaves a `CLAIM` with neither a withdrawal nor a reclaim, so it stays the earliest live claim forever and poison-pills the lock. A live winner converts within seconds, so if we lost but the issue is *still* `status:ready` with zero assignees and the blocking claim is older than the grace window (`CLAIM_GRACE_SECONDS`, default 90s — `lib/orphan-claims.jq`), it never converted: withdraw it on its behalf via `CLAIM-WITHDRAWN` (the ledger's own stand-down path) and re-arbitrate. This clears the orphan in-band, with no dependence on the 4h staleness path in reconcile.
4. Belt-and-suspenders: the implementer re-verifies, before opening the PR, that the node is still `claimed` by its own actor.

Humans claiming via the UI never post `CLAIM` comments; step 1's assignee check is what protects their claim. The grace window in step 3b is comfortably longer than a live claimant's post→convert gap, so a genuine in-flight racer is never mistaken for an orphan.

**local.** Inside the store's `mkdir` lock (§15) the backend re-reads the node, requires `status == "ready"` and no claim, then sets the claim and `status: claimed` and journals a `claim` event. The lock makes it a true test-and-set.

### 7.3 Worktrees — `scripts/task-worktree.sh`

`task-worktree.sh <id>` reads the node through `graph.sh show` and runs `git worktree add .worktrees/task-<id>--<slug> -b task/<id>--<slug> origin/<target_branch>` (the node's `target_branch`, default `BASE_BRANCH`), then `WORKTREE_SETUP_CMD` if set. It prints only the worktree path on stdout. Ids never contain `--`, so a directory name's text before the first `--` is exactly its id. An existing worktree is reused; legacy v0.1.4 worktrees (`.worktrees/task-<n>-<slug>`, branch `task/<n>-<slug>`) are still reused and cleaned up for numeric ids. A target branch missing on origin exits 1 with an error naming `plan.sh apply`. `.worktrees/` is gitignored. `--cleanup <id>` removes the worktree and local branch, only after the merge is confirmed.

## 8. Concurrency and Conflict Strategy

* Worktree-per-task. Parallel implementers never share a checkout.
* **One in-flight task per module per target branch.** Module ownership is the primary merge-conflict avoidance; `tick-plan.sh` enforces it. Open agent PRs (approved-but-unmerged ones included) and `claimed` nodes hold their module's lock. A node with no module is exempt.
* When the target branch moves under a task branch, **merge** `origin/<target_branch>` into the task branch; never rebase a pushed branch.
* Merge conflicts are resolved by the patcher in the task worktree, and pushed with a plain push — **never force-push**, so review history stays intact.
* Default in-flight cap: 2 tasks (serial). Raise only after the loop has demonstrated clean cycles (pilot before scaling).

### 8.1 Union merge driver for append-only registration files (optional)

Many codebases have a few **central registration files** that every new module touches by appending one line — a route table, a DI container, a plugin/module index, a package `__init__`, a service registry. Two module PRs in flight always collide there as benign "both sides appended a line" conflicts, forcing manual conflict resolution. If your repo has such hotspots, this pattern dissolves them:

* Mark those files `merge=union` in `.gitattributes`. On merge git keeps **both** sides' added lines automatically instead of emitting conflict markers — resolving the append-collision at the git layer with no runtime or architecture change.
* Keep union output valid by holding those files in **union-friendly shape**: one import/entry per line, sorted, so a formatter can deterministically re-sort and dedupe. Module PRs must append in that shape.
* **Union is line-dumb.** It can misorder lines (a middle insert may land out of order) or duplicate them (two branches adding the identical line yield two copies), and it never detects semantic conflicts. So the gate (`GATE_CMD`) remains the correctness backstop: a formatter re-sorts and dedupes, and a broken assembly fails the gate before review.
* Union is complementary, not a cure-all: shrink the collision surface where you can (single dispatch points, one handler), and let the orchestrator's rebase action (§8.2) handle the non-append conflicts union cannot.

### 8.2 Orchestrator rebase for approved-but-conflicting PRs

* Module ownership and the union driver (§8.1) prevent most collisions, but a PR that was already **approved** can still conflict when a sibling merges ahead of it — a non-append edit the union driver cannot auto-resolve. Such a PR falls through the loop: it is out of the review cycle (already approved) yet not mergeable, so absent intervention it stalls until a human hand-dispatches a fix.
* The orchestrator tick closes the gap. `tick-plan.sh` emits a **`rebase`** action (rule 3, after patches, before reviews and starts) for an open agent PR whose node is `approved` and whose forge mergeability is `conflicting`, while the PR is under the patch budget and not `needs-human`. The name is historical: the action is carried out by **merging**.
* The rebase-only patch (`patch-task` in rebase-only mode) is mechanical: **merge** `origin/<target_branch>` into the task branch in its worktree, resolve conflicts there, re-run the gate, and push with a plain `git push`. It never rebases a pushed branch and **never force-pushes**. It **preserves `approved`** (the approval still stands after a mechanical catch-up; the node is not sent back to review), comments `Patch iteration: <n+1>/3 (rebase)` so repeated re-conflicts stay bounded, and the PR re-emerges mergeable.
* **Optional auto-merge (`--auto-merge`, opt-in, off by default).** By default the now-mergeable approved PR is handed to a human — the merge authority the rest of this spec assumes. Run the loop with `--auto-merge` and the plan carries `merge` actions (rule 1, highest priority) for every agent PR whose node is an `approved` task, that is mergeable-clean with checks `success` or `none` (no checks counts as green), not `needs-human`, and based on the node's `target_branch`. The tick runs each through `tick-merge.sh <pr> <sha>`, one at a time, which:
  1. re-reads the PR (re-polling an `unknown` mergeability), refuses a moved head or a promotion PR, and re-applies the merge rule over fresh state;
  2. runs `GATE_CMD` on the **merged result** — a fresh detached worktree of `origin/<base>` with the head merged in — because two PRs green on their own can be red together, and a forge reports a behind PR as clean when nothing requires it to be up to date. The gate runs with the config keys unset, so the merged tree's own `.claude/delivery.conf` governs it;
  3. refuses if `origin/<base>` moved while the gate ran;
  4. merges with `TASK_MERGE_METHOD`, pinned to the head SHA, and confirms the forge reports it merged;
  5. reconciles, so the task goes `done` and dependents unblock.

  A conflicting or red merged result is not merged: under the patch budget `tick-merge.sh` prints a `rebase` action for the tick to dispatch; at the budget it escalates itself (flags the node `needs-human`, comments `MERGE-NEEDS-HUMAN: …` with the gate output, runs `NOTIFY_ESCALATE_CMD`) and prints a `needs-human` result. Any other refusal leaves the PR for the next tick to re-plan.
* The plan **skips PRs labeled `needs-human` or already at the max patch iteration** (a `Patch iteration: 3/3` comment), so a conflict that cannot be resolved mechanically escalates once rather than re-dispatching forever.
* This is defense-in-depth complementary to §8.1: the union driver dissolves append collisions at the git layer; the rebase action recovers the non-append conflicts union cannot.

## 9. Failure Policy

* Max 3 patch iterations per PR, tracked in a PR comment (`Patch iteration: n/3`). At 3: the dispatched patcher flags the node `needs-human`, comments a summary of the impasse on the PR, runs `NOTIFY_ESCALATE_CMD`, and stops.
* An implementer that cannot satisfy a criterion (bad spec, missing dependency, environment problem) flags the node `needs-human`, releases its claim with a one-line reason (`graph.sh release <id> "blocked: …"`), runs `NOTIFY_ESCALATE_CMD`, and stops. It does not push partial work as if complete, and the node does not go back to the ready queue until a human clears the flag.
* **Encode-the-lesson rule.** When a failure was caused by the harness — ambiguous acceptance criteria, a missing gate check, a template gap — the fix must include a follow-up `module:infra` task to repair the harness, not just the instance.

## 10. Provenance

* Agent PRs carry the `agent-authored` label (applied by `forge.sh pr-create --label`). Only agent PRs produce loop actions. On github, issues also carry `agent-authored` or `human-authored`.
* **PR ↔ task linkage: the `Delivery-Task:` trailer.** Every agent PR body ends with the line `Delivery-Task: <node id>` at column 0, on every backend. Forge adapters fill a PR's `task_id` from the first of: the `Delivery-Task:` trailer; on the github backend, the first `Closes|Fixes|Resolves #N` line; a `task/<id>--…` head branch; a legacy `task/<n>-…` head branch. This replaces v0.1.4's `#N` body/title match, which falsely linked any PR that merely mentioned an issue.
* PR bodies follow the template: on the github backend a first line `Closes #<id>`; summary; the task's acceptance criteria as a checklist, each with evidence (the command output line); gate status; an **Implementer findings** section; provenance line (`Agent-authored (model: <model>)` or `Human-authored`); and the `Delivery-Task:` trailer. On any other backend the body also carries the full task contract, because the PR is the only place a reviewer on the forge sees it.
* Agent commits carry a `Co-Authored-By` trailer identifying the model.
* **Verdicts carry the `Reviewed-Head:` trailer.** `forge.sh pr-review <pr> approve|request-changes|comment --sha <head_sha>` refuses a stale SHA and appends `Reviewed-Head: <sha>` to every verdict body, whatever form it lands in (formal review, GitLab note, or comment fallback). A comment has no commit of its own, so the trailer is how every forge ties a verdict to a head: a PR's `reviewed_at_head` is true when some review or comment carries a `Reviewed-Head:` equal to its current head. The reviewer verifies the verdict landed (`forge.sh pr-reviews`) before recording it.
* Review verdicts are forge reviews or verdict comments, so review history is inspectable and cannot be overwritten. Nothing in the loop force-pushes.

## 11. Verification and Gates

Three enforcement points, one definition:

* **`GATE_CMD`** (from `.claude/delivery.conf`; default `bash scripts/check.sh`) is the gate — one command that exits 0 iff the repo is correct, and the single definition of "correct." The implementer, patcher, and reviewer all run it; the reviewer runs it on the PR head and on the merged result, and `tick-merge.sh` runs it on the merged result before an auto-merge. `promote.sh` runs `PROMOTE_GATE_CMD` (empty = `GATE_CMD`) on the target branch before opening a promotion PR. Keep it fast enough to run on every change and honest enough that green means mergeable.
* **The gate is a checked-in, self-maintaining artifact.** `init` seeds `scripts/check.sh` from the repo's detected tooling; from then on a task that introduces a tool, test suite, or build step extends it (decomposer method; implementer step 5). So "correct" grows with the repo rather than freezing at bootstrap — no human hand-maintains the gate.
* Git hooks (optional, the consumer repo's own): hygiene/format at pre-commit on changed files; the gate at pre-push. Never bypassed — `--no-verify` is banned.
* CI runs the same gate on every PR. **A PR with failing checks is unreviewable** — reviewers request changes on sight; an approval is never posted while checks are pending.

Acceptance criteria are executed, not trusted: the reviewer runs every criterion itself in a clean checkout.

## 12. Day-1 Topology and Upgrade Path

Day 1: a single local Claude Code orchestrator session runs `/loop` (dynamic self-pacing) with `delivery-tick`. Implementers and reviewers run as subagents; implementers in worktrees. Humans interact through the graph backend (GitHub Issues, or `graph.sh` on local) and the forge. Operational detail — pre-flight checks, free-run bounds, throughput, backends, promotion, troubleshooting — lives in [`delivery_runbook.md`](delivery_runbook.md).

Because all durable state lives in the graph backend and on the forge, and all mechanics live in `scripts/`, the upgrade path is mechanical, not architectural:

* Event-driven: forge CI or GitHub Actions triggered on board or review events, invoking the same skills.
* Scheduled: a `/schedule` cloud routine running `delivery-tick` on a cadence (github backend; the local backend is single-machine, §15).
* Parallel fan-out: worktree-per-task isolation means concurrent dispatch is a config change, gated on demonstrated clean cycles. Realized by `delivery-tick --parallel N`: the same orchestrator tick plans up to N independent agent actions (at most one action per PR, one in-flight task per module per target branch) and dispatches them concurrently, waiting for the whole batch before the tick ends. Because the tick is synchronous, `/loop /delivery-tick --parallel N` can never overlap two batches — and coordination stays in the graph and on the forge, so it remains crash-recoverable (runbook §3 Level 3, §9).

## 13. Open Questions

1. When to enable branch protection with required checks (adds friction for a single human merger today).
2. When reviewer approval becomes a required forge review rather than a status convention. Until then, a dedicated reviewer token lets reviewers post formal approve/request-changes reviews; without it, all agents run under one account and the verdict of record is a comment-form verdict plus the node status (§13.2, runbook §7).
3. Claiming etiquette once multiple humans share the queue.
4. Whether `delivery-tick` should auto-dispatch decomposition when the ready queue drains below a threshold.
5. Whether merged-PR retrospectives should periodically mine `needs-human` escalations for harness improvements (batch encode-the-lesson).

### 13.2 Single-account review fallback

When every agent runs under the same forge account as the PR's author, every forge refuses (or may refuse) a formal verdict on one's own PR: GitHub rejects `--approve`/`--request-changes`, Gitea and Forgejo answer 422, and GitLab blocks author approval and has no request-changes endpoint at all. `forge.sh pr-review` then falls back to a **comment-form verdict** with the same body: a comment (a GitLab note) headed `## Adversarial review — verdict: <VERDICT>` and ending in `Reviewed-Head: <sha>`. The adapter adds the heading when the body lacks one (GitLab refuses a body whose heading names a different verdict). `forge.sh pr-reviews` returns formal reviews plus every comment whose first non-blank line is such a heading (`backends/forge-verdict.jq`, shared by every adapter), so the reviewer can verify either form landed. The node status (`approved` / `changes-requested`) carries the verdict of record, and the human merge is the real approval gate. Setting `GH_REVIEW_TOKEN` / `GITLAB_REVIEW_TOKEN` / `GITEA_REVIEW_TOKEN` in the environment posts verdicts under a separate reviewer identity, which restores formal reviews (§13 Q2).

## 14. Summary

Specs decompose into a dependency-ordered work graph — GitHub Issues or local JSON — with command-shaped acceptance criteria. An orchestrator loop ticks one agent action at a time (or one bounded batch of independent actions, with `--parallel N` — §12): claim ready work into worktrees, implement to criteria, gate everything through one shared command, adversarially review with independent contexts, patch within bounds, and hand every merge to a human (or opt into auto-merge, which gates the merged result first). Task PRs land on a plan's target branch; a promotion PR, always merged by a human, carries the branch onward. Scripts are deterministic; agents supply only judgment; the graph and the forge remember everything.

## 15. Graph backends

The work graph is read and written only through `scripts/graph.sh`, which
validates the config once, loads the configured backend
(`scripts/backends/graph-$GRAPH_BACKEND.sh`), runs `validate_node` on every node
a backend emits (exit 5 on drift), and applies the `lib/*.jq` policy. Backends
store; they never compute readiness, ordering, staleness or legality.

**`graph.sh` ops.** `ready` · `list` (every node, open and closed, one JSON
array) · `show <id> [--format json|md] [--events]` · `export` (every node,
pretty-printed, for backup and debugging) · `create` · `update` · `link <id>
<dep-id> [via]` · `flag <id> needs-human on|off` · `release <id> <reason>` ·
`comment <id> <text>` · `claim` (§7.2) · `transition <id> <to> [--actor
agent|human|promote] [--human <name>]` (§5) · `reconcile [--fix]` (§5.1) ·
`migrate [--apply]` (github only). Exit codes: 0 ok · 1 failed / invalid config /
not claimable · 2 usage or an illegal transition · 3 a list (or an events
thread) reached `LIST_LIMIT` · 4 reconcile: the board changed (re-run) · 5 a
backend node failed validation · 75 the local lock was busy (retry). The
`graph.sh` header is the authoritative contract.

**The node shape** (`lib/node.jq`): `id`, `kind` (`task` \| `epic` \| `promote`
\| `external`), `title`, `epic`, `checklist`, `pinged_at`, `applied_prs`,
`module`, `size`, `deps: [{id, via}]`, `status`, `needs_human`, `claim: {actor,
run, at, by}`, `target_branch`, `promote_to`, `plan_ref`, `body`, `created_at`,
`updated_at`.

**Events.** `graph.sh show <id> --events` prints the node, then its events, one
JSON object per line, oldest first, with the fields `{ts, actor, run, op, id,
from, to, body}`. On local these are the node's last 10 journal events of any
op; on github, the issue's whole comment thread as `comment` events (paginated;
a thread of `LIST_LIMIT` or more comments exits 3). Events are a read-only view:
a comment never changes the node's parsed metadata. Agents treat the
`comment` events that are not script-written markers (`CLAIM `,
`CLAIM-WITHDRAWN `, `RELEASED:`, `RECLAIMED`, `STALE-CLAIM-PING`,
`AUTO-CLOSE:`, `TRANSITIONED:`, `MERGE-NEEDS-HUMAN:`, `PROMOTE-GATE-RED:`,
`nothing to promote:`) as part of the task contract, because the
implementer-side roles never write free-text node comments.

**`github`** (default). Nodes are issues: kind from the `task` / `epic` /
`promote` labels, status from labels plus issue state, edges from native
blocked-by links and legacy `Depends-on:` lines, the epic from the native parent
(else the `[Ee]pic #E` body match), the claim from assignee + `claim:agent` +
the winning `CLAIM` comment. One `gh issue list --state all --limit
$LIST_LIMIT` reads everything; a result count equal to `LIST_LIMIT` exits 3
rather than truncating. Native relations need gh ≥ 2.94; on an older gh only
text edges are read and written, with one warning per invocation. The machine
keys `Delivery-Target:`, `Delivery-Plan:` and `Delivery-Promote-To:` are read
only from the issue body's final **trailer block**, which `create` always writes
last; a key line anywhere else is prose (`show` warns about it). `graph.sh
migrate` plans native blocked-by links and parents from the legacy text
conventions; it is a dry run unless `--apply` is passed, and refuses to exceed
GitHub's 50-blockers-per-issue cap.

**`local`.** The graph lives in `STATE_DIR` (empty = `<git-common-dir>/delivery`,
so every worktree of a clone shares it and it survives branch switches; needs
git ≥ 2.31): `store.json`, one `epics/<epic-id>.json` per epic
(`epics/inbox.json` for nodes with no epic), and an append-only `events.jsonl`
journal. Every mutation runs inside a `mkdir` lock (`STATE_DIR/lock/`, owner
`host pid run epoch`), waited on for `LOCK_WAIT_SECONDS` (exit 75 after), and a
lock whose owner is a dead process on this host older than
`LOCK_STALE_SECONDS` is broken by a serialized break step. Writes replace files
atomically, so readers take no lock. The journal records every mutation as
`{ts, actor, run, op, id, from, to, body}`; `update` and `flag` journal as
`transition` (`from == to` when the status did not change; a flag's body is
`needs-human on|off`). The local backend is **single-machine**: there is no
cross-machine sync, and its only remote state is the forge's PRs, reviews and
comments. A PR merged on the forge becomes `done` locally through reconcile.

**Valid combinations.** `GRAPH_BACKEND=github` requires `FORGE=github` (issues
and PRs share a host). `GRAPH_BACKEND=local` works with any forge.

## 16. Forges

PRs are read and written only through `scripts/forge.sh`, which validates the
config once and dispatches to `scripts/backends/forge-$FORGE.sh`. Adapters map
one forge onto a normalized PR shape and translate; eligibility rules live in
`lib/tick-plan.jq`.

| `FORGE` | Transport | Auth |
|---|---|---|
| `github` | `gh` | `gh auth` (optional `GH_REVIEW_TOKEN`) |
| `gitlab` | `curl` + `jq` against `${FORGE_URL}/api/v4/projects/<url-encoded FORGE_REPO>` | `GITLAB_TOKEN` (optional `GITLAB_REVIEW_TOKEN`) |
| `gitea` (also Forgejo) | `curl` + `jq` against `${FORGE_URL}/api/v1/repos/<owner>/<repo>` | `GITEA_TOKEN` (optional `GITEA_REVIEW_TOKEN`) |

`FORGE_URL` and `FORGE_REPO` default from `git remote get-url origin` (https and
ssh forms). Tokens come from the environment only and are passed to curl in a
private header file, never on the command line. `FORGE_DRY_RUN=1` makes the curl
adapters print each write as `METHOD PATH` plus its JSON body instead of sending
it.

**The PR shape** (`lib/pr.jq`): `number` (GitLab's `iid`), `url`, `state`
(`open` \| `merged` \| `closed`), `head`, `base`, `head_sha`, `mergeable`
(`clean` \| `conflicting` \| `blocked` \| `unknown`; `unknown` is re-polled, never
merged), `checks` (`success` \| `pending` \| `failure` \| `none`), `task_id`
(§10), `labels`, `patch_iteration` (the highest `Patch iteration: n/3` comment),
`reviewed_at_head` (§10), `agent` (the `agent-authored` label), `author`.

**Ops:** `whoami` · `pr-create --head H --base B --title T --body-file F
[--draft] [--label L]…` · `pr-view <n>` · `pr-list [--state open|merged]
[--since ISO]` (fully paginated) · `pr-find --head H` · `pr-review <n>
approve|request-changes|comment --sha S --body-file F` · `pr-reviews <n>` ·
`pr-comment <n> --body-file F` / `pr-comments <n>` · `pr-merge <n> --method
squash|merge --sha S` · `pr-set-base <n> <branch>` · `pr-files <n>` / `pr-diff
<n>` · `ci-failures <n>`. Exit codes: 0 ok · 1 failed / refused / invalid config
· 2 usage · 3 a list reached `LIST_LIMIT` · 4 unsupported by this forge (e.g.
`ci-failures` on gitea: the patcher then reproduces the failure by running
`GATE_CMD` locally). The `forge.sh` header and each adapter header are the
authoritative contract.

**Rules every adapter keeps:**

* Every verdict and merge pins the head SHA; a stale `--sha` is refused before any write.
* `pr-merge` exits 0 only once a re-read shows the PR merged (on github it also disables an auto-merge gh enabled instead of merging, and exits 1).
* `pr-create --label` applies existing labels only and never creates one; each value is exactly one label (a name holding a newline or CR is refused everywhere, a comma on github and gitlab, a `"` on github). On github the labels are a second request after the create: if it fails, the adapter exits 1 naming the created PR's URL, and the caller recovers it with `pr-find --head` rather than opening a duplicate.
* Self-review rejection falls back to a comment-form verdict (§13.2).
* Merge style: GitLab's project-level merge method decides what a non-squash merge produces, and Gitea refuses (405) a merge style the repo disallows. So `PROMOTE_MERGE_METHOD=merge` requires merge commits to be enabled on the forge (§17, runbook §2).

## 17. Branch flow & promotion

* **Targets.** Every node has a `target_branch`, default `BASE_BRANCH`; a plan file sets it for its nodes (§18). `task-worktree.sh` forks from `origin/<target_branch>`, task PRs are created with `--base <target_branch>`, and implementers and patchers catch up with a moved target branch by **merging** it into the task branch — never rebasing, never force-pushing. Reconcile closes a task when its PR merges into its own `target_branch`, whichever branch that is (§5.1 rule 2).
* **Merge methods.** Task PRs merge with `TASK_MERGE_METHOD` (default `squash`). Promotion PRs merge with `PROMOTE_MERGE_METHOD` (default `merge`, which keeps the target branch's ancestry), so the repo must keep merge commits enabled.
* **Promote node.** For a plan with `promote_to` set, `plan.sh apply` creates one node of kind `promote` carrying `target_branch` T and `promote_to` P, whose deps are the plan's **epics** (not its tasks, which keeps a large plan under GitHub's 50-blocker cap). Epics become `done` through reconcile (§5.1 rule 5), so the promote node becomes `ready` when every epic is delivered. `next-task` never claims it: only `task` nodes are ever ready.
* **Promote action.** `tick-plan.sh` emits `promote` for a `ready` promote node that is not `needs-human`. The tick runs `promote.sh <id>`, a deterministic script:
  1. claim the node (actor `promote`);
  2. if `origin/P` and `origin/T` have identical trees, comment `nothing to promote`, set the node `done`, and open no PR;
  3. otherwise run `PROMOTE_GATE_CMD` (empty = `GATE_CMD`) in a fresh detached worktree of `origin/T`, after `WORKTREE_SETUP_CMD`;
  4. red: flag the node `needs-human`, comment `PROMOTE-GATE-RED: …` with the failing output, run `NOTIFY_ESCALATE_CMD`, release the claim, and exit 1;
  5. green: open the promotion PR (head T, base P, title `Promote T → P`, a body listing the plan's done tasks, ending in `Delivery-Task: <id>`) through `forge.sh pr-create --label agent-authored` — or reuse the open PR already on head T into P — and set the node `in-review`. The `agent-authored` label is what makes reconcile treat it as an agent PR and close the node once it merges.

  A failure that is not the gate's (git, forge, graph) releases the claim without flagging, so the next tick retries; once the PR exists the claim is kept and reconcile moves the node to `in-review`.
* **Merging a promotion PR.** Always a human, with `PROMOTE_MERGE_METHOD`. A promotion PR is **never auto-merged**, even under `--auto-merge`: `tick-plan.sh` emits no merge action for it and `tick-merge.sh` refuses it. Reconcile marks the node `done` when it merges.
* **Out of scope.** Keeping T in sync with P while work is in flight (merging P back into T), and multi-hop promotion (`develop → qa → main`), stay human operations. A conflicting promotion PR is a human's to resolve.

## 18. Plan files

The decomposer's output is a checked-in, reviewed **plan file**,
`PLANS_DIR/<plan>.plan.json` (JSON, so it is `jq`-native):

```json
{
  "schema": 1,
  "plan": "example-plan",
  "spec": ["docs/example_spec.md"],
  "target_branch": "release/1.0",
  "promote_to": "main",
  "epics": [{"id": "core", "title": "Core", "goal": "…", "spec_refs": ["§3"]}],
  "tasks": [
    {"id": "parser", "epic": "core", "title": "…", "module": "core", "size": "M",
     "deps": [{"id": "schema", "via": "lib/schema.jq validate"}],
     "context": "…", "criteria": ["`<GATE_CMD>` passes", "…"],
     "scope": ["src/parser/"]}
  ]
}
```

Ids are lowercase slugs (`a-z0-9` and single `-`). A dep names a task of this
plan or an existing node (`"#42"` on github, a node id on local), and every dep
names its seam in `via`. `target_branch` defaults to `BASE_BRANCH`. `scope` is
recorded, not yet enforced. `plan.sh` runs the config check once, and every op
refuses a plan file with a duplicate JSON key.

* **`plan.sh lint <file>`** exits 1, listing every error, for invalid schema or types, duplicate or malformed ids, an unresolved dep, a cycle (named), a dep without `via`, a module outside `MODULES ∪ {infra, docs}`, a size other than S/M/L, empty `criteria`, two plans sharing a `target_branch` but not a `promote_to` (or sharing a `plan` id), and any plan text that a backend would read back as a machine marker (`Delivery-Plan:`, `Depends-on: #N`, …). Size `L` is a warning.
* **`plan.sh render <file>`** prints a Mermaid `flowchart TD`: one subgraph per epic, one node per task labeled `id: title [module/size]`, one edge per dep labeled with its `via`, and the promote node. Every label goes through `lib/plan-render.jq`'s `mermaid_text`; `task-status --graph` renders the live graph through the same function.
* **`plan.sh apply <file>`** is idempotent: it creates whatever is missing and never deletes or overwrites anything. Nothing is written until every check passes: lint against the full `graph.sh list`; `git check-ref-format` on the branches; a preflight (plan_ref collisions, local id reuse across plans, GitHub's title/body, 50-blocker and 100-sub-issue limits); and a composed-body check that renders each node exactly as the backend's `create` writes it and reads it back with the backend's own reader. An existing node (found by `plan_ref`, the idempotency key `<plan>/<id>`) that differs from the plan is reported as `drift: <id> <field>` on stderr and left unchanged (exit 0). A `target_branch` missing on origin is created from `origin/<promote_to or BASE_BRANCH>`, printing the exact `git push` first. Then it creates epics, tasks in topological order (on github: sub-issues with native blocked-by links), and the promote node, and runs `graph.sh reconcile --fix`.
* **`decompose` flow.** Dry run: write the plan file (uncommitted), lint, render, print the backlog table and the Mermaid graph, and stop. `--create`, only after a human approves the graph: commit the plan file (directly, or by PR when the repo requires it, then wait for the merge), then `plan.sh apply` from that commit.
