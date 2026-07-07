# delivery-loop

A self-contained **agentic software-delivery loop** for [Claude Code](https://code.claude.com),
packaged as a plugin. You write specs; it files them as a dependency-ordered
GitHub Issues backlog, then agents **claim → implement → adversarially review →
patch → merge** the tasks — each in its own git worktree, all behind a single
correctness check you define per repo. No server and no database: the state is
your repo, its Issues, and `gh` + `git` + `jq`.

## Two ways to run it

Once a repo is set up, there's a dial between "supervised" and "let it rip."

**a) Stay in the loop.** Steer with `author-spec` and `decompose` — you shape the
specs and approve the backlog — then run the orchestrator with **auto-merge off**:

```
/loop /delivery-loop:delivery-tick
```

Agents implement, review, and patch on their own, but **you are the merge gate**:
every PR waits for you before it lands. The machine writes the code; you decide
what ships.

**b) Let it rip.** When you trust the loop, turn on parallelism and auto-merge:

```
/loop /delivery-loop:delivery-tick --parallel 3 --auto-merge
```

Now approved, green PRs merge themselves and several tasks run at once. Your only
job is keeping it fed with tasks in GitHub Issues. Feed it well and you've got a
code factory that'll have you tokenmaxxing in no time.

## How it works

The delivery loop is a way to build software where **agents do the work and
GitHub holds the state**. The whole model is four ideas.

**1 — Your backlog is GitHub Issues.** You describe what to build in specs (plain
Markdown). `decompose` reads them and files the work as Issues: *epics* (big
trackers) split into *tasks* (small, independently shippable units), with
`Depends-on:` lines recording what has to come first. From then on the backlog
*is* your Issues — `status:*` labels track where each task stands.

**2 — Each task runs one fixed loop: claim → implement → review → patch → merge.**
An agent takes the next ready task and **claims** it, so no two agents grab the
same one. It **implements** the task in its own git worktree — a private,
throwaway checkout — so many agents can work at once without colliding, then
opens a PR. A *different* agent **reviews** that PR adversarially from a clean
checkout, trying to find what's wrong. If it finds something, a bounded **patch**
cycle fixes it (after 3 rounds it escalates to a human). When the PR is clean, it
**merges**.

**3 — One command decides "correct," and it's yours.** Everything above hangs on
a single question: *is the repo correct right now?* You answer it once per repo,
as one command — your **gate**. It runs your typecheck, tests, linter, whatever
matters, and exits 0 only if all is well. The implementer must pass it before
opening a PR; the reviewer re-runs it in a clean checkout, so approval never
rests on trusting the implementer's machine; merge waits on that same command in
CI. Because "correct" is one reproducible command and not a human judgment call,
the loop can run unattended.

> **Where does that command come from?** `/delivery-loop:init` sets it up for you.
> Run once in a repo, it scans your stack — the linters, type-checkers, and test
> frameworks you actually use — and **seeds a starter `scripts/check.sh`** that
> runs them, with `GATE_CMD` (in `.claude/delivery.conf`) pointing at it. You
> review that script and adjust it; if init finds no tooling, it says so and the
> gate fails until you define your checks (an empty gate never passes green).
> From then on it's a checked-in file the loop extends as your repo grows.

**4 — An orchestrator turns the crank.** `delivery-tick` is one step of the loop:
it reads the board, reconciles anything stale, and takes the next sensible
action. Run it under `/loop` and it keeps going on its own — serially at first,
then `--parallel N` to run several tasks at once, and `--auto-merge` to merge
approved, green PRs for you. You start supervised and loosen the reins as you
come to trust it.

## What you get

Nine skills, namespaced `/delivery-loop:*`:

| Skill | Role |
|---|---|
| `init` | One-time per-repo bootstrap: create labels, scaffold `.claude/delivery.conf`, gitignore `.worktrees/`. |
| `author-spec` | Turn a subsystem into a merged, decompose-ready sub-spec — pin → ground → draft → adversarial docs-review → hand to `decompose`. Upstream of the backlog. |
| `decompose` | Specs → a dependency-ordered backlog of epic/task Issues (dry-run by default; `--create` after approval). |
| `next-task` | Claim the next ready task, implement it in a worktree, pass the gate, open a PR. |
| `review-task` | Independently, adversarially review a PR against its task's acceptance criteria — in a clean checkout. |
| `patch-task` | Answer review findings / failing CI on a PR (bounded to 3 iterations, then escalate). |
| `deliver-task` | Drive one issue end-to-end — `next-task` → fresh `review-task` → bounded `patch-task` loop → hand to a human. The single-task path. |
| `delivery-tick` | One orchestrator tick — reconcile the board and take the next action (serial, or `--parallel N`, with opt-in `--auto-merge`). |
| `task-status` | Render the board; `--reclaim` reconciles labels and frees stale claims. |

