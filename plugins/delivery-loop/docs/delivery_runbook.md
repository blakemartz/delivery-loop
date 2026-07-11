# Agentic Delivery Runbook (v0.1)

The **operator's manual** for the delivery system specified in
[`agentic_delivery_spec.md`](agentic_delivery_spec.md). The spec says what the
system *is*; this says how a human *runs* it — day-to-day operation, and the
playbook for free runs (unattended looping dev cycles), which is the end state
the system is built toward. The patterns and failure modes here were hardened in
live free runs before being generalized into this plugin.

Skills are namespaced under the plugin, e.g. `/delivery-loop:delivery-tick`. This
runbook writes them that way.

---

## 1. What the human owns (and nothing else)

The system is designed so exactly five things require a person:

1. **Pinning and nodding on specs.** `/delivery-loop:author-spec` presents design
   forks as explicit decision sets and the finished draft for a nod before any PR
   exists (spec §3.7); normative text is never written over an unpinned fork.
2. **Approving backlogs.** `/delivery-loop:decompose` is dry-run by default;
   issues are only created after you approve the printed table (`--create`).
3. **Merging.** Every PR — unless you opt into `--auto-merge` (§6) or grant an
   equivalent explicit standing authorization. Agents stop at `status:approved`;
   your merge queue is `gh pr list --label agent-authored` filtered to approved
   issues, or the "approved, awaiting human merge" bucket of
   `/delivery-loop:task-status`.
4. **Triaging `needs-human`.** Patch budget exhausted, blocked implementers,
   reviewer/patcher deadlocks. The loop *never* acts on these; they wait for you.
5. **Deciding to free-run, and for how long.** The loop has no opinion about
   whether it should be running.

Everything else — claiming, implementing, gating, reviewing, patching, label
reconciliation, stale-claim reclamation — is the loop's job. If you find
yourself doing one of those by hand, either you're debugging or the harness
has a gap; if the latter, file a `module:infra` task (encode the lesson).

## 2. One-time setup per repo

Install the plugin (once, user or project scope), then bootstrap the repo:

```
/delivery-loop:init        # creates labels, scaffolds .claude/delivery.conf, gitignores .worktrees/
```

Then **edit `.claude/delivery.conf`** — at minimum point `GATE_CMD` at your
repo's check command, and set `WORKTREE_SETUP_CMD` if a fresh worktree needs a
dependency install.

Then seed the other two seams the loop hangs on: run
`/delivery-loop:author-styleguides` to draft the conventions in
`STYLEGUIDES_DIR` (you ratify them; implementers follow them, reviewers enforce
them), and — if nothing matches `SPEC_SOURCES` yet —
`/delivery-loop:author-spec` to author the first spec.

Recommended GitHub settings (run yourself; outward-facing):

```bash
gh auth login   # repo scope
gh repo edit --enable-squash-merge --enable-merge-commit=false \
             --enable-rebase-merge=false --delete-branch-on-merge
```

If your harness gates tool permissions, ensure agents may post the comment-form
review (see §7) and run the gate. Nothing else to configure.

## 3. Operating modes

Run them in this order of increasing autonomy. Do not skip levels with a fresh
backlog — each level is the pilot for the next (pilot-before-scaling).

### Level 0 — one action at a time (debugging / learning the system)

| You want | Run |
|---|---|
| See the board | `/delivery-loop:task-status` (add `--reclaim` to also reconcile labels / free stale claims) |
| Implement one task | `/delivery-loop:next-task <n>` |
| Deliver one task end-to-end | `/delivery-loop:deliver-task <n>` — implement → fresh review → bounded patch loop → hand to a human |
| Review a PR | `/delivery-loop:review-task <pr>` — always a **fresh session/agent**, never the one that implemented |
| Answer review findings | `/delivery-loop:patch-task <pr>` |
| Author a spec for a subsystem | `/delivery-loop:author-spec <subsystem>` — pin → ground → draft → docs-review → merge → hand to decompose |
| Grow the backlog | `/delivery-loop:decompose <scope>` → read the table → `--create` |

