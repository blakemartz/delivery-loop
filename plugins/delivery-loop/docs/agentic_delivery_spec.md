# Agentic Delivery Spec (delivery-loop) v0.1

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

## 2. Delivery Thesis

GitHub Issues are the single source of truth for work state. Git worktrees
isolate parallel implementers. Deterministic scripts own queue mechanics —
computing the ready set, claiming, worktree setup — so agents never re-reason
about them, and a single per-repo gate command owns verification. Model
reasoning owns only judgment: decomposition, implementation, review, and
patching. A human owns every merge (unless auto-merge is opted into, §8.2).

Corollaries:

* Any state that matters survives the death of every agent session, because it lives in GitHub.
* Any actor — agent or human — can pick up any ready task through the same protocol.
* The gate is one command, called identically by git hooks, CI, and agents, so it cannot drift.

## 2.1 Engineering Principles

These bind every role — decomposer, implementer, reviewer, patcher — not just the loop mechanics:

* **Pursue best-practice solutions.** When more than one approach satisfies the acceptance criteria, choose the idiomatic, standard one for the language and framework over the cleverest or most expedient. Match the styleguides and existing patterns.
* **Solve each problem in its own layer.** Do not distort runtime architecture to work around a process or tooling problem — a merge conflict, a CI quirk, a claim race. Fix those in the layer where they belong (git, hooks, the harness). Load-bearing example: benign "both sides appended a line" merge conflicts are solved by rebase automation and a `.gitattributes` merge driver (§8.1), not by reshaping how the application wires itself together.
* **Best practice is a quality bar, not an acceptance criterion.** Acceptance criteria stay concrete and command-checkable (§7; decompose Hard Rule 1) — "follows best practices" is never itself a criterion. The bar is upheld by implementers choosing the idiomatic solution and reviewers flagging non-idiomatic ones, even when every criterion passes.
* **Flag, don't silently comply.** If a task's prescribed approach or criteria force a non-best-practice solution (a workaround, an anti-pattern), raise it — comment on the issue, note it in the PR, or escalate `needs-human` — rather than ship the anti-pattern to satisfy the letter of the task.

## 2.2 Per-repo configuration

Everything project-specific lives in one file, `.claude/delivery.conf` at the
repo root (scaffolded by `delivery-init.sh`, resolved by `scripts/lib/config.sh`).
The engine and skills read it; nothing else needs editing to adopt the loop:

| Key | Default | Role |
|---|---|---|
| `GATE_CMD` | `bash scripts/check.sh` | THE gate (§11) — one command that exits 0 iff the repo is correct. |
| `BASE_BRANCH` | `main` | Branch worktrees fork from and PRs target. |
| `WORKTREE_SETUP_CMD` | (detected) | Command run once in a fresh worktree (install deps). |
| `SPEC_SOURCES` | `docs/*_spec.md` | Files the decomposer reads (§3.2). |
| `STYLEGUIDES_DIR` | `styleguides/` | Coding conventions implementers/reviewers consult. |
| `MODULES` | (empty) | Allowed `module:` labels — the concurrency unit (§8). |
| `NOTIFY_APPROVE_CMD` / `NOTIFY_ESCALATE_CMD` | (empty) | Optional hooks on approval / escalation. |

## 3. Roles

### 3.1 Orchestrator

The loop driver. Typically a local Claude Code session running `/loop` against the `delivery-tick` skill. Each tick advances the board by exactly one state transition (reclaim stale work, patch a rejected PR, review an unreviewed PR, or start the next ready task) — or, with `--parallel N`, by one bounded batch of up to N independent transitions the tick waits out (§12).

The orchestrator never implements, reviews, or merges. It dispatches.

### 3.2 Decomposer

Reads the spec sources (`SPEC_SOURCES`) and the conventions (`STYLEGUIDES_DIR`), and proposes epics and tasks. Runs dry by default; creates issues only after a human approves the proposed backlog. For subsystems covered by a focused sub-spec, the sub-spec's decompose-ready cutline is the primary source (authored upstream by the spec author, §3.7) — translate it, don't re-derive it.

### 3.3 Implementer

