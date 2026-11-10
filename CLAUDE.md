# CLAUDE.md

Guidance for Claude Code working **on this repository**. This repo *is* the
delivery-loop plugin — you are editing a shareable package. It also **dogfoods
the loop on itself** (see "Dogfooding"), so you may additionally be *running*
the loop here. For how the loop works and how a consumer uses it, read
`README.md`; don't duplicate it here.

## What this is

A self-contained **agentic software-delivery loop** for Claude Code, shipped as a
**plugin + marketplace**. Consumers write specs; the loop turns them into a
reviewed plan file and then a work graph — GitHub Issues
(`GRAPH_BACKEND=github`) or JSON files in the clone (`GRAPH_BACKEND=local`) —
and agents claim → implement → adversarially review → patch → merge each task in
its own git worktree, behind one per-repo correctness gate. PRs live on a forge
(`FORGE=github|gitlab|gitea`). Task PRs merge into a plan's target branch, which
a promotion PR carries onward. There is no server and no database — state is the
consumer's repo, its graph backend, its forge, and `git` + `jq` (+ `gh` or
`curl`). Skills reach that state only through two seams, `graph.sh` and
`forge.sh`.

The system was extracted and **generalized** from the Lineage monorepo, where it
runs live. Lineage is upstream: most changes originate there and get ported here
(see "Origin & sync"). This repo is the generic, redistributable copy.

## The cardinal rule: everything must stay repo-agnostic

Every skill and script here runs inside **someone else's** repo. The single most
common way to break this package is to leak specifics of one consumer.

- **No consumer-specific strings.** No `lineage`, no hardcoded tool names
  (`pnpm`, `uv`, `alembic`, `afplay`), no assumed filenames (`CLAUDE.md`, a
  specific spec name). If you're tempted to write one, route it through config
  instead. Quick check: `grep -ri lineage plugins/` must stay empty.
- **Per-repo behavior lives in exactly one place:** `.claude/delivery.conf` in
  the *consumer's* repo, resolved by `scripts/lib/config.sh`. Skills read config
  keys (`GATE_CMD`, `SPEC_SOURCES`, …); they never name a concrete command.
- **Scripts self-reference via `${CLAUDE_PLUGIN_ROOT}`** so they resolve wherever
  the plugin is installed. Never use paths relative to a checkout.
- **Docs are cited by section number.** Skills reference
  `docs/agentic_delivery_spec.md §N`. When editing those docs, preserve existing
  `§` numbers so the citations keep resolving.

## Layout

```
delivery-loop/
├── .claude-plugin/marketplace.json      # THIS repo as a marketplace (version A)
├── README.md                            # user-facing: how it works, install, config
└── plugins/delivery-loop/
    ├── .claude-plugin/plugin.json        # the plugin manifest (version B — keep == A)
    ├── skills/                           # the 10 /delivery-loop:* skills (SKILL.md each)
    ├── scripts/                          # the engine the skills drive
    │   ├── graph.sh                      # the graph seam: ready/list/show/claim/transition/reconcile/migrate/…
    │   ├── forge.sh                      # the forge seam: pr-create/pr-view/pr-list/pr-review/pr-merge/…
    │   ├── tick-plan.sh                  # the tick's action plan (lib/tick-plan.jq); changes nothing
    │   ├── tick-merge.sh                 # the tick's merge action: re-check, gate merged result, merge
    │   ├── promote.sh                    # the tick's promote action: gate target, open promotion PR
    │   ├── plan.sh                       # plan files: lint / render / apply
    │   ├── task-worktree.sh              # per-task worktree, forked from the node's target branch
    │   ├── task-queue.sh, claim-task.sh  # v0.1.4-compatible wrappers over graph.sh ready / claim
    │   ├── delivery-init.sh              # one-time consumer bootstrap (seams+conf+gate seed+labels/store)
    │   ├── delivery-config.sh            # print the resolved config; --check validates it
    │   ├── backends/                     # graph-{github,local}.sh, forge-{github,gitlab,gitea}.sh (+ .jq),
    │   │                                 #   forge-verdict.jq
    │   ├── lib/config.sh                 # resolve .claude/delivery.conf (defaults<file<env)
    │   ├── lib/worktree-gate.sh          # run a gate in a throwaway worktree (tick-merge, promote)
    │   ├── lib/*.jq                      # pure policy core: node/pr/shape, graph, ready, transitions,
    │   │                                 #   reconcile, tick-plan, claim-*, orphan-claims, plan-*
    │   └── tests/                        # *-test.sh unit tests (gh/git shims) + fixtures/
    └── docs/                             # agentic_delivery_spec.md (design) + delivery_runbook.md (ops)
```

