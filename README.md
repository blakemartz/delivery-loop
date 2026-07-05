# delivery-loop

A self-contained **agentic software-delivery loop** for [Claude Code](https://code.claude.com),
packaged as a plugin. It turns specs into a dependency-ordered GitHub Issues
backlog, then lets agents **claim → implement → adversarially review → patch →
merge** tasks in isolated git worktrees, each gated by a single "is this repo
correct" command.

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
call them; they never re-derive the mechanics. Everything runs on `gh` + `git` +
`jq` — no server, no database.

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

That creates the label taxonomy, scaffolds `.claude/delivery.conf`, and
gitignores `.worktrees/`. Then **edit `.claude/delivery.conf`** — at minimum set
`GATE_CMD` to your repo's check command.

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

## How it works

- **State lives in GitHub, not a database.** Issue labels are a derived cache of
  ground truth (issue/PR state); `task-queue.sh --fix` reconciles them each tick.
- **The claim lock is comment-ordered.** `claim-task.sh` posts a `CLAIM` comment
  and the earliest *live* claim wins — a cheap Lamport lock with orphan-reaping
  (`scripts/lib/*.jq`, unit-tested in `scripts/tests/`).
- **Every task runs in its own worktree** under `.worktrees/`, so parallel agents
  never collide in the working tree.
- **The gate is the only definition of "correct."** The loop never bypasses it.

See `plugins/delivery-loop/docs/delivery_runbook.md` for operating modes and the
free-run playbook, and `plugins/delivery-loop/docs/agentic_delivery_spec.md` for
the full design.

## Layout

```
delivery-loop/
├── .claude-plugin/marketplace.json      # this repo as a marketplace
└── plugins/delivery-loop/
    ├── .claude-plugin/plugin.json
    ├── skills/                          # the 7 skills
    ├── scripts/                         # engine: task-queue, claim-task, task-worktree, delivery-init, lib/, tests/
    └── docs/                            # design spec + operator runbook
```

## License

MIT — see [LICENSE](LICENSE).