Claims one ready task, works in a dedicated worktree, satisfies every acceptance criterion, passes the gate, opens a PR. One task, one branch, one PR.

### 3.4 Reviewer

A fresh agent with no access to the implementer's context. Inputs are only: the issue's acceptance criteria, the PR diff, the styleguides, and a clean checkout of the PR branch in which it **executes** every acceptance criterion. Approves or requests changes. Never reviews its own work — reviewer and implementer are always different agent instances.

### 3.5 Patcher

Responds to review findings or failing CI on an existing PR. Usually the implementer role resumed in the same worktree. Bounded to 3 iterations per PR (§9).

### 3.6 Human

Approves proposed backlogs, pins spec-level design decisions and nods on spec drafts before they become PRs, merges every PR (or opts into auto-merge, §8.2), breaks ties, handles `needs-human` escalations, and may claim any task off the same queue on equal footing with agents.

### 3.7 Spec author

Upstream of the decomposer: turns a subsystem into a merged, decompose-ready sub-spec (`/delivery-loop:author-spec`). Collects operator pins before drafting, grounds every claim against the repo and primary sources, drafts to a house template, and lands the spec through a fresh-agent adversarial **docs review** (grounding, consistency, and buildability instead of executable criteria; verdict as a single GitHub review comment — the single-account form of record, §13.2 and runbook §7). Docs-review fix rounds resume the *same* reviewer — its grounding context is the asset — a deliberate deviation from §3.4's fresh-reviewer rule, scoped to docs reviews only. Two human gates: the draft nod before any PR, and the `/decompose` backlog approval after merge. The spec PR's merge follows the same authority model as every other PR (§3.6, §8.2): human by default, agent only under the operator's explicit standing authorization. The spec author never implements tasks — it hands the merged cutline to the decomposer and stops. Sequencing is deliberate: decomposition always runs against the **merged** spec, because review rounds change cutlines.

## 4. Task Model

A task is a GitHub Issue with the `task` label.

Required fields (encoded in the issue template):

* Context — what and why, with spec references
* Acceptance criteria — see determinism rule below
* Depends on — `Depends-on: #N #M` line(s), the machine-parsed dependency edges
* Module — exactly one `module:<name>` label
* Size — `size:S` or `size:M` (`size:L` exists only as a marker meaning "split me; not claimable")

Rules:

* **Determinism rule.** Every acceptance criterion is a command that must exit 0, or a checkable artifact ("`<GATE_CMD>` passes", "`test -d src/parser`", "`curl -s localhost:PORT/health` returns 200"). Never "works well" or "is clean".
* **Sizing rule.** Every task must fit comfortably in one agent context. `size:M` is the maximum claimable size.
* **One module per task.** The `module:` label is the concurrency unit (§8).

### 4.1 Worked criterion examples

The determinism rule in practice — criteria a reviewer can execute verbatim vs. criteria that cannot be enforced:

| Good (command-shaped) | Bad (unenforceable) | Why the good one wins |
|---|---|---|
| `<GATE_CMD>` passes | "code is clean and follows best practices" | The gate is executable; "clean" is a vibe. Best practice is a quality bar upheld in design and review, never a criterion (§2.1). |
| `<test runner> path/to/module_test` passes, including the golden cases from the spec | "the parser works correctly" | Golden-case tables pin behavior to specific inputs → expected outputs; "correctly" is undefined. |
| `test -f migrations/<name>` exists and `<migrate command>` exits 0 | "the database schema is updated" | A checkable artifact plus a command that must exit 0. |
| `curl -s -o /dev/null -w '%{http_code}' localhost:PORT/health` prints `200` | "the service runs reliably" | Observable behavior at a seam, not an aspiration. |

Design-shaped work (an algorithm, a wire format, a workflow) is specced **before** it is decomposed: the spec document supplies golden-case tables and concrete seams so that every derived task's criteria can be command-shaped. A task whose criteria cannot be made command-shaped is a signal that a spec is missing — write the spec; don't ship the mushy criterion.

An epic is a GitHub Issue with the `epic` label: a goal, spec references, and a task list of child issues. Epics are trackers only — never claimed, never in the ready queue.

## 5. Task Lifecycle State Machine