The repo root also carries the dogfood artifacts (not shipped): `scripts/check.sh`
(the gate) with its helpers `scripts/lib/{bash32,private-tmp}.sh` and their
self-tests `scripts/tests/`, `.claude/delivery.conf`, `styleguides/`, and the
specs under `docs/`.

Two artifact types, two audiences:
- **Skills** (`skills/*/SKILL.md`) are prompts an agent follows. Edit these to
  change *behavior*. They orchestrate; they call scripts for mechanics and must
  never re-derive queue/claim logic in prose.
- **Scripts** (`scripts/*.sh`, `lib/*.jq`) are the deterministic engine. Edit
  these to change *mechanics*. Keep reasoning out of them and behavior out of the
  skills.

## Config: the one seam

`lib/config.sh` fills settings from three layers, each overriding the last:
built-in defaults → the consumer's `.claude/delivery.conf` → environment
variables (for CI). Keys: `GATE_CMD`, `BASE_BRANCH`, `WORKTREE_SETUP_CMD`,
`SPEC_SOURCES`, `STYLEGUIDES_DIR`, `MODULES`, `NOTIFY_APPROVE_CMD`,
`NOTIFY_ESCALATE_CMD`, `GRAPH_BACKEND`, `STATE_DIR`, `LOCK_STALE_SECONDS`,
`LIST_LIMIT`, `FORGE`, `FORGE_URL`, `FORGE_REPO`, `PLANS_DIR`,
`TASK_MERGE_METHOD`, `PROMOTE_MERGE_METHOD`, `PROMOTE_GATE_CMD` (documented in
the README table and design spec §2.2). Environment-only keys (`_DL_ENV_ONLY`,
never read from the file): `GITLAB_TOKEN`, `GITEA_TOKEN`, `GH_REVIEW_TOKEN`,
`GITLAB_REVIEW_TOKEN`, `GITEA_REVIEW_TOKEN`, `LOCK_WAIT_SECONDS`.
`dl_config_check` in `lib/config.sh` (`delivery-config.sh --check`) validates the
combination and the jq version; every seam entry point runs it before any I/O.

**Adding a config key touches five places** — miss one and it silently defaults:
1. `lib/config.sh` — add to `_DL_VARS`, the `:` default, and the `export` list
   (or to `_DL_ENV_ONLY` for a secret or runtime knob).
2. `delivery-init.sh` — scaffold it into the generated `.claude/delivery.conf`.
3. `delivery-config.sh` — it prints each file key explicitly; add the new one
   there (env-only keys are never printed).