### Level 1 — supervised loop (default working mode)

`/delivery-loop:delivery-tick` once, read what it did, repeat. One state
transition per tick, so you always understand the board. This is the mode for the
first few tasks of any new epic or after any harness change.

### Level 2 — free run

`/loop /delivery-loop:delivery-tick` in a dedicated session. See §5.

### Level 3 — parallel loop

`/loop /delivery-loop:delivery-tick --parallel 3` in a dedicated session, once
serial free runs are boringly reliable. Same tick, same loop — but each tick
plans up to N independent actions (at most one per PR, one start per `module:`,
in-flight ≤ N), dispatches them concurrently, and waits for the whole batch
before the tick ends. That synchronous barrier is why it stays loop-safe: two
batches can never overlap, and every tick replans from GitHub, so your merges and
new issues are picked up each interval. Still one orchestrator — never run a
second delivery session alongside it. See §9 step 1.

## 4. Decomposition — how you steer the system

`/delivery-loop:decompose` is the compiler from specs to executable backlog, and
backlog approval is the **only moment where product intent enters the loop** —
every guarantee downstream inherits from what you approve here. The loop has no
planner: the dependency DAG you approve *is* the plan.

### 4.1 What it does

Reads the spec sources (`SPEC_SOURCES`), the relevant styleguides
(`STYLEGUIDES_DIR`), and the existing backlog (never proposes duplicates).
Proposes epics (≈ major spec sections or modules) and child tasks — each with
exactly one `module:`, a size, `Depends-on:` edges following natural build order
(scaffold → models → repositories → services → endpoints → wiring), and
command-shaped acceptance criteria. Prints the table and **stops**. Only after
your approval does `--create` file the issues (epics first, then tasks in
dependency order so `#N` references resolve), then promote the dep-free ones
to `status:ready`.

### 4.2 Why each hard rule exists

| Rule | What it buys |
|---|---|
| Every criterion is a command (exit 0) or checkable artifact | The criteria ARE the review contract — reviewers execute them verbatim. A vague criterion is unenforceable and produces plausible-looking merges. |
| Nothing bigger than `size:M` | A task must fit one agent context. `size:L` is only legal as an explicit "split me" placeholder the queue refuses to serve. |
| Exactly one `module:` per task | The module is the concurrency unit — it's what lets parallel worktrees never conflict. |
| `Depends-on:` edges resolve to real issues | The DAG is the schedule; `task-queue.sh` derives the ready set from it mechanically. |

Worked examples of good vs. bad criteria: `agentic_delivery_spec.md` §4.1. When a
dry-run comes back with mushy criteria, point the decomposer there — and if the
criteria *can't* be made command-shaped, the fix is a missing spec, not a better
sentence.

### 4.3 Approving a dry-run (this is planning, not proofreading)

For each proposed task ask three questions:

1. **Could I verify every criterion myself by pasting the command?** If a
   criterion needs interpretation, the reviewer will interpret it too —
   differently. Tighten it or strike it.
2. **Is this one sitting of work in one module?** If you can't picture the PR,
   it's two tasks.
3. **Is the dependency order how I'd actually build it?** Missing edges cause
   rebase pain; fake edges serialize work that could run in parallel.

Trim freely — a smaller, sharper backlog beats a complete, mushy one.

### 4.4 Cadence

Decompose **just-in-time, one scope at a time** (`/delivery-loop:decompose
<scope>`, e.g. "the ingestion pipeline: sources + fetch"), not the whole roadmap.
Small batches keep your steering current; a deep pre-built backlog goes stale the
moment an early task teaches you something. The natural trigger is the tick
reporting "queue empty".

### 4.5 Why auto-decompose is deliberately last

Spec §13 Q4 and step 4 of the scaling ladder (§9). Automating decomposition
means the system chooses its own work — you only grant that after backlog
quality is boringly consistent under your review. The safe interim: let the
tick auto-dispatch a *dry-run* when the queue drains, while `--create` stays
human-gated.

