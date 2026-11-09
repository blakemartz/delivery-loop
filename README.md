# delivery-loop

A self-contained **agentic software-delivery loop** for [Claude Code](https://code.claude.com),
packaged as a plugin. You write specs; it files them as a dependency-ordered
backlog — GitHub Issues, or a local JSON graph on your machine — then agents
**claim → implement → adversarially review → patch → merge** the tasks — each in
its own git worktree, all behind a single correctness check you define per repo.
PRs live on GitHub, GitLab, or Gitea/Forgejo. No server and no database: the
state is your repo, its backlog, its PRs, and `git` + `jq` (+ `gh` or `curl`).

## Two ways to run it

Both modes run the same loop — agents claim, implement, review, and patch on
their own. They differ in **exactly one thing: who gates the merge.**

**a) Human in the loop.** Auto-merge stays off, so **every PR waits for your
approval before it lands.** The machine writes the code; you decide what ships.

```
/loop /delivery-loop:delivery-tick
```

**b) Let it rip.** Turn on auto-merge (and parallelism), and approved, green PRs
merge themselves while several tasks run at once. Your only job is keeping it fed
with tasks — feed it well and you've got a code factory that'll
have you tokenmaxxing in no time.

```
/loop /delivery-loop:delivery-tick --parallel 3 --auto-merge
```

Either way, you steer it the same way: **`author-spec` and `decompose` shape the
specs and approve the backlog.** That's the wheel — in both modes the loop only
ever builds what the backlog tells it to.

> **A note on models.** The Issues you author *are* the build prompts the loop
> agents run from — so spend your strongest model where it compounds: authoring
> specs and decomposing the backlog. Once the tasks are concrete, the loop itself
> (implement / review / patch) runs fine on cheaper, faster models.

## How it works

The delivery loop is a way to build software where **agents do the work and
your backlog and forge hold the state**. The whole model is four ideas.

**1 — Your backlog is a work graph, and you pick where it lives.** You describe
what to build in specs (plain Markdown). `decompose` reads them and writes a
reviewed **plan file**: *epics* (big trackers) split into *tasks* (small,
independently shippable units), with dependency edges recording what has to come
first. Once you approve it, the plan becomes nodes in your **graph backend** —
GitHub Issues (`GRAPH_BACKEND=github`, the default, with native blocked-by links
and sub-issues) or JSON files on your machine (`GRAPH_BACKEND=local`, no issue
tracker at all). PRs go to your **forge**: GitHub, GitLab, or Gitea/Forgejo
(`FORGE`). From then on the backlog *is* that graph — every task has a status
(`ready`, `claimed`, `in-review`, …) the loop keeps in sync with what really
happened on the forge.

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

Ten skills, namespaced `/delivery-loop:*`:

| Skill | Role |
|---|---|
| `init` | One-time per-repo bootstrap: pick the graph backend and forge, create/connect the remote if needed, scaffold `.claude/delivery.conf`, seed the gate + styleguides stub, gitignore `.worktrees/`, create the labels (github) or the local store, check forge auth. |
| `author-styleguides` | Draft the repo's styleguides — the conventions agents implement and review against — from your stack and existing code. You ratify before anything lands; re-runnable as stacks grow. |
| `author-spec` | Turn a subsystem into a merged, decompose-ready sub-spec — pin → ground → draft → adversarial docs-review → hand to `decompose`. Upstream of the backlog. |
| `decompose` | Specs → a plan file of epics and tasks, linted and rendered as a Mermaid graph (dry-run by default); `--create` after approval commits it and applies it to the graph backend. |
| `next-task` | Claim the next ready task, implement it in a worktree, pass the gate, open a PR. |
| `review-task` | Independently, adversarially review a PR against its task's acceptance criteria — in a clean checkout. |
| `patch-task` | Answer review findings / failing CI on a PR (bounded to 3 iterations, then escalate). |
| `deliver-task` | Drive one issue end-to-end — `next-task` → fresh `review-task` → bounded `patch-task` loop → hand to a human. The single-task path. |
| `delivery-tick` | One orchestrator tick — reconcile the board and take the next action (serial, or `--parallel N`, with opt-in `--auto-merge`). |
| `task-status` | Render the board; `--reclaim` reconciles status and frees stale claims; `--graph` draws the open graph as Mermaid. |