4. `README.md` — the config table (and design spec §2.2's).
5. Any skill that reads it — reference the key (via `delivery-config.sh`), never
   a hardcoded value.

## Verify a change (the gate)

Before any commit, run the gate:

```bash
bash scripts/check.sh
```

It encodes this package's invariants: every script parses (`bash -n`); a
**bash-3.2 lint** finds no bash-4+ construct (`declare -A`, `mapfile`,
`readarray`, `${x,,}`, `${x^^}`, `&>>`, `|&`, `coproc`) under
`plugins/delivery-loop/scripts/`; **every** `plugins/delivery-loop/scripts/tests/*-test.sh`
passes, discovered by glob (a new test needs no gate edit), each run under a
fresh private `TMPDIR` it must leave empty (a leaked temp file fails the gate);
the gate's own self-tests pass; the plugin manifest validates; **both manifests
agree on the version**; and the leak check `grep -ri lineage plugins/` stays
empty. The jq version rule (≥ 1.6, never 1.8.2) is enforced by `dl_config_check`
and covered by `tests/config-check-test.sh`; the bash-3.2 container stage
installs a jq < 1.8 for the same reason. A change that adds a new class of check
belongs **in** `scripts/check.sh`, not in prose here — the gate is the single
definition of "correct" (it is `GATE_CMD` in `.claude/delivery.conf`).

The gate also re-runs the unit tests under a real **bash 3.2**: set
`DL_BASH32=/path/to/bash-3.2` (a bare name resolves via PATH; it is linked by
absolute path and re-verified as 3.2 through the shim, else the gate fails), or
keep a local `bash:3.2` docker image (override with `DL_BASH32_IMAGE`; never
pulled). The stock `bash:3.2` image lacks git and jq, so each run needs network
to `apk add` them; a prebuilt local image with git + jq<1.8 avoids that. With
neither it prints a `SKIPPED` notice and continues; `DL_BASH32=off` skips
explicitly. It then re-runs them under **jq 1.6**, the supported floor, in a
local docker image `dl-bash32:jq16` (override with `DL_JQ16_IMAGE`; never
pulled, nothing installed: it must already carry bash, git and jq 1.6, else the
gate fails). No image prints a `SKIPPED` notice; `DL_JQ16=off` skips
explicitly. Details in `scripts/check.sh`.

To smoke-test an install without touching your real config, point Claude Code at
a throwaway config dir: `CLAUDE_CONFIG_DIR=$(mktemp -d) claude plugin marketplace
add ./ && … install …` (the CLI rejects bare `.` — use `./`). Never mutate
`~/.claude` to test.

## Dogfooding

This repo runs the delivery loop **on itself** (since v0.1.4): the GitHub repo
carries the label taxonomy, `.claude/delivery.conf` is checked in, and the gate
is `scripts/check.sh`. Two things to keep straight:

- **What ships vs. what steers.** Only `plugins/delivery-loop/**` is the
  shippable package (version bump required — see Release protocol). The
  repo-root dogfood artifacts — `.claude/delivery.conf`, `scripts/check.sh`,
  `styleguides/`, root `docs/` specs — steer the loop here and are **not**
  shipped; changing only them needs no version bump.
- **Sessions run the installed copy** (from the `delivery-loop` marketplace),
  not this working tree. After merging a plugin change, `claude plugin update
  delivery-loop` to dogfood it; a task's acceptance criteria can only rely on
  loop behavior that is already installed.

Modules: `policy`, `graph`, `forge`, `plan`, `engine`, `skills`, plus the built-in
`infra` and `docs`. Path ownership (first match wins) is the table in
`docs/delivery_graph_spec.md` §14: `plan` = `plan.sh` + `lib/plan-*.jq`;
`policy` = other `lib/*.jq` + `tick-plan.sh`; `graph` = `graph.sh`,
`backends/graph-*`, `task-queue.sh`, `claim-task.sh`; `forge` = `forge.sh` +
`backends/forge-*`; `engine` = every other script — all under
`plugins/delivery-loop/scripts/`; `skills` = `plugins/delivery-loop/skills/**`.
A task that touches shipped plugin content must include the version bump (both
manifests) in its acceptance criteria — **except** on a release branch (e.g.
`release/0.2.0`), where the bump happens once, in the release's final task, and
nothing reaches `main` (what installed copies track) until the promotion PR.

## Release protocol

Ship via **branch → PR → squash-merge** (this repo adopted PRs at v0.1.3; earlier
versions went direct-to-main). Every shippable change **must bump the version**,
or installed copies will `plugin update` to "same version, nothing to do" and go
stale.

1. Bump the version in **both** manifests, kept identical:
   `plugins/delivery-loop/.claude-plugin/plugin.json` **and**
   `.claude-plugin/marketplace.json`. During `0.x`, features are patch bumps.
2. Merge to `main` (the marketplace tracks `main`'s HEAD, not tags).
3. Tag the release: `claude plugin tag ./plugins/delivery-loop` → creates
   `delivery-loop--v<version>` (validates the two manifests agree). `git push --tags`.

Adding a skill also means adding its row to the README's skill table and its
one-liner to the plugin `docs/README.md`.

## Origin & sync (porting from Lineage)

The engine scripts and skills are copies of Lineage's `scripts/` + `.claude/skills/`
plus the two delivery docs. When Lineage lands a generic improvement to this
system, port it:

- Pure machinery (`task-queue`, `claim-task`, `lib/*.jq`) usually re-copies
  wholesale — then **re-generalize**: strip any consumer strings, restore
  `${CLAUDE_PLUGIN_ROOT}` paths and config reads.
- Skills and docs need re-generalizing by hand (config keys instead of concrete
  tools; no `afplay`/`pnpm`/`alembic`/`CLAUDE.md`; preserve spec `§` numbers).
- Finish with the full Release protocol above (bump both manifests + tag + push).

## Conventions

- **Bash:** executable scripts start `set -euo pipefail`; the **sourced**
  `lib/config.sh` deliberately does **not** (it runs inside the caller's shell
  options and guard-quotes its own expansions). Target **bash 3.2** (macOS
  default) — no associative arrays, mind empty-array expansion under `set -u`.
- **JSON** is read/written with `jq`, never ad-hoc parsing.
- Keep skills terse and imperative; keep scripts deterministic and side-effect-honest.
