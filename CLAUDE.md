# CLAUDE.md

Guidance for Claude Code working **on this repository**. This repo *is* the
delivery-loop plugin — you are editing a shareable package. It also **dogfoods
the loop on itself** (see "Dogfooding"), so you may additionally be *running*
the loop here. For how the loop works and how a consumer uses it, read
`README.md`; don't duplicate it here.

## What this is

A self-contained **agentic software-delivery loop** for Claude Code, shipped as a
**plugin + marketplace**. Consumers write specs; the loop files them as a
GitHub-Issues backlog, then agents claim → implement → adversarially review →
patch → merge each task in its own git worktree, behind one per-repo correctness
gate. There is no server and no database — state is the consumer's repo, its
Issues, and `gh` + `git` + `jq`.

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
    │   ├── task-queue.sh                 # compute ready set; --fix reconciles labels
    │   ├── claim-task.sh + lib/*.jq      # comment-ordered Lamport claim lock
    │   ├── task-worktree.sh              # per-task isolated worktree lifecycle
    │   ├── delivery-init.sh              # one-time consumer bootstrap (labels+conf+gate seed)
    │   ├── lib/config.sh                 # resolve .claude/delivery.conf (defaults<file<env)
    │   └── tests/                        # jq unit tests for the claim logic
    └── docs/                             # agentic_delivery_spec.md (design) + delivery_runbook.md (ops)
```

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
`NOTIFY_ESCALATE_CMD` (documented in the README table).

**Adding a config key touches four places** — miss one and it silently defaults:
1. `lib/config.sh` — add to `_DL_VARS`, the `:` default, and the `export` list.
2. `delivery-init.sh` — scaffold it into the generated `.claude/delivery.conf`.
3. `README.md` — the config table.
4. Any skill that reads it — reference the key, never a hardcoded value.

## Verify a change (the gate)

Before any commit, run the gate:

```bash
bash scripts/check.sh
```

It encodes this package's invariants: every script parses (`bash -n`), the
claim-logic unit tests pass, the plugin manifest validates, **both manifests
agree on the version**, and `grep -ri lineage plugins/` stays empty. A change
that adds a new class of check belongs **in** `scripts/check.sh`, not in prose
here — the gate is the single definition of "correct" (it is `GATE_CMD` in
`.claude/delivery.conf`).

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

Modules: `engine` (`plugins/delivery-loop/scripts/**`), `skills`
(`plugins/delivery-loop/skills/**`), plus the built-in `infra` and `docs`.
A task that touches shipped plugin content must include the version bump (both
manifests) in its acceptance criteria.

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