The graph and forge seams (`graph.sh`, `forge.sh`), the policy core (ready set,
transitions, reconcile, the tick's action plan — pure `jq`), claims, worktrees,
plan files, merges and promotion are shell scripts under
`plugins/delivery-loop/scripts/`. The skills call them; they never re-derive the
mechanics.

## Prerequisites

Always:

- `git`, `bash` (3.2 or later; macOS's default works), and `jq`.
- jq ≥ 1.7, excluding 1.8.2 (upstream bug
  [jqlang/jq#3597](https://github.com/jqlang/jq/issues/3597)); use 1.8.1, or 1.8.3
  or later. `delivery-config.sh --check`, which every entry point runs, refuses an
  unsupported jq. A version string it cannot parse is accepted, so Alpine's jq 1.6
  build, which reports `jq-master-…`, is not caught: upgrade it yourself.
- A remote on your forge — don't have one yet? `init` walks you through creating
  or connecting one.

Per seam (`GRAPH_BACKEND` / `FORGE`):

| Seam | Needs |
|---|---|
| `GRAPH_BACKEND=github` | `gh` ≥ 2.94 (native blocked-by links and sub-issues; an older gh falls back to `Depends-on:` text edges with a warning), authenticated with repo scope, and Issues enabled on the repo. Requires `FORGE=github`. |
| `GRAPH_BACKEND=local` | git ≥ 2.31 (`rev-parse --path-format`). No issue tracker. Single machine: the store lives in the clone's `.git`. |
| `FORGE=github` | `gh`, authenticated with repo scope. |
| `FORGE=gitlab` | `curl`, and `GITLAB_TOKEN` in the environment. |
| `FORGE=gitea` (also Forgejo) | `curl`, and `GITEA_TOKEN` in the environment. |

Tokens are environment-only; optional reviewer tokens (`GH_REVIEW_TOKEN`,
`GITLAB_REVIEW_TOKEN`, `GITEA_REVIEW_TOKEN`) let reviews post as a second
identity, which restores formal reviews (see the runbook, §10.3).

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

That picks the seams (it detects `FORGE` from your `origin` host and defaults the
backend to `github` on GitHub, `local` elsewhere — override with
`GRAPH_BACKEND=… FORGE=…` in the environment), scaffolds `.claude/delivery.conf`,
gitignores `.worktrees/`, **seeds `scripts/check.sh` from your detected
tooling**, and creates the label taxonomy (github backend) or the local store
(local backend). (No remote yet? It scaffolds everything local, then tells you
exactly how to create or connect one and finishes on re-run.) Then **review `scripts/check.sh`**
— it's your gate — and adjust it so it runs your repo's real checks. (If init
found no tooling, the seeded gate fails on purpose until you fill it in.)

The loop hangs three per-repo artifacts, and init only establishes the first:

1. **The gate** — what is *correct* (seeded above; you review it).
2. **The styleguides** — what is *good*: `/delivery-loop:author-styleguides`
   drafts coding conventions from your stack and existing code into
   `STYLEGUIDES_DIR`; you ratify them before they land. From then on decompose
   fits tasks to them, implementers follow them, reviewers enforce them.
3. **The specs** — what to *build*: if nothing matches `SPEC_SOURCES` yet,
   `/delivery-loop:author-spec` authors your first spec; `decompose` turns
   specs into the backlog.

### `.claude/delivery.conf` — the whole adapter

One per-repo file is the entire seam between the generic engine and your project:

| Key | Default | Meaning |
|---|---|---|
| `GATE_CMD` | `bash scripts/check.sh` | **THE gate** — one command that exits 0 iff the repo is correct. Implementers, patchers, and reviewers all run it. |
| `BASE_BRANCH` | `main` | Default target branch: worktrees fork from it and PRs target it, unless a plan file names another (see Branch flow). |
| `WORKTREE_SETUP_CMD` | (detected) | Command run once in a fresh worktree, e.g. `pnpm install`, `uv sync`. |
| `SPEC_SOURCES` | `docs/*_spec.md` | Files `decompose` reads to produce tasks. |
| `STYLEGUIDES_DIR` | `styleguides/` | Where coding conventions live. |
| `MODULES` | (empty) | Allowed `module:` labels — the concurrency unit (≤ 1 in-flight task per module). |
| `NOTIFY_APPROVE_CMD` / `NOTIFY_ESCALATE_CMD` | (empty) | Optional hooks run on approval / escalation (e.g. a sound). |
| `GRAPH_BACKEND` | `github` | Where the task graph lives: `github` \| `local`. `github` requires `FORGE=github`. |
| `STATE_DIR` | (empty → `<git-common-dir>/delivery`) | Local backend store, shared by every worktree of the clone. |
| `LOCK_STALE_SECONDS` | `120` | Local backend: age after which a lock may be broken. |
| `LIST_LIMIT` | `5000` | Fetch ceiling for graph and forge lists; reaching it is an error, never a silent truncation. |
| `FORGE` | `github` | Where PRs live: `github` \| `gitlab` \| `gitea`. |
| `FORGE_URL` | (derived from origin) | Forge API base host, e.g. `https://gitlab.example.com`. |
| `FORGE_REPO` | (derived from origin) | `owner/repo`, or GitLab `group/subgroup/project`. |
| `PLANS_DIR` | `docs/plans/` | Where plan files live. |
| `TASK_MERGE_METHOD` | `squash` | Merge method for task PRs. |
| `PROMOTE_MERGE_METHOD` | `merge` | Merge method for promotion PRs. |
| `PROMOTE_GATE_CMD` | (empty → `GATE_CMD`) | Gate run on the target branch before a promotion PR. |

Environment only — never in `.claude/delivery.conf` (a checked-in file; values
set there are ignored): `GITLAB_TOKEN` / `GITEA_TOKEN` (forge auth),
`GH_REVIEW_TOKEN` / `GITLAB_REVIEW_TOKEN` / `GITEA_REVIEW_TOKEN` (optional
reviewer identity), `LOCK_WAIT_SECONDS` (local lock wait, default 30).
`delivery-config.sh --check` validates the combination (backend/forge values,
`GRAPH_BACKEND=github` needs `FORGE=github`, a gitlab/gitea forge needs its token,
and the jq on `PATH` is supported).

Recommended repo settings (run once, yourself — it changes forge state). **Keep
merge commits enabled**: task PRs merge with `TASK_MERGE_METHOD` (squash), but
promotion PRs merge with `PROMOTE_MERGE_METHOD` (a merge commit, which keeps the
release branch's ancestry). On GitHub:

```bash
gh repo edit --enable-squash-merge --enable-merge-commit \
             --enable-rebase-merge=false --delete-branch-on-merge
```

On GitLab and Gitea/Forgejo, `init` names the equivalent settings (runbook §2).

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

## Branch flow

Task PRs merge into a node's **target branch**, which defaults to `BASE_BRANCH`.
A plan file can name another — a feature, develop, qa or release branch — plus a
`promote_to` branch it is promoted into:

```
task PRs ──squash──▶ release/1.0 ──promotion PR (merge commit, human)──▶ main
```

- `plan.sh apply` creates the target branch from `promote_to` if it is missing,
  and one **promote node** that depends on the plan's epics.
- Every task of the plan forks from, targets, and merges into the target branch.
  Implementers and patchers catch up with a moved target by **merging** it into
  the task branch — never rebasing, never force-pushing. The loop closes each
  task when its PR merges, whichever branch that is.
- When every epic is delivered, the tick runs `promote.sh`: it gates the target
  branch (`PROMOTE_GATE_CMD`, default `GATE_CMD`) and opens the promotion PR
  `Promote <target> → <promote_to>`. A red gate escalates to you instead.
- **You merge the promotion PR**, with a merge commit. It is never auto-merged,
  `--auto-merge` or not. That is why merge commits stay enabled.

Details: the runbook's §11 and the design spec's §17.

## Under the hood

The mechanics behind the four ideas above:

- **State lives in your graph backend and forge, not a server.** Stored status
  (labels, on GitHub) is a derived cache of ground truth (merged and open PRs on
  the forge, issue state); `graph.sh reconcile --fix` repairs it each tick.
- **Policy is code, computed once.** The ready set, legal transitions,
  reconciliation and the tick's action plan are pure `jq` (`scripts/lib/*.jq`)
  over one normalized node shape. Backends store; they never decide, so the
  github and local backends behave the same by construction.
- **The orchestrator decides nothing.** `tick-plan.sh` computes the tick's
  actions; `tick-merge.sh` re-checks eligibility and gates the merged result
  before an auto-merge; `promote.sh` opens promotion PRs.
- **Claims are atomic per backend.** On GitHub, `claim-task.sh` posts a `CLAIM`
  comment and the earliest *live* claim wins — a cheap Lamport lock with
  orphan-reaping. On local, a `mkdir` lock makes the claim a true test-and-set.
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
    ├── skills/                          # the 10 skills
    ├── scripts/                         # engine: graph.sh, forge.sh, tick-plan, tick-merge, promote, plan,
    │                                    #   task-worktree, delivery-init, backends/, lib/, tests/
    └── docs/                            # design spec + operator runbook
```

## License

MIT — see [LICENSE](LICENSE).
