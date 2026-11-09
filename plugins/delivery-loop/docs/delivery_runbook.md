# Agentic Delivery Runbook (v0.2)

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
   equivalent explicit standing authorization — and **every promotion PR,
   always** (§11). Agents stop at `approved`; your merge queue is the
   "approved, awaiting human merge" bucket of `/delivery-loop:task-status`.
4. **Triaging `needs-human`.** Patch budget exhausted, blocked implementers,
   reviewer/patcher deadlocks. The loop *never* acts on these; they wait for you.
5. **Deciding to free-run, and for how long.** The loop has no opinion about
   whether it should be running.

Everything else — claiming, implementing, gating, reviewing, patching, status
reconciliation, stale-claim reclamation, promotion PRs — is the loop's job. If you find
yourself doing one of those by hand, either you're debugging or the harness
has a gap; if the latter, file a `module:infra` task (encode the lesson).

## 2. One-time setup per repo

Install the plugin (once, user or project scope), then bootstrap the repo:

```
/delivery-loop:init        # picks the seams, scaffolds .claude/delivery.conf, seeds the gate,
                           # gitignores .worktrees/, creates labels (github) or STATE_DIR (local)
```

`init` first settles the two seams (§10): `GRAPH_BACKEND` (`github` = GitHub
Issues, `local` = JSON files on this machine) and `FORGE` (`github`, `gitlab`,
`gitea`). Without an existing `.claude/delivery.conf` it detects `FORGE` from the
`origin` host and defaults the backend to `github` on GitHub and `local`
elsewhere; override by passing them in the environment
(`GRAPH_BACKEND=local FORGE=gitlab bash …/delivery-init.sh`). A gitlab or gitea
forge needs its token exported first (§10.3). It checks its requirements: jq;
git ≥ 2.31 for the local backend; an authenticated `gh` only when a seam is
github, and gh ≥ 2.94 for the github backend.

Then **edit `.claude/delivery.conf`** — at minimum point `GATE_CMD` at your
repo's check command, and set `WORKTREE_SETUP_CMD` if a fresh worktree needs a
dependency install. `bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-config.sh"`
prints the resolved values; `… delivery-config.sh --check` validates them
(including the jq on `PATH`: jq ≥ 1.7, never 1.8.2).

Then seed the other two seams the loop hangs on: run
`/delivery-loop:author-styleguides` to draft the conventions in
`STYLEGUIDES_DIR` (you ratify them; implementers follow them, reviewers enforce
them), and — if nothing matches `SPEC_SOURCES` yet —
`/delivery-loop:author-spec` to author the first spec.