The queue, claim arbitration (a comment-ordered Lamport lock), and worktree
management are shell scripts under `plugins/delivery-loop/scripts/`. The skills
call them; they never re-derive the mechanics.

## Prerequisites

- `gh` (authenticated, repo scope), `git`, `jq`, `bash`.
- A GitHub repo with Issues enabled.

## Install

```bash
# add this repo as a marketplace (one-time)
/plugin marketplace add blakemartz/delivery-loop

# install the plugin — user scope makes it available in ALL your repos
/plugin install delivery-loop@delivery-loop
```

> Install at **user scope** to use it across your own repos; install at
> **project scope** (committed to `.claude/settings.json`) to hand it to a team.

## Set up a repo

Once per repo you want to run the loop in:

```
/delivery-loop:init
```

That creates the label taxonomy, scaffolds `.claude/delivery.conf`, gitignores
`.worktrees/`, and **seeds `scripts/check.sh` from your detected tooling**. Then
**review `scripts/check.sh`** — it's your gate — and adjust it so it runs your
repo's real checks. (If init found no tooling, the seeded gate fails on purpose
until you fill it in.)

### `.claude/delivery.conf` — the whole adapter

One per-repo file is the entire seam between the generic engine and your project:

| Key | Default | Meaning |
|---|---|---|
| `GATE_CMD` | `bash scripts/check.sh` | **THE gate** — one command that exits 0 iff the repo is correct. Implementers, patchers, and reviewers all run it. |
| `BASE_BRANCH` | `main` | Branch worktrees fork from and PRs target. |
| `WORKTREE_SETUP_CMD` | (detected) | Command run once in a fresh worktree, e.g. `pnpm install`, `uv sync`. |
| `SPEC_SOURCES` | `docs/*_spec.md` | Files `decompose` reads to produce tasks. |
| `STYLEGUIDES_DIR` | `styleguides/` | Where coding conventions live. |
| `MODULES` | (empty) | Allowed `module:` labels — the concurrency unit (≤ 1 in-flight task per module). |
| `NOTIFY_APPROVE_CMD` / `NOTIFY_ESCALATE_CMD` | (empty) | Optional hooks run on approval / escalation (e.g. a sound). |

Recommended repo settings (run once, yourself — it changes GitHub state):

```bash
gh repo edit --enable-squash-merge --enable-merge-commit=false \
             --enable-rebase-merge=false --delete-branch-on-merge
```

## Run it

```
/delivery-loop:decompose                 # propose a backlog (dry-run) → approve → re-run with --create
/delivery-loop:task-status               # see the board
/delivery-loop:delivery-tick             # one serial tick — the next single action
/loop /delivery-loop:delivery-tick                      # supervised serial free-run
/loop /delivery-loop:delivery-tick --parallel 3 --auto-merge   # parallel free-run, agent-merges approved PRs
```

Start **serial and supervised**; graduate to `--parallel` / `--auto-merge` once
free runs are boringly reliable.

## Under the hood

The mechanics behind the four ideas above:

- **State lives in GitHub, not a database.** Issue labels are a derived cache of
  ground truth (issue/PR state); `task-queue.sh --fix` reconciles them each tick.
- **The claim lock is comment-ordered.** `claim-task.sh` posts a `CLAIM` comment
  and the earliest *live* claim wins — a cheap Lamport lock with orphan-reaping
  (`scripts/lib/*.jq`, unit-tested in `scripts/tests/`).
- **Every task runs in its own worktree** under `.worktrees/`, so parallel agents
  never collide in the working tree.
- **The gate is never bypassed.** No stage may skip the `GATE_CMD` check — no
  `--no-verify`, no merging red CI. It is the loop's only definition of "correct."

See `plugins/delivery-loop/docs/delivery_runbook.md` for operating modes and the
free-run playbook, and `plugins/delivery-loop/docs/agentic_delivery_spec.md` for
the full design.

## Layout

```
delivery-loop/
├── .claude-plugin/marketplace.json      # this repo as a marketplace
└── plugins/delivery-loop/
    ├── .claude-plugin/plugin.json
    ├── skills/                          # the 9 skills
    ├── scripts/                         # engine: task-queue, claim-task, task-worktree, delivery-init, lib/, tests/
    └── docs/                            # design spec + operator runbook
```

## License

MIT — see [LICENSE](LICENSE).