States are encoded as `status:*` labels:

```
status:blocked ──deps close──▶ status:ready ──claim──▶ status:claimed
                                                            │ PR opened
                                                            ▼
             ┌───────────── status:in-review ◀──────────────┘
             │ review rejects        │ review approves
             ▼                       ▼
  status:changes-requested    status:approved ──human merges──▶ closed
             │ patch pushed
             └──────────▶ status:in-review   (≤3 patch iterations, then needs-human)
```

Legal transitions and actors:

| Transition | Performed by |
|---|---|
| blocked → ready | `task-queue.sh --fix` when all `Depends-on` issues are closed |
| ready → claimed | `claim-task.sh` (agent) or self-assignment in the UI (human) |
| claimed → ready | stale-claim reclamation (§5.2), or claimant releasing |
| claimed → in-review | implementer, on opening the PR |
| in-review → changes-requested | reviewer |
| changes-requested → in-review | patcher, on pushing fixes |
| in-review → approved | reviewer |
| approved → closed | human merge, or auto-merge (§8.2); PR `Closes #N` auto-closes |
| any → needs-human | any actor hitting an impasse |

### 5.1 Ground-truth precedence

Labels are a derived cache, not ground truth. Precedence when they disagree:

closed issue > merged PR > open PR state > labels.

`task-queue.sh --fix` reconciles labels to ground truth every orchestrator tick.

It also closes **fully-delivered epics**: an open `epic` issue is a tracker, and
once every one of its child tasks is closed the tracker is done, so `--fix` closes
it (a `fix: #E epic fully delivered -> closed` line). Children are the union of
tasks whose body says `Part of epic #E` and the `#N` refs in the epic's own
`- [ ] #N` checklist; a `>=1`-child guard keeps a freshly-created epic whose tasks
are not filed yet from closing itself vacuously.

### 5.2 Claims: human vs agent, and staleness

* Agent claim = the `claim-task.sh` protocol (§7.2): assignee + `status:claimed` + `claim:agent`.
* Human claim = self-assignment in the GitHub UI. No `claim:agent` label. Scripts fix status labels up around it.
* Agents treat **any existing assignee** as an absolute stop. Agents never touch an issue assigned to someone else and never review or patch a human-authored PR unless the human has opted in by labeling it `status:in-review`.
* Stale agent claim: `claim:agent`, no linked open PR, no activity for 4 hours → auto-reclaimed (assignee removed, back to `status:ready`, explanatory comment).
* Stale human claim: flagged at 72 hours with a comment ping. **Never auto-reclaimed.** A human decides.

## 6. The Loop Protocol

One orchestrator tick (`delivery-tick`), in order — the first matching action is taken, then the tick ends:

1. `task-queue.sh --fix` — reconcile labels, reclaim stale agent claims, close delivered epics.
2. If a PR is `status:changes-requested` → dispatch the patcher.
3. Else if a PR is `status:approved` but `CONFLICTING` — a sibling merged ahead of it (§8.2) → dispatch a **rebase-only** patcher that preserves the approval. Skip PRs already `needs-human` or at max patch iterations.
4. Else if a PR is `status:in-review` with no completed review → dispatch a **fresh** reviewer agent.
5. Else if the ready set is non-empty and in-flight tasks < 2 → dispatch an implementer on the top ready task (the `next-task` skill).
6. Else report the board and idle.

(With `--auto-merge`, a step 1′ runs before step 2: squash-merge every approved, mergeable, green PR — §8.2.)

One state-advancing action per tick keeps `/loop` pacing meaningful: the loop self-paces against how fast the board actually changes. In parallel mode (`--parallel N`, §12) a tick instead collects all matching actions from the same priority order into one independent batch of ≤ N (at most one action per PR, one in-flight task per module) and awaits the whole batch before ending — a single bounded dispatch, so the pacing property is preserved.

The implementer's inner loop for one task:

claim → worktree → implement to acceptance criteria (consulting the module's styleguide) → run every criterion + the gate (`GATE_CMD`) → commit (any pre-commit hooks fire) → push (any pre-push gate fires) → open PR with `Closes #N` → label `status:in-review`.

The review/patch loop: reviewer executes criteria in a clean checkout → approve (`status:approved`, report "ready for human merge") or request changes (`status:changes-requested`) → patcher fixes and pushes → repeat, at most 3 times → `needs-human`.

The `deliver-task` skill runs this whole implement → review → patch sequence for a single issue in one invocation — the Level-0 counterpart to the loop. The reviewer is always spawned as a fresh agent, so review independence (§3.4) holds by construction; the loop (`delivery-tick`) instead spreads the same roles across ticks so it stays crash-recoverable and replans from GitHub each tick.

Human merge (or auto-merge) closes the issue; the next tick's `--fix` promotes any dependents whose last dependency just closed.

## 7. Queue Mechanics (deterministic scripts)

All queue mechanics are `gh` + `jq` shell scripts shipped with the plugin (`scripts/`). Agents call them via `${CLAUDE_PLUGIN_ROOT}/scripts/…`; they never re-derive the logic.

### 7.1 Ready set — `scripts/task-queue.sh`

A task is **ready** iff: open, `task` label, every issue referenced by `Depends-on:` lines is closed, zero assignees, not `size:L`, and not `needs-human`.

Ordering: tasks that unblock the most open dependents first, then `size:S` before `size:M`, then oldest first.

`--fix` applies derived-state repairs: promotes `status:blocked → status:ready` when dependencies have closed, flags/reclaims stale claims, and closes fully-delivered epics.

Dependency encoding is `Depends-on: #N` lines in the issue body — chosen over GitHub task-lists (no API-queryable blocked semantics) and Projects fields (most moving parts, no day-1 benefit). Human-writable, template-prompted, trivially parseable.

### 7.2 Claiming — `scripts/claim-task.sh`

`gh issue edit --add-assignee` is not test-and-set, but GitHub comments are server-ordered, so comment ordering arbitrates:

1. Pre-check: issue open, `status:ready`, zero assignees. Fail fast otherwise.
2. Post a claim comment: `CLAIM <actor> <run-id> <timestamp>`.
3. Re-read all `CLAIM` comments. Earliest *live* wins (a claim voided by a later `RECLAIMED` or a matching `CLAIM-WITHDRAWN` is skipped — `lib/claim-winner.jq`): apply assignee, `status:claimed`, `claim:agent`, remove `status:ready`. Loser posts `CLAIM-WITHDRAWN` and exits nonzero.
3b. Orphan reap: a claimant that dies between step 2 and converting its win to `status:claimed` leaves a `CLAIM` with neither a withdrawal nor a reclaim, so it stays the earliest live claim forever and poison-pills the lock. A live winner converts within seconds, so if we lost but the issue is *still* `status:ready` with zero assignees and the blocking claim is older than the grace window (`CLAIM_GRACE_SECONDS`, default 90s — `lib/orphan-claims.jq`), it never converted: withdraw it on its behalf via `CLAIM-WITHDRAWN` (the ledger's own stand-down path) and re-arbitrate. This clears the orphan in-band, with no dependence on the 4h/`claim:agent` staleness path in `task-queue.sh --fix`.
4. Belt-and-suspenders: the implementer re-verifies it is still the sole assignee before opening the PR.

Humans claiming via the UI never post `CLAIM` comments; step 1's assignee check is what protects their claim. The grace window in step 3b is comfortably longer than a live claimant's post→convert gap, so a genuine in-flight racer is never mistaken for an orphan.

### 7.3 Worktrees — `scripts/task-worktree.sh`

`git worktree add .worktrees/task-<n>-<slug> -b task/<n>-<slug> origin/$BASE_BRANCH`, then run `WORKTREE_SETUP_CMD` if set (install deps). `.worktrees/` is gitignored. `--cleanup <n>` removes the worktree and local branch after merge.

## 8. Concurrency and Conflict Strategy

* Worktree-per-task. Parallel implementers never share a checkout.
* **One in-flight task per `module:` label.** Module ownership is the primary merge-conflict avoidance; the ready-set ordering respects it.
* Rebase onto `origin/$BASE_BRANCH` before every push if behind.
* Merge conflicts are resolved by the patcher in the task worktree — never by force-pushing over review history.
* Default in-flight cap: 2 tasks (serial). Raise only after the loop has demonstrated clean cycles (pilot before scaling).

### 8.1 Union merge driver for append-only registration files (optional)

Many codebases have a few **central registration files** that every new module touches by appending one line — a route table, a DI container, a plugin/module index, a package `__init__`, a service registry. Two module PRs in flight always collide there as benign "both sides appended a line" conflicts, forcing manual rebases. If your repo has such hotspots, this pattern dissolves them:

* Mark those files `merge=union` in `.gitattributes`. On merge/rebase git keeps **both** sides' added lines automatically instead of emitting conflict markers — resolving the append-collision at the git layer with no runtime or architecture change.
* Keep union output valid by holding those files in **union-friendly shape**: one import/entry per line, sorted, so a formatter can deterministically re-sort and dedupe. Module PRs must append in that shape.
* **Union is line-dumb.** It can misorder lines (a middle insert may land out of order) or duplicate them (two branches adding the identical line yield two copies), and it never detects semantic conflicts. So the gate (`GATE_CMD`) remains the correctness backstop: a formatter re-sorts and dedupes, and a broken assembly fails the gate before review.
* Union is complementary, not a cure-all: shrink the collision surface where you can (single dispatch points, one handler), and let the orchestrator auto-rebase (§8.2) handle the non-append conflicts union cannot.

### 8.2 Orchestrator auto-rebase for approved-but-conflicting PRs

* Module ownership and the union driver (§8.1) prevent most collisions, but a PR that was already **approved** can still go `CONFLICTING` when a sibling merges ahead of it — a non-append edit the union driver cannot auto-resolve. Such a PR falls through the loop: it is out of the review cycle (already approved) yet not mergeable, so absent intervention it stalls until a human hand-dispatches a rebase.
* The orchestrator tick closes the gap. **Ordered before the "Start" step** (`delivery-tick` step 3), it detects open agent PRs whose linked issue is `status:approved` and whose `gh pr view <pr> --json mergeable,mergeStateStatus` is non-`MERGEABLE` (`mergeStateStatus: DIRTY`), and dispatches a **rebase-only** `patch-task` as a first-class, state-advancing action.
* The rebase-only patch is mechanical: rebase onto `origin/$BASE_BRANCH`, resolve conflicts in the worktree, re-run the gate, and push with `--force-with-lease` **only as the rebase requires** — never a plain force over review history. It **preserves `status:approved`** (the approval still stands after a mechanical rebase; the PR is not sent back to review) and re-emerges immediately mergeable.
* **Optional auto-merge (`--auto-merge`, opt-in, off by default).** By default the now-mergeable approved PR is handed to a human — the merge authority the rest of this spec assumes. Run the loop with `--auto-merge` and the orchestrator performs that final step itself: as `delivery-tick` **step 1** (highest priority, before any dispatch) it squash-merges every agent PR whose linked issue is `status:approved` and that is `MERGEABLE` + `mergeStateStatus: CLEAN` + every check `SUCCESS` and not `needs-human`, then re-reconciles so dependents unblock. The gate stays the backstop — a bad assembly fails CI, so `mergeStateStatus` never reaches `CLEAN` and the PR cannot auto-merge. A conflicting approved PR is rebased (above) before it becomes eligible.
* It **skips PRs labeled `needs-human` or already at the max patch iteration** (a `Patch iteration: 3/3` comment), so a conflict that cannot be resolved mechanically escalates once rather than re-dispatching forever.
* This is defense-in-depth complementary to §8.1: the union driver dissolves append collisions at the git layer; auto-rebase recovers the non-append conflicts union cannot.

## 9. Failure Policy

* Max 3 patch iterations per PR, tracked in a PR comment (`Patch iteration: n/3`). At 3: label `needs-human`, comment a summary of the impasse, stop.
* An implementer that cannot satisfy a criterion (bad spec, missing dependency, environment problem) comments what it found, labels `needs-human`, releases its claim, and stops. It does not push partial work as if complete.
* **Encode-the-lesson rule.** When a failure was caused by the harness — ambiguous acceptance criteria, a missing gate check, a template gap — the fix must include a follow-up `module:infra` task to repair the harness, not just the instance.

## 10. Provenance

* Issues and PRs carry `agent-authored` or `human-authored` labels.
* PR bodies follow the template: `Closes #N`; summary; the issue's acceptance criteria as a checklist, each with evidence (the command output line); gate status; provenance line (`Agent-authored (<model>)` or `Human-authored`).
* Agent commits carry a `Co-Authored-By` trailer identifying the model.
* Review verdicts are GitHub reviews (approve / request-changes), so review history is inspectable and cannot be overwritten.

## 11. Verification and Gates

Three enforcement points, one definition:

* **`GATE_CMD`** (from `.claude/delivery.conf`; default `bash scripts/check.sh`) is the gate — one command that exits 0 iff the repo is correct, and the single definition of "correct." The implementer, patcher, and reviewer all run it. Keep it fast enough to run on every change and honest enough that green means mergeable.
* Git hooks (optional, the consumer repo's own): hygiene/format at pre-commit on changed files; the gate at pre-push. Never bypassed — `--no-verify` is banned.
* CI runs the same gate on every PR. **A PR without a green check is unreviewable** — reviewers reject on sight.

Acceptance criteria are executed, not trusted: the reviewer runs every criterion itself in a clean checkout.

## 12. Day-1 Topology and Upgrade Path

Day 1: a single local Claude Code orchestrator session runs `/loop` (dynamic self-pacing) with `delivery-tick`. Implementers and reviewers run as subagents; implementers in worktrees. Humans interact purely through GitHub. Operational detail — pre-flight checks, free-run bounds, throughput, troubleshooting — lives in [`delivery_runbook.md`](delivery_runbook.md).

Because all durable state lives in GitHub and all mechanics live in `scripts/`, the upgrade path is mechanical, not architectural:

* Event-driven: GitHub Actions triggered on `issues: labeled status:ready` / `pull_request_review submitted` invoking the same skills.
* Scheduled: a `/schedule` cloud routine running `delivery-tick` on a cadence.
* Parallel fan-out: worktree-per-task isolation means concurrent dispatch is a config change, gated on demonstrated clean cycles. Realized by `delivery-tick --parallel N`: the same orchestrator tick plans up to N independent actions from GitHub (at most one action per PR, one in-flight task per module) and dispatches them concurrently, waiting for the whole batch before the tick ends. Because the tick is synchronous, `/loop /delivery-tick --parallel N` can never overlap two batches — and coordination stays in Issues/PRs, so it remains crash-recoverable (runbook §3 Level 3, §9).

## 13. Open Questions

1. When to enable branch protection with required checks (adds friction for a single human merger today).
2. When reviewer approval becomes a required GitHub review rather than a label convention. Until then, a dedicated bot account/token lets reviewers post formal approve/request-changes reviews; without it, all agents run under one account and the verdict of record is a comment-form review plus the `status:*` label (§13.2, runbook §7).
3. Claiming etiquette once multiple humans share the queue.
4. Whether `delivery-tick` should auto-dispatch decomposition when the ready queue drains below a threshold.
5. Whether merged-PR retrospectives should periodically mine `needs-human` escalations for harness improvements (batch encode-the-lesson).

### 13.2 Single-account review fallback

When every agent runs under the repo owner's GitHub account, GitHub rejects a formal `--approve`/`--request-changes` on that owner's own PR. The reviewer falls back to a **comment-form review** (`gh pr review --comment --body "…" <pr>`) and the `status:approved` / `status:changes-requested` label carries the verdict of record. The human merge is the real approval gate. A dedicated bot account/token for reviewers restores formal reviews (§13 Q2).

## 14. Summary

Specs decompose into dependency-ordered GitHub Issues with command-shaped acceptance criteria. An orchestrator loop ticks one state transition at a time (or one bounded batch of independent transitions, with `--parallel N` — §12): claim ready work into worktrees, implement to criteria, gate everything through one shared command, adversarially review with independent contexts, patch within bounds, and hand every merge to a human (or opt into auto-merge). Scripts are deterministic; agents supply only judgment; GitHub remembers everything.