Recommended repo merge settings (run yourself; outward-facing). **Keep merge
commits enabled**: task PRs merge with `TASK_MERGE_METHOD` (default `squash`),
but promotion PRs merge with `PROMOTE_MERGE_METHOD` (default `merge`, which keeps
the release branch's ancestry), and a forge refuses a merge style the repo
disallows. On GitHub:

```bash
gh auth login   # repo scope
gh repo edit --enable-squash-merge --enable-merge-commit \
             --enable-rebase-merge=false --delete-branch-on-merge
```

On GitLab: Settings > Merge requests, merge method "Merge commit" (the
project-level method decides what a non-squash merge produces), squash commits
"Allow", delete the source branch by default. On Gitea/Forgejo: Repository
settings > Pull Requests, enable "Create merge commit" and "Create squash commit"
(a disallowed style is refused with 405), and delete the PR branch after merge by
default. `init` prints the same advice for your forge. A repo set up from the
v0.1.4 advice, which disabled merge commits, must turn them back on before its
first promotion.

If your harness gates tool permissions, ensure agents may post comment-form
verdicts through `forge.sh pr-review` (see §7) and run the gate. Nothing else to
configure.

## 3. Operating modes

Run them in this order of increasing autonomy. Do not skip levels with a fresh
backlog — each level is the pilot for the next (pilot-before-scaling).

### Level 0 — one action at a time (debugging / learning the system)

| You want | Run |
|---|---|
| See the board | `/delivery-loop:task-status` (add `--reclaim` to also reconcile / free stale claims, `--graph` for a Mermaid chart of the open graph) |
| Implement one task | `/delivery-loop:next-task <id>` (a node id: an issue number on github, a slug on local) |
| Deliver one task end-to-end | `/delivery-loop:deliver-task <id>` — implement → fresh review → bounded patch loop → hand to a human |
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
batches can never overlap, and every tick replans from the graph, so your merges
and new tasks are picked up each interval. Still one orchestrator — never run a
second delivery session alongside it. See §9 step 1.

## 4. Decomposition — how you steer the system

`/delivery-loop:decompose` is the compiler from specs to executable backlog, and
backlog approval is the **only moment where product intent enters the loop** —
every guarantee downstream inherits from what you approve here. The loop has no
planner: the dependency DAG you approve *is* the plan.

### 4.1 What it does

Reads the spec sources (`SPEC_SOURCES`), the relevant styleguides
(`STYLEGUIDES_DIR`), and the existing backlog (`graph.sh list` and the plan files
in `PLANS_DIR`; never proposes duplicates). Writes a **plan file**
(`PLANS_DIR/<plan>.plan.json`, spec §18): epics (≈ major spec sections or
modules) and child tasks — each with exactly one module, a size, deps following
natural build order (scaffold → models → repositories → services → endpoints →
wiring), each dep naming its seam (`via`), and command-shaped acceptance
criteria. It lints and renders the plan (`plan.sh lint` / `render`), prints the
table plus a Mermaid graph, and **stops**, leaving the file uncommitted. Only
after your approval does `--create` commit the plan file and run `plan.sh apply`,
which creates the nodes (epics, then tasks in dependency order, then the plan's
promote node if it has a `promote_to`) and reconciles, promoting the dep-free
ones to `ready`. Re-running apply is safe: it creates only what is missing and
reports `drift:` for a node that differs from the plan without overwriting it.

### 4.2 Why each hard rule exists

| Rule | What it buys |
|---|---|
| Every criterion is a command (exit 0) or checkable artifact | The criteria ARE the review contract — reviewers execute them verbatim. A vague criterion is unenforceable and produces plausible-looking merges. |
| Nothing bigger than `size:M` | A task must fit one agent context. `size:L` is only legal as an explicit "split me" placeholder the queue refuses to serve. |
| Exactly one `module:` per task | The module is the concurrency unit — it's what lets parallel worktrees never conflict. |
| Deps resolve to real nodes, each with a `via` | The DAG is the schedule; `graph.sh ready` derives the ready set from it mechanically. `plan.sh lint` refuses an unresolved dep or a cycle. |

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
      unexplained `claimed` nodes, no stale worktrees (`git worktree list`).
- [ ] **The gate is honest.** `GATE_CMD` passes on every target branch in play
      (`BASE_BRANCH`, and any plan's `target_branch`), and CI is green. A free
      run on a red base branch multiplies the mess.
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
  fully-approved, mergeable, green PR lands, after `tick-merge.sh` re-runs the
  gate on the merged result. A promotion PR is never auto-merged. The worst case
  of a bad free run is noisy PRs and spent tokens, not a broken base branch.
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

Interrupt the `/loop` (or just close the session — all durable state is in the
graph backend and on the forge, so a killed loop loses nothing). Then:

```
/delivery-loop:task-status --reclaim          # free anything the dead loop had claimed
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-worktree.sh" --cleanup <id>   # for each merged task
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
default) and the orchestrator merges every approved + mergeable + green task PR
itself at the top of each tick (`tick-merge.sh`, with `TASK_MERGE_METHOD`), then
reconciles so dependents unblock — an unattended run keeps flowing instead of
idling on "waiting on human merges". The trade is deliberate: an unmerged
approved PR is no longer held as unconfirmed, so enable it only once your review
pass is trustworthy. The gate stays the hard backstop twice over: a red CI check
keeps the PR from being planned for a merge, and `tick-merge.sh` re-runs
`GATE_CMD` on the merged result (base + head) in a fresh worktree before merging,
so two PRs green alone but red together are caught. A red or conflicting merged
result becomes a rebase action, or a `needs-human` escalation at the patch
budget. Promotion PRs are never auto-merged. Without the flag, your merge cadence
is the throttle exactly as above.

Dependency chains compound this: a dependent can't even become ready until you
merge its dep. Deep chains + absent merger = an idle loop, correctly.

## 7. Known constraints and encoded lessons

Kept here so they don't get re-learned:

- **Single-account reviews.** If all agents run under one forge account (the
  repo owner's), the forge rejects formal approve/request-changes on agent PRs
  (GitHub rejects it, Gitea/Forgejo answer 422, GitLab blocks author approval
  and has no request-changes endpoint at all). `forge.sh pr-review` then posts a
  *comment-form verdict*: the same body as a comment (a GitLab note), headed
  `## Adversarial review — verdict: <VERDICT>` and ending in `Reviewed-Head:
  <sha>`. The node status (`approved` / `changes-requested`) is the verdict of
  record; the human merge is the real approval. Allowlist `forge.sh pr-review`
  if your harness gates permissions. Upgrade path: a reviewer token (§10.3)
  restores formal reviews (spec §13.2).
- **An unposted review did not happen.** Reviewers must verify their verdict
  landed (`forge.sh pr-reviews <pr>` holds an entry with `commit == <head_sha>`)
  before recording it; a verdict that doesn't carry a posted review is a
  failure, not an outcome. (A review can be *executed* while its *post* is
  denied — never trust the self-report.) `pr-reviews` returns formal reviews
  plus every comment whose first non-blank line is a `## … verdict:` heading.
- **Docs-review verdicts.** `/delivery-loop:author-spec`'s reviewer posts a
  `comment` verdict whose first line is plain text, `Docs-review verdict:
  APPROVE` or `Docs-review verdict: REQUEST_CHANGES`. On github and gitea it
  lands as a formal COMMENT review with that body (a comment review is allowed
  on one's own PR); only on gitlab, where it is a note, does the adapter add
  the `## Adversarial review — verdict: COMMENT` heading itself. Never open such
  a body with a `## … verdict:` heading of its own: the gitlab adapter refuses a
  `comment` whose heading names another verdict.
- **The permission layer is part of the system.** If your harness gates tool
  use, it will (correctly) block things like a gate-disabling push disguised as a
  "chore" or a positive self-review. If an agent reports a denied action, treat
  it as a design signal: either the action was wrong, or it needs an explicit,
  narrow allowlist entry a human approves.
- **Green CI is not "criteria met."** CI runs `GATE_CMD`; criteria can be broader
  (e.g. wiring the gate itself doesn't check). Only reviewer execution closes
  that gap.
- **Merge, never rebase; never force-push.** Implementers and patchers catch up
  with a moved target branch by merging `origin/<target_branch>` into the task
  branch and pushing plainly. Review history and verdicts pinned to earlier
  heads stay intact. Branch protection that blocks force-pushes costs the loop
  nothing.
- **Don't edit the top of an issue's machine trailer block (github).** A task
  issue's body ends with a trailer block that `create` writes (`Delivery-Target:`,
  `Delivery-Plan:`, `Delivery-Promote-To:`, then any `Depends-on:` lines).
  Appending to the body is safe — prose, checklist items, a new paragraph below
  the block. *Editing the top* of the block is not: deleting the blank line
  between the contract and the block, or typing a line just above its first
  `Delivery-*` key, makes it no longer a trailer block, so every key falls back
  to its default (the target to `BASE_BRANCH`, the plan link to none, so a
  re-apply would duplicate the node). `graph.sh show` warns on stderr about each
  stray key line. Tell humans: append, never touch the block, and never start a
  paragraph you add below it with a `Key: value` line.
- **A node's target is pinned when it is created.** github `create` writes
  `Delivery-Target:` with the `BASE_BRANCH` in force at creation time (a plan's
  `target_branch` when it names one). Changing `BASE_BRANCH` later retargets only
  nodes created afterwards; existing nodes keep their branch. A node with no
  `Delivery-Target:` line (created by v0.1.4, or whose trailer block was
  broken) is not pinned: it follows whatever `BASE_BRANCH` is in force.
- **jq ≥ 1.7, excluding 1.8.2.** jq 1.8.2 mis-links nested module includes
  (upstream jqlang/jq#3597) and crashes most of the engine; use 1.8.1, or 1.8.3
  or later. Every entry point's config check refuses jq < 1.7 and exactly 1.8.2
  (`1.8.2-dirty` included). A version string that does not parse as a release is
  accepted, so Alpine's jq 1.6 build, which reports `jq-master-…`, slips through:
  upgrade it yourself. `delivery-init.sh`'s own preflight only checks jq ≥ 1.6,
  so the first `graph.sh`/`forge.sh` call is where an unsupported jq is refused.
  Deferred follow-up (upstream): once jq 1.8.3 ships, or if 1.8.2 ever must be
  supported, list full include chains (leaves last) at every nested-module call
  site and gate a run under jq 1.8.x that calls into each module.
- **Long-running scripts and signals.** `tick-merge.sh` and `promote.sh` run the
  gate, which can take minutes; run them in the foreground with a long timeout.
  A signal stops them with exit 128+n and stops a running gate. Edge cases:
  - *tick-merge, self-healing window.* A signal to the script's PID that arrives
    once the merge request is out is held until the merge is settled. A signal to
    the whole process group (Ctrl-C, a terminal hangup, `kill -- -<pgid>`) also
    kills the forge re-read in flight, so the script can exit before printing
    `merged`. The task then stays `approved` until the next tick's reconcile
    closes it from the merged PR. Nothing is lost; the next tick heals it.
  - *promote, PR reporting.* "An opened PR is still reported on stdout" holds
    only for a signal sent to the script's PID; a process-group signal can kill
    the forge call that would report it.
  - *promote, forge unreachable.* With the forge unreachable, a group signal
    after the promotion PR is recorded cannot confirm the PR (`forge.sh pr-find`
    fails), so the claim is released while the PR is open. The next `promote.sh`
    run adopts the existing PR (head T into P) instead of opening another.
  - *SIGINT in the background.* A non-interactive shell without job control
    starts a background child (`tick-merge.sh … &`) with SIGINT ignored, and
    POSIX does not let the script trap it, so INT is a no-op there. Use TERM,
    or start it with job control (`set -m`).
- **Behavior changes from v0.1.4** (deliberate, listed so they don't surprise
  you):
  - A dep closed as not-planned or duplicate no longer satisfies readiness: the
    dependent stays blocked and reconcile warns. Close superseded deps as
    completed, or edit the edge.
  - Fetch ceilings fail loudly (exit 3, naming `LIST_LIMIT`) instead of silently
    truncating. Raise `LIST_LIMIT` when a repo outgrows it.
  - PRs link to tasks by the `Delivery-Task:` trailer, not by any `#N`
    mention.
  - A merged agent PR closes its task only when the PR's base is the task's
    `target_branch` (a promote node's: its `promote_to`), on any backend and
    whichever branch that is; a PR merged into another base leaves the task
    open. It acts once per (task, PR); a human reopen is respected, and only a
    newer merged PR closes the task again.
  - **Human PRs into a non-default base no longer close delivery tasks.** v0.1.4
    closed every issue named by a closing keyword in any merged PR into a
    non-default `BASE_BRANCH`; v0.2 acts only on agent PRs (the `agent-authored`
    label), one task per PR. Human PRs into the default branch are unaffected
    (GitHub closes them natively). For a human PR into a release or feature
    branch, close the task by hand or label the PR `agent-authored`.
  - Reclaiming a stale agent claim clears every `status:*` label (v0.1.4 left
    `status:ready` set), and the `fix:` stderr wording changed (prefix and
    stream are the same).
  - `claim-task.sh` refuses (exit 1, nothing written) a `needs-human` issue even
    when it is labelled `status:ready` with no assignee; v0.1.4 claimed it.
  - An issue labelled both `task` and `epic` is a task only.
  - `Depends-on:` counts only at line start (after indentation, a bullet, or
    `**`); a mention mid-line, in a checklist item, a code span, or a blockquote
    adds no edge.
  - An epic's children are one set for both the started flag and completion.
    v0.1.4 counted a broad `[Ee]pic #E` body mention for *started* but only
    `Part of epic #E` (plus the checklist) for *auto-close*. So an open
    unlabelled issue that says `Epic #9` (but not `Part of epic #9`) now keeps
    epic #9 from auto-closing where v0.1.4 would have closed it. This errs
    safe and leaves the ready set unaffected; edit or close that issue.
- **Mermaid output limitations** (`plan.sh render`, `task-status --graph`):
  - a C1 control character (U+0080–U+009F) right after the word `direction` in
    a title renders as a Windows-1252 glyph (cosmetic; the label stays safe);
  - Mermaid trims leading and trailing whitespace in edge labels and subgraph
    titles;
  - `task-status --graph` is assembled by the agent from `graph.sh list`
    through `plan-render.jq`'s `mermaid_text`; there is no engine render command
    for the live graph yet.

## 8. Troubleshooting

| Symptom | Meaning | Action |
|---|---|---|
| Tick reports idle, queue empty | Backlog drained | `/delivery-loop:decompose <next scope>`, approve, `--create` |
| Tick reports idle, PRs approved | You're the bottleneck | Merge, then `/delivery-loop:task-status --reclaim` (or enable `--auto-merge`) |
| Node stuck `claimed`, no PR, >4h | Dead agent | `--reclaim` auto-frees it (agent claims only) |
| Human-claimed node idle >72h | Stalled colleague | The loop pings once; talking to them is on you |
| `needs-human` anything | Escalation by design | Read the latest PR comment and node notes (`graph.sh show <id> --events`); decide; fix; `graph.sh flag <id> needs-human off` |
| Same task fails review 3× | Criteria ambiguous or task too big | Split the task / rewrite criteria; file the harness lesson |
| Status looks wrong vs reality | Drift | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph.sh" reconcile --fix`; ground truth: closed issue > merged PR > open PR > stored status |
| A script exits 1 with `config: …` | Invalid seam combination, missing token, or unsupported jq | Fix what the line names; `delivery-config.sh --check` re-validates |
| Exit 3, `graph-github: gh issue list returned <n> issues = LIST_LIMIT (<n>); refusing to truncate (raise LIST_LIMIT)` (a forge list: `forge-<forge>: … returned <n> items = LIST_LIMIT (<n>) …`; a github comment thread: `… has <n> comments >= LIST_LIMIT (<n>) …`) | A list hit the fetch ceiling (never truncated) | Raise `LIST_LIMIT` in `.claude/delivery.conf` |
| Exit 75 / "busy; retry" (local) | Another writer holds the store lock | Retry. A lock left by a dead process is broken automatically once older than `LOCK_STALE_SECONDS`; see §10.2 for an owner-less or crashed lock |
| Reconcile exit 4, "board changed" | The board moved under the plan | Re-run; the tick and `task-queue.sh` retry automatically |
| `drift: <id> <field>` from `plan.sh apply` | A node differs from its plan file | Decide which is right; apply never overwrites |
| `PROMOTE-GATE-RED: …` on a promote node | The target branch is red | Fix the target branch, then `graph.sh flag <id> needs-human off`; the next tick re-runs `promote.sh` |
| `MERGE-NEEDS-HUMAN: …` on a task | Its merged result is red or conflicting at the patch budget | Resolve by hand on the PR, then clear the flag |
| `tick-merge` refusal ending `verify it by hand` | The merge request went out and may have landed | Check the PR on the forge. Don't retry the merge; the next reconcile closes the task if it merged |
| Task stays `approved` after its PR merged | A merge whose report was interrupted (§7) | Nothing: the next tick's reconcile closes it |
| Task's PR merged into a release branch, task still open | Human-authored PR (no `agent-authored` label) | Close the task by hand, or label the PR `agent-authored` and reconcile |
| An issue's target or plan link reverted to defaults | The trailer block was edited (§7) | Restore the block as `create` wrote it (check the issue's edit history) |

## 9. Scaling up (when free runs are boringly reliable)

In order, each gated on clean cycles at the previous level (spec §12):

1. Raise the in-flight cap 2 → 3–4 and parallelize dispatch across ready
   tasks — config, not architecture. Realized by
   **`/delivery-loop:delivery-tick --parallel N`** (default 3): each tick plans
   up to N independent actions from the graph (implement / review / patch /
   rebase) and dispatches them concurrently, awaiting the whole batch before the
   tick ends (Level 3, §3).
2. Reviewer token → formal forge reviews (§10.3) → branch protection with
   required review + required checks.
3. Move the tick off your laptop: `/schedule` cloud routine or forge CI on board
   or review events, invoking the same skills (github backend: the local backend
   is single-machine, §10.2).
4. Auto-decompose when the ready queue drains below a threshold (spec §13 Q4) —
   only after you trust backlog quality unsupervised, since backlog approval
   is currently your strongest steering input.

## 10. Seams: graph backends and forges

Two keys in `.claude/delivery.conf` decide where state lives (spec §15, §16):
`GRAPH_BACKEND` (`github` | `local`) and `FORGE` (`github` | `gitlab` |
`gitea`). `GRAPH_BACKEND=github` requires `FORGE=github`; `local` works with any
forge. Every skill and script goes through `graph.sh` and `forge.sh`, so you can
inspect the same state by hand:

```bash
S="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$S/graph.sh" list | jq '.[] | {id, kind, status, needs_human}'
bash "$S/graph.sh" show <id> --format md     # the task contract
bash "$S/graph.sh" show <id> --events        # its notes (github: the comment thread)
bash "$S/forge.sh" pr-list --state open | jq '.[] | {number, task_id, checks, mergeable}'
```

### 10.1 github backend

The backlog is GitHub Issues, labelled `task` / `epic` / `promote`, `status:*`,
`module:*`, `size:*`, `claim:agent`, `needs-human`, and the authorship labels
(`init` creates them). Native blocked-by links and sub-issues need gh ≥ 2.94; an
older gh falls back to `Depends-on:` text edges with one warning per run. Humans
can work the board from the GitHub UI: self-assign to claim, close as not planned
to cancel, remove `needs-human` to clear the flag.

**Moving a v0.1.4 backlog to native links.** `graph.sh migrate` plans a native
blocked-by link for each legacy `Depends-on:` line of every open task and a
native parent from `Part of epic #E`, and leaves the text lines in place. It is a
**dry run by default** (each planned edit printed as a JSON line); only
`graph.sh migrate --apply` writes, and a second `--apply` plans nothing. Before
any write it refuses a plan that would exceed 50 blockers on one issue. Mind:
- run it only from a v0.2 install: it relies on line-start `Depends-on:` parsing,
  without which prose that quotes the convention would become a real edge;
- a `Part of epic #E` target is not verified to be an epic, so a mistyped number
  can produce a parent cycle that wedges `--apply`: read the dry run first;
- GitHub's 100-sub-issues-per-parent limit is not pre-checked by `migrate`
  (`plan.sh apply` does check it).

### 10.2 local backend

The graph lives in JSON files under `STATE_DIR` (empty = `<git-common-dir>/delivery`,
inside the clone's shared `.git`, so every worktree sees one store, it survives
branch switches, and it is never committed). Requires git ≥ 2.31. There is no
issue tracker: the forge's PRs, reviews and comments are the only remote state,
and a PR body carries the full task contract so reviewers on the forge can read
it.

- **Single machine.** There is no cross-machine sync in v0.2. Run one
  orchestrator against one clone; don't point two clones at copies of the
  store.
- **Working the board by hand.** `graph.sh claim <id> --human <name>`,
  `graph.sh release <id> <reason>`, `graph.sh flag <id> needs-human off`,
  `graph.sh transition <id> cancelled --human <name>`, `graph.sh comment <id>
  <text>`. New work arrives through plan files (`/delivery-loop:decompose`).
- **Lock.** Every write takes `STATE_DIR/lock/` (a `mkdir` lock with an owner
  line `host pid run epoch`), waiting up to `LOCK_WAIT_SECONDS` (environment,
  default 30) before exit 75. A lock whose owner is a dead process on this host
  and older than `LOCK_STALE_SECONDS` (default 120) is broken automatically,
  and journalled as `lock-broken`. A lock with no owner file, or a crashed break
  step (`lock.break.reap`), needs operator cleanup: once you are sure no process
  holds it, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/backends/graph-local.sh"
  unlock --force`.
- **Backup.** The store lives inside `.git`, so deleting the clone deletes the
  backlog. `graph.sh export > nodes-backup.json` dumps every node as JSON for
  inspection and as a record; it does not include the journal. For a restorable
  backup, copy the whole `STATE_DIR` (`store.json`, `epics/`, `events.jsonl`)
  while no loop or script is writing, e.g. `tar -C "$(dirname "$STATE_DIR")" -czf
  delivery-backup.tgz "$(basename "$STATE_DIR")"` (with an empty `STATE_DIR`,
  that directory is `$(git rev-parse --path-format=absolute
  --git-common-dir)/delivery`). Restore by putting the directory back with the
  loop stopped. There is no import command, and a store whose `schema` differs
  from the engine's is refused, never migrated implicitly.
- **Journal.** `events.jsonl` is append-only; `graph.sh show <id> --events`
  prints a node's last 10 events. A torn or unparsable line is skipped with a
  warning, never hiding the events beside it.

### 10.3 Forge tokens and reviewer tokens

Tokens come from the **environment only**. A value set in `.claude/delivery.conf`
(a checked-in file) is discarded.

| Forge | Auth | Optional reviewer identity |
|---|---|---|
| github | `gh auth login` (repo scope) | `GH_REVIEW_TOKEN` |
| gitlab | `GITLAB_TOKEN` (API access to the project) | `GITLAB_REVIEW_TOKEN` |
| gitea / Forgejo | `GITEA_TOKEN` (repository read/write) | `GITEA_REVIEW_TOKEN` |

`delivery-config.sh --check` refuses a gitlab or gitea forge whose token is
unset. `FORGE_URL` and `FORGE_REPO` default from the `origin` remote; set them in
the conf for a self-hosted instance under a sub-path or when origin is not the
forge. `bash "$S/forge.sh" whoami` confirms which account the loop runs as.

A **reviewer token** belongs to a second account that can review PRs on the
repo. When it is set, `forge.sh pr-review` posts verdicts under that identity,
so the forge accepts formal approve/request-changes reviews instead of the
single-account comment form (§7). Everything else still runs as the main
account. Export it only in the session that runs reviewers if you want the
implementer and reviewer identities kept apart.

## 11. Release-branch workflow and promotion

Task PRs don't have to land on `main`. A plan file (spec §18) names a
`target_branch` (a feature, develop, qa or release branch) and a `promote_to`
branch it is promoted into:

1. **Plan it.** `/delivery-loop:decompose` writes the plan with `target_branch`
   and `promote_to`; you approve; `--create` commits it and runs `plan.sh
   apply`. If the target branch is missing on origin, apply creates it from
   `origin/<promote_to>` (or `origin/<BASE_BRANCH>`), printing the exact
   `git push` first — the only step that creates a branch. Apply also creates
   one **promote node** whose deps are the plan's epics.
2. **Build on it.** Every node carries the plan's `target_branch`: worktrees fork
   from it, PRs target it, and the module lock is per target branch, so a
   release and `main` can each have one in-flight task per module. Reconcile
   closes each task when its agent PR merges into that branch (GitHub's closing
   keywords would not, off the default branch).
3. **Promote it.** When every epic of the plan is `done`, the promote node is
   `ready` and the tick runs `promote.sh`. It gates the target branch
   (`PROMOTE_GATE_CMD`, empty = `GATE_CMD`) in a fresh worktree. Green: it opens
   the promotion PR `Promote <T> → <P>` (labelled `agent-authored`, body listing
   the plan's done tasks, ending `Delivery-Task: <id>`) and sets the node
   `in-review`. Red: it flags the node `needs-human` with a `PROMOTE-GATE-RED:`
   comment and runs `NOTIFY_ESCALATE_CMD`. Identical trees: it marks the node
   `done` with `nothing to promote` and opens no PR.
4. **You merge the promotion PR**, with a merge commit (`PROMOTE_MERGE_METHOD`,
   default `merge`), which is why merge commits must stay enabled (§2). It is
   never auto-merged, `--auto-merge` or not. Reconcile marks the promote node
   `done` once it merges.

Without a plan target, every node targets `BASE_BRANCH`. Setting `BASE_BRANCH`
to a release branch works too (every new node then targets it), but there is no
promote node: you open and merge the promotion PR yourself, and remember that
nodes keep the target they were created with (§7).

Not handled by the loop: merging P back into T while work is in flight, and
multi-hop promotion (`develop → qa → main`). Both are human operations; a
conflicting promotion PR is yours to resolve.