## 5. The free-run playbook

### 5.1 Pre-flight checklist

Do not start a free run unless all of these hold:

- [ ] **Backlog is command-shaped.** Spot-check the ready queue: every
      acceptance criterion is a command or checkable artifact. Vague criteria
      are how loops burn tokens producing plausible garbage.
- [ ] **The board is clean.** `/delivery-loop:task-status --reclaim` first; zero
      unexplained `status:claimed`, no stale worktrees (`git worktree list`).
- [ ] **The gate is honest.** `GATE_CMD` passes on the base branch, and CI is
      green. A free run on a red base branch multiplies the mess.
- [ ] **You have merge bandwidth.** See §6 — an unattended loop with an absent
      merger stalls by design (unless `--auto-merge`); that's a feature, but know
      it going in.
- [ ] **One pilot cycle completed at Level 0/1** since the last harness change
      (skills, scripts, config, gate). Harness changes reset trust.

### 5.2 Starting

```
/loop /delivery-loop:delivery-tick
```

Dynamic (self-paced) is the right default: the model stretches the interval
when idle and tightens it when PRs are moving. If you prefer a fixed cadence,
10–15 minutes matches the pace of one implement/review cycle (~10 min each);
tighter than ~5 minutes buys nothing because ticks serialize on real work. At
Level 3 the same playbook applies with `/loop /delivery-loop:delivery-tick
--parallel 3`.

### 5.3 What bounds a free run (the safety model)

You are not trusting the model to behave; you are trusting structure:

- **One state-advancing action per tick** — the loop cannot cascade. (At
  Level 3, one *bounded batch* of ≤ N independent actions per tick — still a
  single dispatch the tick waits out; §3.)
- **In-flight cap (2 serial / N parallel) and one-task-per-module** — bounded
  concurrency, no worktree pile-ups.
- **Patch budget (3)** — no infinite implementer/reviewer arguments; losers
  escalate to `needs-human` and *stop*.
- **Every merge is yours by default** — nothing reaches the base branch
  unattended unless you opt into `--auto-merge` (§6), and even then only a
  fully-approved, mergeable, green PR lands (a bad assembly fails CI and cannot
  auto-merge). The worst case of a bad free run is noisy PRs and spent tokens,
  not a broken base branch.
- **Gates can't be bypassed** — `--no-verify` is banned and any pre-push hook,
  CI, and reviewers all run the same `GATE_CMD`.
- **Reviews are execution, not vibes** — a criterion violation with green CI
  still gets blocked, because reviewers run every criterion in a clean checkout.

### 5.4 While it runs

Check in on the cadence of your merge bandwidth, not the loop's. Each glance:
read the last tick report (each ends with the one-line "next action"), merge
what's approved, triage anything `needs-human`. That's it. Resist fixing
in-flight branches by hand — comment on the PR instead and let
`/delivery-loop:patch-task` answer; hand edits to agent branches break the
provenance the reviews rely on.

### 5.5 Stopping and cleaning up

Interrupt the `/loop` (or just close the session — all durable state is in
GitHub, so a killed loop loses nothing). Then:

```
/delivery-loop:task-status --reclaim          # free anything the dead loop had claimed
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-worktree.sh" --cleanup <n>   # for each merged task
```

A crashed or interrupted loop needs no other recovery — the next tick's
reconcile is the recovery.

## 6. Throughput physics (read before your first overnight run)

**Your merge cadence is the loop's throttle.** Approved-but-unmerged PRs still
count against the in-flight cap and hold their module lock, so an unattended
overnight run with no human merging will do roughly *cap* tasks' worth of work
and then idle, reporting "waiting on human merges" every tick. This is by
design (unmerged work is unconfirmed work), but it means:

- Free runs produce at most ~(in-flight cap) reviewed PRs per merge session.
- The natural rhythm is: free-run → merge batch → free-run, not a week-long run.
- Raising the cap (spec §8) is only worth it if you also merge more often.

**`--auto-merge` lifts this throttle.** Run the loop as
`/loop /delivery-loop:delivery-tick --parallel N --auto-merge` (opt-in, off by
default) and the orchestrator squash-merges every approved + mergeable + green PR
itself at the top of each tick, then reconciles so dependents unblock — an
unattended run keeps flowing instead of idling on "waiting on human merges". The
trade is deliberate: an unmerged approved PR is no longer held as unconfirmed, so
enable it only once your review pass is trustworthy. The CI gate stays the hard
backstop — a red gate leaves the PR non-`CLEAN`, so it cannot auto-merge. Without
the flag, your merge cadence is the throttle exactly as above.

Dependency chains compound this: `#N+1` can't even become ready until you merge
`#N`. Deep chains + absent merger = an idle loop, correctly.

## 7. Known constraints and encoded lessons

Kept here so they don't get re-learned:

- **Single-account reviews.** If all agents run under one GitHub account (the
  repo owner's), GitHub rejects formal approve/request-changes on agent PRs. The
  verdict of record is a *comment-form review* (`gh pr review --comment
  --body "..." <pr>` — allowlist exactly this shape if your harness gates
  permissions) plus the `status:approved`/`status:changes-requested` label. The
  human merge is the real approval. Upgrade path: a dedicated bot account/token
  for reviewers restores formal reviews (spec §13.2).
- **An unposted review did not happen.** Reviewers must verify their verdict
  landed on the PR (`gh pr view --json reviews`) before reporting; a verdict that
  doesn't carry a posted review is a failure, not an outcome. (A review can be
  *executed* while its *post* is denied — never trust the self-report.)
- **The permission layer is part of the system.** If your harness gates tool
  use, it will (correctly) block things like a gate-disabling push disguised as a
  "chore" or a positive self-review. If an agent reports a denied action, treat
  it as a design signal: either the action was wrong, or it needs an explicit,
  narrow allowlist entry a human approves.
- **Green CI is not "criteria met."** CI runs `GATE_CMD`; criteria can be broader
  (e.g. wiring the gate itself doesn't check). Only reviewer execution closes
  that gap.

## 8. Troubleshooting

| Symptom | Meaning | Action |
|---|---|---|
| Tick reports idle, queue empty | Backlog drained | `/delivery-loop:decompose <next scope>`, approve, `--create` |
| Tick reports idle, PRs approved | You're the bottleneck | Merge, then `/delivery-loop:task-status --reclaim` (or enable `--auto-merge`) |
| Issue stuck `status:claimed`, no PR, >4h | Dead agent | `--reclaim` auto-frees it (agent claims only) |
| Human-assigned issue idle >72h | Stalled colleague | The loop pings once; talking to them is on you |
| `needs-human` anything | Escalation by design | Read the latest PR/issue comment; decide; relabel |
| Same task fails review 3× | Criteria ambiguous or task too big | Split the task / rewrite criteria; file the harness lesson |
| Labels look wrong vs reality | Drift | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh" --fix`; ground truth: closed issue > merged PR > open PR > labels |

## 9. Scaling up (when free runs are boringly reliable)

In order, each gated on clean cycles at the previous level (spec §12):

1. Raise the in-flight cap 2 → 3–4 and parallelize dispatch across ready
   tasks — config, not architecture. Realized by
   **`/delivery-loop:delivery-tick --parallel N`** (default 3): each tick plans
   up to N independent actions from GitHub (implement / review / patch / rebase)
   and dispatches them concurrently, awaiting the whole batch before the tick
   ends (Level 3, §3).
2. Bot account for reviewers → formal GitHub reviews → branch protection with
   required review + required checks.
3. Move the tick off your laptop: `/schedule` cloud routine or GitHub Actions
   on `issues: labeled status:ready` / review events, invoking the same skills.
4. Auto-decompose when the ready queue drains below a threshold (spec §13 Q4) —
   only after you trust backlog quality unsupervised, since backlog approval
   is currently your strongest steering input.
