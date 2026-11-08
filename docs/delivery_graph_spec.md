# Delivery Graph & Portability Spec (delivery-loop v0.2)

> **Spec-graph position.** Sub-spec of the plugin's design spec
> (`plugins/delivery-loop/docs/agentic_delivery_spec.md`, "the design spec"). It
> amends §5 (state machine), §6 (loop protocol), §7 (queue mechanics) and §8
> (concurrency), and adds new sections §15–§18 to the design spec (see §16 here).
> Prerequisite of the v0.3 "gates & learning" spec (§15 here).
>
> **Research basis (2026-11-06/08).** Two practitioner articles (@hanakoxbt, "Loops
> and Graphs", 2026-08-23; @beamnxw, "Harness vs Loop vs Graph Engineering",
> 2026-07-25). Prior art: StrongDM Attractor (DOT pipelines with typed nodes and
> per-node checkpoints), Beads/Gas Town (agent-native work graph, leases, bisecting
> merge queue), OpenAI Symphony (tracker-driven runs, per-issue workpad), Cursor's
> scaling write-ups (flat locks failed; planner/worker handoffs worked), Stripe
> "blueprints" (deterministic nodes mixed with agent nodes). Literature: LLMCompiler
> (deterministic DAG dispatch), MAST (failure taxonomy), MASS (prompts beat topology),
> CooperBench / "Passes Alone, Fails Together" (implicit coupling causes integration
> failures). The research notes live outside this repo; claims this spec relies on
> are restated where they are used.
>
> **Operator decisions, confirmed 2026-11-08.**
> 1. There must be a queue/graph backend that does **not** depend on GitHub and works
>    locally. Its only remote state is PRs plus their reviews and comments.
> 2. Local store = **one JSON file per epic + an append-only `events.jsonl`, behind a
>    single `mkdir` lock**, in the clone's shared git dir. Not SQLite.
> 3. The local backend is **single-machine** in v0.2. Cross-machine sync is deferred
>    (§15).
> 4. PRs go through a **forge seam**: GitHub (`gh`), GitLab and Gitea (`curl` + `jq`
>    REST) in v0.2.
> 5. **Merge targets are configurable.** Task PRs merge to a plan's target branch
>    (feature / develop / qa / release) and are promoted onward, not merged straight
>    to `main`.
> 6. **Two releases.** v0.2 = graph & portability (this spec). v0.3 = gates &
>    learning (§15).
> 7. **This spec's own work dogfoods #5.** Everything merges to `release/0.2.0`,
>    which is tested before one promotion PR to `main` (§14).
>
> **Code anchors (origin/main @ c08e6ff, v0.1.4).**
> - `scripts/task-queue.sh`: ready set, `--fix` reconcile, epic auto-close.
> - `scripts/claim-task.sh` + `lib/claim-winner.jq`, `lib/orphan-claims.jq`,
>   `lib/claim-ledger.jq`: the Lamport claim.
> - `scripts/task-worktree.sh`: forks from `origin/$BASE_BRANCH`.
> - `scripts/lib/config.sh`: `_DL_VARS`.
> - `skills/delivery-tick/SKILL.md`: tick priority and batching, currently in prose.
> - `scripts/check.sh` (repo root): hard-codes the two test files.

## 1. Purpose

Make the work graph a first-class, **backend-independent** part of the loop. Today
the loop's state *is* GitHub Issues. Edges are `Depends-on:` text, status is labels,
and the tick's planning is prose the orchestrator model interprets. After v0.2:

- **Policy is code, computed once.** The ready predicate, legal transitions,
  reconciliation and the tick's action plan are pure `jq` over a **normalized node
  shape** (§4). Every backend feeds that one implementation, which is how "remote and
  local stay aligned" is enforced: by construction, plus a parity test (GC26).
- **Storage is swappable.** `GRAPH_BACKEND=github` keeps today's behavior, upgraded
  to GitHub's native blocked-by links and sub-issues. `GRAPH_BACKEND=local` keeps the
  graph in JSON on the machine, with no issue tracker.
- **PRs are forge-agnostic.** `FORGE=github|gitlab|gitea`.
- **Merge targets are explicit.** A plan names its `target_branch` and `promote_to`.
  Promotion is itself a node in the graph.
- **The graph is authored as a reviewed file.** `decompose` writes a checked-in plan
  file. `plan.sh lint` / `render` / `apply` turn it into nodes in whichever backend is
  configured.

## 2. Scope and non-goals

**In v0.2:**
- normalized shapes;
- the policy core (`ready.jq`, `transitions.jq`, `reconcile.jq`, `tick-plan.jq`);
- the `graph.sh` contract with `github` and `local` backends;
- the `forge.sh` contract with `github`, `gitlab` and `gitea` adapters;
- plan files (schema, lint, render, apply);
- target branches and promotion nodes;
- skill migration to the two seams;
- the engine defects found in review (GC2, GC10, GC33);
- docs and the version bump.

**Not in v0.2 (do not decompose).** Everything in §15: cross-machine sync for the local
backend, write-scope checks, gate-tamper guard, risk lanes, structured verdicts,
re-plan edge, lessons ledger, metrics, stacked PRs, multi-hop promotion, a "no-forge"
local mode, and new node kinds beyond `task | epic | promote`.

**Behavior parity is a hard requirement.** With default config (`GRAPH_BACKEND=github`,
`FORGE=github`, no plan target), these are unchanged from v0.1.4:
- the ready set and its ordering;
- claim semantics, including the `CLAIM` / `CLAIM-WITHDRAWN` / `RECLAIMED` /
  `STALE-CLAIM-PING` comment prefixes;
- the tick's choice of action, including auto-merge treating "no checks" as green
  (GC15);
- the staleness windows (4h agent / 72h human);
- the patch budget (3);
- the `task-queue.sh` output format (GC61).

**The complete list of intentional exceptions:**
1. A dep closed as not-planned/duplicate no longer satisfies readiness (GC2).
2. Fetch ceilings fail loudly instead of truncating (GC10).
3. PR linkage uses the `Delivery-Task:` trailer, not a `#N` regex (GC33, GC46).
4. A merged PR closes its issue even when it merged into a non-default branch
   (GC42). GitHub's closing keywords only fire on the default branch.
5. Reconcile repairs `claimed → in-review` when an open PR exists (GC43). v0.1.4
   relied on the implementer's own label edit.

## 3. Architecture

```
            skills (judgment: decompose, implement, review, patch)
                 │ call only ▼
  ┌──────────────┴───────────────────────────────────────────────┐
  │ graph.sh  (ready | show | list | claim | release | transition │
  │            | comment | reconcile | create | link | migrate)    │──► lib/*.jq policy core
  │ forge.sh  (pr-create | pr-view | pr-list | pr-review | …)      │    (pure, unit-tested)
  │ tick-plan.sh · plan.sh · promote.sh · task-worktree.sh         │
  └──────┬──────────────────────────────┬────────────────────────┘
         ▼                              ▼
  backends/graph-github.sh       backends/forge-github.sh   (gh)
  backends/graph-local.sh        backends/forge-gitlab.sh   (curl+jq)
                                 backends/forge-gitea.sh    (curl+jq)
```

**Layering rules (normative):**

1. **Backends store; they do not decide.** A graph backend implements only the
   storage primitives in §6.1. It never computes readiness, ordering, staleness or
   legality. The dispatcher `graph.sh` loads the backend's normalized nodes and
   applies `lib/*.jq`.
2. **Forge adapters translate; they do not decide.** An adapter maps one forge's API
   onto the normalized PR shape (§4.2) and the operations in §7.1. Eligibility rules,
   such as auto-merge, live in `tick-plan.jq`.
3. **Skills never call `gh issue`/`gh pr`, `glab`, `tea` or `curl` directly.** They
   call `graph.sh` and `forge.sh`, via `${CLAUDE_PLUGIN_ROOT}/scripts/…`. Exceptions
   are repo bootstrap in `init` and read-only diagnostics.
4. **Compatibility wrappers stay.** `task-queue.sh` and `claim-task.sh` keep their
   names, arguments and output format, and delegate to `graph.sh ready` /
   `graph.sh reconcile --fix` / `graph.sh claim`.
5. **Valid combinations.** `GRAPH_BACKEND=github` requires `FORGE=github`, since
   issues and PRs must share a host. `GRAPH_BACKEND=local` works with any forge.
   Validation is §11.

## 4. Normalized shapes (domain model)

### 4.1 Node

Every backend's `list`/`show` emits nodes of exactly this shape. `lib/node.jq`
provides `validate_node`, which `graph.sh` runs on every backend output (fail fast
on drift).

| Field | Type | Notes |
|---|---|---|
| `id` | string | github: the issue number as a string (`"42"`). local: a slug matching `^[a-z0-9]+(-[a-z0-9]+)*$`, ≤ 40 chars, must not contain `--`. |
| `kind` | `task` \| `epic` \| `promote` | github: from the `task` / `epic` / `promote` labels. |
| `title` | string | |
| `epic` | string \| null | parent epic id, used for ordering and output. github: native `parent.number`, else the legacy `[Ee]pic #E` body match. That is parity with v0.1.4, whose task `epic` came from the body only. |
| `checklist` | [string] | epic nodes only: ids from the epic's own `- [ ] #N` checklist (github). It is empty on local. `children(epic)` = nodes whose `epic` is this epic ∪ `checklist`. This is used only for the started-epic flag and epic completion, as in v0.1.4. |
| `pinged_at` | ISO-8601 \| null | when a stale-human-claim ping was last posted. github: the newest `STALE-CLAIM-PING` comment; local: the newest `comment` event with that prefix. |
| `module` | string \| null | from `module:<m>`. |
| `size` | `S` \| `M` \| `L` \| null | |
| `deps` | `[{id, via}]` | blocking edges. `via` is a string, or null for legacy edges. github: union of native `blockedBy.nodes[].number` and legacy `Depends-on:` lines, deduplicated (GC11). |
| `status` | `blocked` \| `ready` \| `claimed` \| `in-review` \| `changes-requested` \| `approved` \| `done` \| `cancelled` | github: `done`/`cancelled` come from `state` + `stateReason` (`COMPLETED` → done; `NOT_PLANNED`/`DUPLICATE` → cancelled). Other statuses come from labels, a cache that reconcile repairs. |
| `needs_human` | bool | orthogonal flag (the design spec's "any → needs-human"). |
| `claim` | `{actor, run, at, by: "agent"\|"human"}` \| null | github: derived from assignee + `claim:agent` + the winning `CLAIM` comment. |
| `target_branch` | string | the plan's target. Default `BASE_BRANCH`. github: from a `Delivery-Target: <branch>` body line. |
| `promote_to` | string \| null | promote nodes only. |
| `plan_ref` | string \| null | `<plan>/<plan-task-id>`, the idempotency key for `plan.sh apply` (§8.3). |
| `body` | string | markdown: Context + Acceptance criteria (the task contract). |
| `created_at`, `updated_at` | ISO-8601 | |

### 4.2 Pull request

Every forge adapter's `pr-view`/`pr-list` emits PRs of exactly this shape
(`lib/pr.jq` `validate_pr`):

| Field | Type | Notes |
|---|---|---|
| `number` | int | the PR/MR number within its repo (GitLab `iid`, not `id`). |
| `url` | string | |
| `state` | `open` \| `merged` \| `closed` | |
| `head`, `base` | string | branch names. |
| `head_sha` | string | |
| `mergeable` | `clean` \| `conflicting` \| `blocked` \| `unknown` | adapter mapping in §7.3. `unknown` is never eligible to merge. |
| `checks` | `success` \| `pending` \| `failure` \| `none` | rolled up over all required checks. |
| `task_id` | string \| null | linkage, §4.3. |
| `labels` | [string] | |
| `patch_iteration` | int | highest `Patch iteration: n/3` found in the PR comments (0 if none). |
| `reviewed_at_head` | bool | true when some review **or** comment carries a `Reviewed-Head: <sha>` trailer equal to `head_sha`. Every verdict body ends with that trailer, whatever the form: formal review, GitLab note, or comment fallback. A comment has no commit of its own, so the trailer is the only forge-independent way to tie a verdict to a head (GC28, GC29). |
| `agent` | bool | the PR carries the `agent-authored` label. Only agent PRs are patched, reviewed, rebased or merged by the loop (design spec §5.2). |
| `author` | string | |

### 4.3 PR ↔ task linkage

- Agent PR bodies carry a trailer line `Delivery-Task: <node id>`, on every backend.
  On the github backend they also keep `Closes #N`.
- Adapters fill `task_id` from the first of these that matches (GC46):
  1. the `Delivery-Task:` trailer;
  2. if `GRAPH_BACKEND=github`, the first `(Closes|Fixes|Resolves) #N` line;
  3. a `task/<id>--…` head branch;
  4. the legacy `task/<n>-…` head branch (numeric `n`);
  5. otherwise `null`.
- The trailer replaces v0.1.4's `#N\b` body/title regex, which falsely matched any PR
  that merely mentioned the issue (GC33).

## 5. Policy core (`scripts/lib/`)

All of it is pure `jq`. Wall-clock time arrives as an argument (`--argjson now`), so
fixtures are deterministic. Shared graph helpers live in `lib/graph.jq` (owned by
A4) and are used by reconcile, tick-plan and plan lint:

- `index_by_id`: build an id → node lookup.
- `children(epic)`: the epic's child nodes.
- `unblocks(id)`: the number of open nodes whose `deps` contain this id.
- `cycles`: every simple cycle over the `deps` edges, each reported as an id path.

**`ready.jq`.** Input: all nodes. Output: the ready set, best first, as JSON lines of
`{id, title, unblocks, size, started, epic, module, target_branch}`.

*Ready iff:*
- `kind=="task"`;
- status is not `done`/`cancelled`;
- every dep exists and has status `done`;
- `claim==null` and no human assignee;
- `size != "L"`;
- `needs_human` is false.

A dep that is `cancelled` or **unknown** never satisfies readiness (GC2, GC7).

*Ordering (parity with v0.1.4):*
1. started-epic first. An epic is started when it has ≥ 1 child whose status is
   `done` or `cancelled`; v0.1.4 counted any CLOSED child.
2. `unblocks` descending.
3. `S` before `M`.
4. `created_at` ascending (GC5).

*`task-queue.sh` wrapper output.* The wrapper re-emits each line in exactly the
v0.1.4 shape (GC61): `{number, title, unblocks, size: "S"|"M", started,
epic: <number>|null, module: "module:<m>"|"none"}`. Here `number` and `epic` are
the numeric ids, and `module` is the full label name. Callers written for v0.1.4
keep working.

**`transitions.jq`.** The complete transition table. It supersedes the design
spec's §5 table, which is amended to match (§16):

| From | To | Actor kind | When |
|---|---|---|---|
| blocked | ready | reconcile | every dep `done`, not `needs_human` |
| ready | blocked | reconcile | a dep is not `done` |
| ready | claimed | agent \| human \| promote | `claim` (promote only on `kind=="promote"` nodes) |
| claimed | ready | reconcile \| agent \| promote | stale reclaim; claimant releases (promote: red gate, GC50) |
| claimed | in-review | agent \| reconcile \| promote | PR opened (reconcile: open PR exists, GC43; promote: promotion PR opened, GC51) |
| ready \| blocked | in-review | reconcile | status drift: an open agent PR with this `task_id` while the claim was cleared or the status relabelled (reconcile rule 4, GC69) |
| in-review | changes-requested | agent (reviewer) | verdict REQUEST_CHANGES |
| changes-requested | in-review | agent (patcher) | fixes pushed |
| in-review | approved | agent (reviewer) | verdict APPROVE |
| blocked \| ready \| claimed \| in-review \| changes-requested \| approved | done | reconcile | PR with this `task_id` merged into the node's `target_branch` (GC42). `claimed` covers a merge that lands before the label edit; `blocked`/`ready` cover label drift and human-driven PRs (reconcile rule 3: any open status). |
| ready | done | reconcile | `kind=="epic"` only: an open epic with ≥ 1 child, every child `done` or `cancelled` (reconcile rule 7, GC45) |
| claimed | done | promote | promote node with identical trees (§9) |
| in-review | done | reconcile | promotion PR merged (§9) |
| any open status | cancelled | human | `graph.sh transition <id> cancelled --human <name>`; any other actor gets exit 2 (GC47) |

- `needs_human` is a flag, not a status. `graph.sh flag <id> needs-human
  on|off` sets and clears it.
- `graph.sh transition <id> <to> [--actor agent|human|promote]` validates
  `(from, to, actor)` and exits 2 on an illegal transition, without writing (GC8).
- Reconcile's own fix records are validated against the same table before being
  applied. A record that fails validation is printed as a warning and skipped
  (GC65).

**`reconcile.jq`.** Input: `{nodes, prs, now}`. `prs` contains the open PRs plus the
PRs merged since the oldest open node was created; §6.2 and §6.3 describe the
backend queries. Output: a list of fix records `{op, id, from, to, reason}`. The
backend applies them, and `--fix` prints them as `fix: …` lines.

1. `blocked → ready` when every dep is `done`. Never while `needs_human`.
2. `ready → blocked` when deps are unmet.
3. **Merged PR → done, on every backend.** An agent PR with `task_id` X (X in any
   open status),
   `state=="merged"` and `base == X.target_branch` sets X to `done` (GC25, GC42).
   On github the backend applies this by closing the issue with `--reason completed`
   and a comment naming the PR. That is needed because GitHub's closing keywords
   only act on PRs into the default branch.
4. **Open PR → in-review.** An open agent PR with `task_id` X while X is `claimed`,
   `ready` or `blocked` sets X to `in-review` (GC43). `ready`/`blocked` are status
   drift: the claim was cleared or the status relabelled while the PR stayed open
   (GC69). Rule 4 is applied before rules 1 and 2, so an open PR outranks the deps
   and a drifted node is not first moved between `ready` and `blocked`.
5. **Stale agent claims.** A claim with `by=="agent"`, no open PR for the node,
   `now - updated_at > 4h` and `needs_human` false is released to `ready`, with the
   reason `RECLAIMED` (GC24). The github backend keeps the
   `RECLAIMED: agent claim was idle >4h…` comment text verbatim.
6. **Stale human claims.** A claim with `by=="human"` and `now - updated_at > 72h`
   gets exactly one `ping` record, emitted only when `pinged_at` is null (§4.1).
   Human claims are never released (GC44).
7. **Epics done.** An open epic with ≥ 1 child is set to `done` when every child is
   `done` or `cancelled` (GC45). Parity with v0.1.4, which closed an epic when every
   child was CLOSED.
8. **Warnings, never mutations,** printed on stderr:
   - `blocked on cancelled dep <id>`
   - `unknown dep <id>`
   - `cycle: <id> → … → <id>`

**`tick-plan.jq`.** Input: `{nodes, prs, flags: {parallel, auto_merge}, now}`.
Output: `{mode, actions: [{action, pr?, id?, reason}], board: {<status>: count},
waiting: [string]}`, where `action` is one of `merge`, `patch`, `rebase`, `review`,
`promote`, `start`.

Only **agent PRs** (`agent==true`) with a linked node ever produce PR actions. The
rules, in priority order, encode today's `delivery-tick` (GC12–GC20, GC39):

1. **merge.** Only when `auto_merge` is set. The PR is `open`, `mergeable=="clean"`
   and `checks` is `success` **or `none`** (parity: v0.1.4's "every check SUCCESS"
   is vacuously true with no checks). Its node is a `task` with status `approved`.
   The PR has no `needs-human` label, and the node's `needs_human` is false.
2. **patch.** The node is `changes-requested` and `needs_human` is false. There is
   **no iteration filter** (parity with v0.1.4). At `patch_iteration == 3` the
   dispatched `patch-task` performs the escalation itself: it sets `needs-human`,
   runs `NOTIFY_ESCALATE_CMD` and stops. So a task at the cap is escalated once
   rather than silently stranded (GC62).
3. **rebase.** The node is `approved`, `mergeable=="conflicting"`,
   `patch_iteration < 3`, and `needs_human` is false.
4. **review.** The node is `in-review`, `reviewed_at_head` is false, and
   `needs_human` is false; a PR labeled `needs-human` is not reviewed either
   (parity with v0.1.4: never act on needs-human items).
5. **promote.** The node is a promote node with status `ready` and `needs_human`
   false (§9). A promote node whose gate went red is not re-run every tick
   (GC19).
6. **start.** The ready set, in `ready.jq` order, minus every node with an open
   agent PR. Such a node is never started, whatever its status (a cleared claim or
   a drifted `ready` label would otherwise spawn a duplicate implementation, and a
   module-less node has no lock to stop it); it is listed in `waiting`, and
   reconcile rule 4 repairs its status (GC70).

**Promotion PRs never produce merge actions**, even under `auto_merge` (GC39).

**Batch rules:**
- A node has exactly one status, so each PR matches at most one of patch, rebase and
  review. "One action per PR" holds by construction, and GC13 asserts it.
- Merge and promote actions are deterministic scripts, not agents. They run before
  the agent batch and do **not** count against N.
- In-flight = open agent PRs (approved-but-unmerged ones included) + `claimed` task
  nodes. Starts fill `cap - in-flight`.
- Each start's `(target_branch, module)` must be distinct from every in-flight
  task's and from every other start's. The module lock is per target branch (GC18).
  Nodes with no module are exempt.

**Modes:**
- Serial emits only the first non-merge, non-promote agent action. For starts it
  considers **only the top ready task**, with start cap 2. All merge and promote
  actions are still emitted ahead of it.
- Parallel takes agent actions in priority order, truncated to N. `tick-plan.sh`
  parses the flag (GC17): bare → 3; non-integer → 3; > 16 → 16; ≤ 1 → serial.

## 6. Graph backends

### 6.1 Backend contract

`backends/graph-<name>.sh <primitive> [args]`, sourced config, exit 0 on success:

| Primitive | Contract |
|---|---|
| `list` | **All** nodes (open and closed) as a JSON array of §4.1 nodes. Done and cancelled children are needed for started-epic ordering and epic completion, and closed deps are needed for readiness. The ceiling is `LIST_LIMIT` (github; GC10). |
| `show <id>` | One node. `--format md` renders title + body for agent prompts. |
| `create <node-json>` | Creates a node, returns its `id`. |
| `update <id> <patch-json>` | Merges the patch fields (status, claim, needs_human, …). Used by `transition`/`reconcile`. |
| `claim <id> <actor> <run>` | **Atomic** test-and-set: succeeds only if the node is still `ready` with no claim. Exit 0 = owned, 1 = lost or not claimable. |
| `release <id> <reason>` | Clears the claim and returns the node to `ready` (or leaves `needs_human` set). |
| `comment <id> <text>` | Durable note on the node (github: issue comment; local: journal event). |
| `link <id> <dep-id> [via]` | Adds a blocking edge. github: `gh issue edit <id> --add-blocked-by <dep>`; `via` is recorded as a `Depends-on: #<dep> (via: …)` body line, because native links carry no label. local: appends to `deps`. |
| `flag <id> needs-human on\|off` | Sets or clears `needs_human` (github: the `needs-human` label). |

`graph.sh` adds:
- `ready`;
- `reconcile [--fix]`;
- `transition <id> <to> [--actor …]`;
- `claim <id> <actor>` (policy pre-check, then the backend's atomic `claim`);
- `migrate`, github only (§6.2);
- `export`, which dumps nodes as JSON for backup and debugging.

### 6.2 `github` backend

- **Reads** one paginated `gh issue list --state all --json
  number,title,state,stateReason,labels,assignees,body,createdAt,updatedAt,blockedBy,parent,comments`
  with `--limit "$LIST_LIMIT"`. If the result count equals `LIST_LIMIT`, it exits 3
  naming the key (GC10). v0.1.4 silently truncated at 500/1000 and read out-of-window
  deps as OPEN. `gh pr list` is never called without an explicit `--limit`; v0.1.4
  used the default 30, which blinded the stale-claim reaper (GC33).
- **PRs for reconcile.** Reconcile receives `forge.sh pr-list --state open` plus
  `forge.sh pr-list --state merged --since <oldest open node's created_at>`. Rule 3
  needs the merged set; §7.3 maps the merged feed per forge (GC67).
- **Native relations.** `blockedBy.nodes[].number` and `parent.number` (shape
  verified 2026-11-08: `{"blockedBy":{"nodes":[{"number":7,"state":"OPEN",…}],"totalCount":3},"parent":{"number":1,…}}`).
  Requires gh ≥ 2.94.0. On older gh (detected by `gh --version`), the backend reads
  without the `blockedBy,parent` fields, uses text edges only, and prints one warning
  per invocation: `gh < 2.94.0: native relations ignored` (GC56).
  - Native relations on GitHub Enterprise Server need GHES ≥ 3.19 (UNVERIFIED).
  - The page size of nested `blockedBy` connections under `gh issue list` is
    UNVERIFIED. When `totalCount` exceeds the returned `nodes`, the backend re-reads
    that issue with `gh issue view --json blockedBy` (GC64).
- **Claims are unchanged.** The comment-ordered Lamport lock (`lib/claim-winner.jq`,
  `lib/orphan-claims.jq`) is reused as is; GitHub offers no compare-and-set on
  assignment.
- **Writes:**
  - `create` uses `gh issue create --blocked-by … --parent …` plus labels and the
    `Delivery-Target:` / `Delivery-Plan:` body lines.
  - status changes are label edits, as today.
  - `done`/`cancelled` are issue close with `--reason completed|"not planned"`.
- **`graph.sh migrate`** is idempotent. For every open task, it adds a native
  blocked-by for each legacy `Depends-on:` ref and sets the native parent from
  `Part of epic #E`. Text lines are left in place (GC48).
  - It refuses to exceed 50 blockers per issue: it prints the offender and exits 1.
    The cap is from GitHub's changelog of 2025-08-21: "You can link up to 50 issues
    for each relationship type". It is not in the REST reference, so it is enforced
    defensively.
  - The cap only affects `migrate` and `plan.sh apply` edge creation. §9's design
    does not depend on its exact value.
- **Labels added to the taxonomy:** `promote` (node kind).

### 6.3 `local` backend

**Store.** `STATE_DIR`, defaulting (when empty) to `$(git rev-parse
--path-format=absolute --git-common-dir)/delivery`. Every worktree of the clone
resolves the same directory, it is never tracked, and it survives branch switches
(GC27).

```
<STATE_DIR>/
  store.json          {"schema":1,"created_at":…}
  epics/<epic-id>.json {"schema":1,"epic":<node>,"nodes":[<task|promote nodes>]}
  events.jsonl        append-only journal (one JSON object per line)
  lock/               present only while held; contains owner (host pid run ts)
```

- Nodes whose `epic` is null live in `epics/inbox.json`.
- **Ids.**
  - Plan-applied nodes use their plan id.
  - `apply` refuses an id that already exists with a different `plan_ref`, so ids
    stay unique across plans (GC35).
  - `graph.sh create` without an id assigns `<epic-id>-<n>`, with `n` = 1 + the
    highest existing numeric suffix in that epic (GC66).
- **Minimum git.** `--path-format` needs git ≥ 2.31; `init` checks it.
- The epic node itself is in its file's `epic` field.
- `schema` mismatch → refuse with the expected vs found version. No implicit
  migrations.

**Lock.**

Every mutating primitive runs inside `with_lock`, which:
1. Calls `mkdir "$STATE_DIR/lock"`. `mkdir` is atomic on POSIX; `flock` is not used
   because macOS lacks it.
2. Immediately writes `lock/owner` as `host pid run epoch`.
3. On `mkdir` failure, retries with backoff for up to `LOCK_WAIT_SECONDS`, then exits
   75 (EX_TEMPFAIL). `LOCK_WAIT_SECONDS` is an environment-only knob, default 30,
   which lets tests shorten it.
4. Runs the critical section.
5. Removes the lock in a trap: `rm -rf "$STATE_DIR/lock"`.

A lock is **stale** only when all of the following hold:
- `lock/owner` exists. A lock with no owner file is a holder between steps 1 and 2,
  and is treated as live.
- The owner's host equals this host.
- The owner's pid is not alive. `kill -0` must fail with ESRCH; EPERM means alive.
- It is older than `LOCK_STALE_SECONDS` (default 120), judged by the epoch in the
  owner line, never by file timestamps.

Breaking a stale lock is itself serialized:
1. The breaker takes `mkdir "$STATE_DIR/lock.break"`. It writes the same owner line
   as the lock. A `lock.break` is itself stale only under the same rule as `lock`:
   its owner on this host with a dead pid, judged by the epoch in its owner file.
   No `stat` is needed. A stale `lock.break` is removed by re-checking the same
   owner line under its own `mkdir lock.break.reap` step; that step's owner is
   checked the same way, and a crash there needs operator cleanup (`graph.sh
   unlock --force`).
2. It re-reads `lock/owner` and re-checks staleness against the **same owner
   line** it judged stale.
3. Only then does it remove `lock` and append a `lock-broken` event.
4. It releases `lock.break`, then retries step 1.

So two concurrent breakers can never delete a lock that a third process acquired in
between (GC22).
- Readers (`list`, `show`) take no lock. Writers replace files atomically: write
  `<file>.tmp.$$` in the same directory, then `mv` it over the target. A reader
  therefore always sees a whole file.

**Journal.**
- Every mutation appends `{ts, actor, run, op, id, from, to, body}` to `events.jsonl`
  inside the same lock. `op` is one of `create` | `claim` | `release` | `reclaim` |
  `transition` | `comment` | `link` | `apply` | `lock-broken`.
- The epic files are the source of truth. The journal is the audit trail, and in
  v0.3 the metrics input. `graph.sh show <id>` prints the node's last 10 events.

**Claim.**
- `with_lock`: re-read the node, require `status=="ready"` and `claim==null`, then
  set the claim (`by: "agent"`) and `status: "claimed"`, and append a `claim` event
  (GC21).
- A human claim is `graph.sh claim <id> --human <name>` (`by: "human"`). It is never
  auto-released, as with GitHub UI claims.

**Ground truth.**
- `reconcile` receives the same PR sets as on github (§6.2): open PRs, plus PRs merged
  since the oldest open node was created. This is how a merge on the forge becomes
  `done` locally (GC25).
- Precedence: forge PR merged > forge PR open > stored status.

**Visibility.** With no issue tracker, a PR body must stand alone:
- `next-task` copies the node's Context and Acceptance criteria into it, as
  `forge.sh` markdown;
- `task-status` renders the board from `graph.sh list`.

## 7. Forge seam

### 7.1 Contract — `forge.sh <op>` → `backends/forge-$FORGE.sh`

| Op | Contract |
|---|---|
| `whoami` | The login of the authenticated account. |
| `pr-create --head H --base B --title T --body-file F [--draft]` | Returns `{number, url}`. |
| `pr-view <n>` | A §4.2 PR, including `patch_iteration` and `reviewed_at_head`. |
| `pr-list [--state open\|merged] [--since ISO]` | All matching PRs, **fully paginated** (GC32). Elements carry every §4.2 field. When the forge's list endpoint omits a field (GitLab `head_pipeline`; GitHub `comments`/`reviews` used for `patch_iteration` and `reviewed_at_head`), the adapter hydrates it per PR. |
| `pr-find --head H` | The open PR for a head branch, or empty. |
| `pr-review <n> approve\|request-changes\|comment --sha S --body-file F` | Posts a verdict and returns `{posted, form: "formal"\|"comment", url}`. The adapter appends `Reviewed-Head: S` to the body. If the forge rejects a self-review, it falls back to a comment-form review with the same body (GC29). If `*_REVIEW_TOKEN` is set, it posts under that identity instead (GC58). |
| `pr-reviews <n>` | `[{author, verdict, body, at, commit}]`, used to verify a verdict landed. |
| `pr-comment <n> --body-file F` / `pr-comments <n>` | Post / list plain comments. |
| `pr-merge <n> --method squash\|merge --sha S` | Merges only if the head is still S (GC30), then re-reads the PR and exits 0 **only if `state=="merged"`**. On github, `gh pr merge` without `--auto` can still enable auto-merge when requirements are pending; the re-read catches that, and the adapter then disables it (`gh pr merge --disable-auto`) and exits 1 (GC63). The source branch is deleted on squash. |
| `pr-set-base <n> <branch>` | Retarget the PR. |
| `pr-files <n>` / `pr-diff <n>` | Changed paths / unified diff. |
| `ci-failures <n>` | Best-effort failing-job log text. Exit 4 = unsupported: the patcher then reproduces the failure by running `GATE_CMD` locally. |

### 7.2 Adapters

- **github:**
  - `gh pr …`, with an explicit `--limit` on every list;
  - `gh pr view --json number,url,state,headRefName,baseRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup,body,labels,comments,reviews,author,closingIssuesReferences`;
  - `ci-failures` uses `gh run view --log-failed`.
- **gitlab:** `curl` against `${FORGE_URL}/api/v4/projects/<url-encoded FORGE_REPO>/merge_requests…`
  with header `PRIVATE-TOKEN: $GITLAB_TOKEN`.
- **gitea:** `curl` against `${FORGE_URL}/api/v1/repos/<owner>/<repo>/pulls…` with
  header `Authorization: token $GITEA_TOKEN`. Forgejo is covered by the same adapter.
  - It is a GitHub-compatible API fork. Divergences are recorded in the adapter
    header as they are found.
- **Defaults and tokens:**
  - `FORGE_URL` and `FORGE_REPO` default from `git remote get-url origin`, for both
    https and ssh remote forms.
  - Tokens come from the environment only. They are never stored in
    `.claude/delivery.conf` (a checked-in file).
- **`FORGE_DRY_RUN=1`** makes the curl adapters print `METHOD PATH` plus the JSON
  body instead of sending it. Tests assert against that (GC31).

### 7.3 Normalization map

Verified 2026-11-08 against docs.gitlab.com (REST v4) and the live Gitea
(`gitea.com/swagger.v1.json`, 29.0.0+dev) and Forgejo
(`codeberg.org/swagger.v1.json`) specs. "(src)" means confirmed in forge source code,
not in the docs.

| §4.2 field / op | github (`gh`) | gitlab (`/api/v4/projects/:id`, `:id` = URL-encoded path) | gitea / forgejo (`/api/v1/repos/{o}/{r}`) |
|---|---|---|---|
| `number` | `number` | `iid` (**never** the global `id`) | `number` |
| `state` | `OPEN`/`MERGED`/`CLOSED` | `opened`→open, `merged`→merged, `closed`/`locked`→closed | `merged==true`→merged; else `state` `open`/`closed` |
| `head`/`base`/`head_sha` | `headRefName`/`baseRefName`/`headRefOid` | `source_branch`/`target_branch`/`sha` | `head.ref`/`base.ref`/`head.sha` |
| `mergeable` | `mergeStateStatus` CLEAN→clean, DIRTY→conflicting, BLOCKED/UNSTABLE/BEHIND→blocked, else unknown | `detailed_merge_status`: `mergeable`→clean; `conflict`/`need_rebase`→conflicting; `unchecked`/`checking`/`preparing`/`approvals_syncing`/`ci_still_running`→unknown (re-poll); everything else→blocked | `mergeable` field: `true`→clean, `false`→conflicting, absent/null→unknown. Separately, a 405 "try again later" from the merge POST makes `pr-merge` re-poll, then exit 1. |
| `checks` | `statusCheckRollup` (every conclusion SUCCESS/NEUTRAL/SKIPPED→success; any FAILURE/ERROR/CANCELLED/TIMED_OUT/ACTION_REQUIRED/STARTUP_FAILURE→failure; else pending; empty→none) | `head_pipeline.status` (present only on the single-MR GET, so `pr-list` hydrates it): `success`→success; `failed`/`canceled`/`canceling`→failure; null→none; else pending | `GET /commits/{sha}/status`: `total_count==0`→none; `success`→success; `error`/`failure`→failure; `pending`→pending; `warning`/`skipped`→success (one statement in the adapter header; Gitea Actions posts one status per job (src)) |
| `pr-create` | `gh pr create` | `POST /merge_requests` `source_branch,target_branch,title,description` → `iid,web_url` | `POST /pulls` `head,base,title,body` → `number,html_url` |
| `pr-list` / `pr-find` | `gh pr list --limit $LIST_LIMIT` / `--head` | `GET /merge_requests?state=opened&per_page=100`, following `x-next-page` until empty (`x-total` is omitted above 10k) / `&source_branch=` | `GET /pulls?state=open&limit=<max_response_items>&page=n`, following `Link rel=next` / `GET /pulls/{base}/{head}` (Forgejo also has a `head` filter) |
| `pr-list --state merged --since T` | `gh pr list --state merged --search "merged:>=T" --limit $LIST_LIMIT` (gh has no `--since`) | `GET /merge_requests?state=merged&updated_after=T&per_page=100`, then client-side `merged_at >= T` | `GET /pulls?state=closed` paged; keep `merged==true && merged_at >= T`. The swagger has no `since`, so paging stops once `updated_at < T` with `sort=recentupdate`. |
| `pr-review` approve | `gh pr review --approve` | `POST /merge_requests/:iid/approve` with `sha` (409 if not head). The endpoint takes no body, so the verdict body (with `Reviewed-Head:`) is **also** posted as a note. | `POST /pulls/{n}/reviews` `event=APPROVED, commit_id` |
| `pr-review` request-changes | `--request-changes` | **No REST endpoint.** Always comment form: a note whose body starts `## Adversarial review — verdict: REQUEST_CHANGES` | `event=REQUEST_CHANGES` |
| self-review rejection | GitHub rejects on own PR | author approval is blocked by default (the setting is Premium+; behavior on Free is UNVERIFIED) | 422 "approve/reject your own pull is not allowed" (src); `COMMENT` is allowed |
| `pr-reviews` | `reviews` | `GET .../approvals` (`approved_by[].user.username`) + `GET .../notes` (verdict-prefixed, non-`system`) | `GET /pulls/{n}/reviews` (`state, user.login, commit_id, stale, dismissed`) |
| `pr-comment(s)` | `gh pr comment` / `comments` | `POST/GET .../notes` (`sort=asc`) | `POST/GET /issues/{n}/comments` (no documented pagination: use `since`) |
| `pr-merge` | `gh pr merge --squash\|--merge --match-head-commit S` | `PUT .../merge` `squash, should_remove_source_branch, sha` (405 not mergeable, 409 sha mismatch) | `POST /pulls/{n}/merge` `Do=squash\|merge, delete_branch_after_merge, head_commit_id` (409 conflicts / head out of date) |
| `pr-set-base` | `gh pr edit --base` | `PUT /merge_requests/:iid` `target_branch` | `PATCH /pulls/{n}` `base` |
| `pr-files` / `pr-diff` | `gh pr diff --name-only` / `gh pr diff` | `GET .../diffs` (`new_path`; `/changes` is deprecated) | `GET /pulls/{n}/files` / `GET /pulls/{n}.diff` |
| `ci-failures` | `gh run view --log-failed` | job traces of the head pipeline (best effort) | exit 4 (unsupported) |
| auth header | gh auth | `PRIVATE-TOKEN: $GITLAB_TOKEN` | `Authorization: token $GITEA_TOKEN` |

**Adapter rules from the verified contracts:**

- **Pin the head SHA on every verdict and merge** (`sha` / `commit_id` /
  `head_commit_id` / `--match-head-commit`). That way a push racing a verdict cannot
  be merged on.
- **`unknown` is re-polled, never merged.** Re-poll up to 3 times with backoff, then
  report `unknown` (GC57).
- **Separate reviewer identity, optional.** Self-review rejection is the norm on
  every forge. If `GITLAB_REVIEW_TOKEN` / `GITEA_REVIEW_TOKEN` / `GH_REVIEW_TOKEN` is
  set in the environment, `pr-review` posts under it, which restores formal reviews.
  Otherwise it posts the comment form, and the graph status is the verdict of record,
  as design spec §13.2 already specifies.
- **Merge style is project-level on GitLab.** The project's merge method decides
  whether `squash:false` produces a merge commit. On Gitea, a `Do` value the repo
  disallows returns 405. So `PROMOTE_MERGE_METHOD=merge` requires merge commits to
  be enabled on the forge. `init` prints this requirement, as it prints today's
  `gh repo edit` advice.
- **Forgejo uses `Do`.** Its spec names the merge field `Do`, Gitea's newer spec
  names it `do`, and Go decodes JSON case-insensitively. The adapter sends `Do`
  (works on both: UNVERIFIED against a live instance).
- **Unverified items:** GitLab rate-limit headers (the adapter backs off on 429
  regardless); fork-head PRs (out of scope: same-repo branches only).

## 8. Plan files

### 8.1 Schema — `PLANS_DIR/<plan>.plan.json` (default `docs/plans/`)

```json
{
  "schema": 1,
  "plan": "graph-portability",
  "spec": ["docs/delivery_graph_spec.md"],
  "target_branch": "release/0.2.0",
  "promote_to": "main",
  "epics": [
    {"id": "policy-core", "title": "Policy core", "goal": "…", "spec_refs": ["§5"]}
  ],
  "tasks": [
    {"id": "ready-policy", "epic": "policy-core", "title": "…", "module": "policy",
     "size": "M",
     "deps": [{"id": "node-schema", "via": "lib/node.jq validate_node"}],
     "context": "…",
     "criteria": ["`bash scripts/check.sh` passes", "…"],
     "scope": ["plugins/delivery-loop/scripts/lib/ready.jq"]}
  ]
}
```

- JSON, not YAML, so it is `jq`-native and needs no `yq`.
- `scope` is recorded now and enforced in v0.3.
- `deps[].id` may name a task in this plan, or an existing node (`"#42"` on the
  github backend, or a local id).

### 8.2 `plan.sh lint <file>`

Exits 1, listing every error, when any of the following holds. GC34 has one fixture
per bullet.
- the schema or field types are invalid;
- ids are duplicate or malformed;
- a dep is unresolved;
- the graph has a cycle (named in the error);
- a dep has no `via` (plan files require it; legacy backend edges do not);
- a `module` is not in `MODULES ∪ {infra, docs}`;
- a size is not S/M/L;
- `criteria` is empty;
- two plans in `PLANS_DIR` share a `target_branch` but give different `promote_to`.

`size: "L"` produces a warning, not an error. `L` stays a legal "split me" placeholder.

### 8.3 `plan.sh apply <file>`

Idempotent: it runs lint first, then creates whatever is missing and never deletes
anything (GC35).

- **Idempotency key.** A node's `plan_ref` is `<plan>/<id>`. On github it is stored
  as a `Delivery-Plan: <plan>/<id>` body line.
- **Drift.** An existing node whose title or body differs from the plan is
  **reported, not overwritten**: a `drift: <id> <field>` line on stderr, and exit 0
  (GC54).
- **Order:**
  1. epics;
  2. tasks, in topological order so dep ids resolve;
  3. then one **promote node** per plan, if `promote_to` is set (§9);
  4. then `graph.sh reconcile --fix`.
- On github, tasks are sub-issues of their epic issue and carry native blocked-by
  links (GC36).
- **Missing target branch.** If `target_branch` doesn't exist on the remote, apply
  creates it from `origin/<promote_to or BASE_BRANCH>` and pushes it, printing the
  exact `git push` first (GC53). This is the only branch-creating step.

### 8.4 `plan.sh render <file>`

Prints a Mermaid `flowchart TD`:
- one node per task, labeled `id: title [module/size]`;
- one edge per dep, labeled with `via`;
- epic subgraphs;
- the promote node (GC37).

`decompose` dry-run prints the table plus the render, so backlog approval reviews
the graph itself.

### 8.5 `decompose` flow

1. **Dry-run.** Write `PLANS_DIR/<plan>.plan.json` to the working tree (uncommitted),
   then lint and render it. Print the table and the Mermaid graph, then stop.
2. **`--create`.** Only after approval: commit the plan file (to the current branch,
   or by PR when the repo requires it), then run `plan.sh apply`.

## 9. Branch flow and promotion

- **Targets.** Each node has a `target_branch` (§4.1), default `BASE_BRANCH`.
  `task-worktree.sh` forks from `origin/<target_branch>`, `next-task` and
  `patch-task` rebase onto it, and `forge.sh pr-create --base <target_branch>`.
- **Missing target.** If the target is missing at worktree time, the script exits 1
  with an error that names `plan.sh apply` (GC38).
- **Merge methods.** Task PRs merge with `TASK_MERGE_METHOD` (default `squash`).
- **Promote node** (`kind: "promote"`), created by `plan.sh apply`:
  - `deps` = the plan's **epics**, not its tasks. That keeps a large plan under
    GitHub's 50-blocker cap (§6.2). Epics become `done` through
    reconcile rule 7.
  - It carries `target_branch` (T) and `promote_to` (P).
  - `next-task` never claims it: `ready.jq` admits only `kind=="task"`.
- **Promote action.** When a promote node's deps are all `done`, `tick-plan`
  emits `promote` for it (GC19). The tick runs `promote.sh <id>`, a deterministic
  script that takes no model judgment:
  1. Claim the node (actor `promote`).
  2. If `git diff --quiet origin/P origin/T` (identical trees), mark the node `done`
     with the note `nothing to promote` (GC49).
  3. Otherwise create a fresh worktree of `origin/T` and run `PROMOTE_GATE_CMD`
     (default `GATE_CMD`).
  4. If it is red: set `needs_human`, comment with the failing output, run
     `NOTIFY_ESCALATE_CMD`, release the claim, and exit 1 (GC50).
  5. If it is green:
     - open a PR with head T, base P, the title `Promote T → P`, a body listing the
       plan's done tasks, and `Delivery-Task: <promote id>`;
     - set the node to `in-review` (GC51).
- **Merging a promotion PR.**
  - A human merges it, with `PROMOTE_MERGE_METHOD` (default `merge`, which keeps
    ancestry).
  - **Never auto-merged in v0.2, even under `--auto-merge`** (GC39). Promotion has
    the largest blast radius in the loop.
  - Reconcile marks the node `done` when the PR merges.
- **Out of scope.** Keeping T in sync with P while work is in flight (merging P back
  into T) stays a human operation in v0.2. A conflicting promotion PR escalates.

## 10. Skill changes

| Skill | Change |
|---|---|
| `delivery-tick` | Reconcile (`graph.sh reconcile --fix`) → `tick-plan.sh [--parallel N] [--auto-merge]`. Merge actions run via `tick-merge.sh <pr> <sha>`. It re-reads the PR and re-applies the merge rule from §5. It exits 1 without merging if the PR is no longer eligible, for example because the head moved or checks went red (GC52). Otherwise it merges via `forge.sh pr-merge --method $TASK_MERGE_METHOD --sha`, then reconciles. Promote actions run via `promote.sh`. Agents are dispatched only for `patch`/`rebase`/`review`/`start`. The prose priority rules are deleted and replaced by "execute the plan's actions in order". |
| `next-task` | `graph.sh ready`/`claim`/`show --format md`/`transition`. The PR goes through `forge.sh pr-create --base <target_branch>`, with a body carrying `Delivery-Task:` and, on the local backend, the full task contract. |
| `review-task` | Reads the contract via `graph.sh show`, PR state via `forge.sh pr-view`/`pr-diff`. Posts via `forge.sh pr-review --sha <head_sha>` and verifies via `pr-reviews`. Verdict of record: `graph.sh transition`. |
| `patch-task` | `forge.sh pr-view`/`pr-comments`/`ci-failures`. Rebases onto `target_branch`. Iteration counter unchanged (a PR comment). |
| `deliver-task` | Passes node ids, not issue numbers. Otherwise unchanged. |
| `decompose` | §8.5. |
| `task-status` | `graph.sh list` + `forge.sh pr-list` → board. `--graph` prints Mermaid. `--reclaim` → `graph.sh reconcile --fix`. |
| `init` | Asks for or detects `GRAPH_BACKEND` and `FORGE`. The local backend skips labels and creates `STATE_DIR`. Checks forge auth via `forge.sh whoami`. gh is required only when either seam is github. Its repo-settings advice keeps merge commits **enabled**, because promotion merges with `PROMOTE_MERGE_METHOD=merge`. v0.1.4 advised `--enable-merge-commit=false`. |
| `author-spec` | Board reads via `graph.sh`. Docs-review verdict via `forge.sh pr-review <pr> comment --sha <head> --body-file F`. |
| `author-styleguides` | No change. |

## 11. Configuration

New keys. Each follows `CLAUDE.md`'s four-place rule:
1. `lib/config.sh`: `_DL_VARS`, the `:` default, and the `export` list.
2. The `delivery-init.sh` scaffold.
3. The README table.
4. Any skill that reads the key.

It also touches two further places: `delivery-config.sh`, which prints keys
explicitly, and the design spec §2.2 table. **All of them land in one task (A2)**,
because `config.sh`, `delivery-init.sh`, `delivery-config.sh` and the README are hub
files.

| Key | Default | Meaning |
|---|---|---|
| `GRAPH_BACKEND` | `github` | `github` \| `local`. |
| `STATE_DIR` | (empty → `<git-common-dir>/delivery`) | Local backend store. |
| `LOCK_STALE_SECONDS` | `120` | Local lock break threshold. |
| `LIST_LIMIT` | `5000` | github backend fetch ceiling; reaching it is an error, never a silent truncation. |
| `FORGE` | `github` | `github` \| `gitlab` \| `gitea`. |
| `FORGE_URL` | (derived from origin) | API base host, e.g. `https://gitlab.example.com`. |
| `FORGE_REPO` | (derived from origin) | `owner/repo` or GitLab `group/subgroup/project`. |
| `PLANS_DIR` | `docs/plans/` | Where plan files live. |
| `TASK_MERGE_METHOD` | `squash` | Task PR merge method. |
| `PROMOTE_MERGE_METHOD` | `merge` | Promotion PR merge method. |
| `PROMOTE_GATE_CMD` | (empty → `GATE_CMD`) | Gate run on the target branch before a promotion PR. |

Environment only, never in `.claude/delivery.conf`:
- `GITLAB_TOKEN` / `GITEA_TOKEN`: forge auth.
- `GH_REVIEW_TOKEN` / `GITLAB_REVIEW_TOKEN` / `GITEA_REVIEW_TOKEN`: the optional
  reviewer identity (§7.3).
- `LOCK_WAIT_SECONDS` (default 30): the local lock wait (§6.3).

**`delivery-config.sh --check`** validates the combination and exits 1 with a
message:
- `GRAPH_BACKEND=github` requires `FORGE=github` (GC40);
- unknown backend or forge values are rejected, listing the valid ones (GC41);
- a gitlab/gitea forge with an unset token is rejected (GC59).

`graph.sh`, `forge.sh`, `tick-plan.sh`, `plan.sh` and `promote.sh` each run the
check once at start-up, and exit 1 on an invalid combination before doing any I/O
(GC59).

## 12. Golden cases

Fixtures live in `plugins/delivery-loop/scripts/tests/fixtures/`. A compound case may
have assertions owned by different tasks: for example, GC2's "not ready" belongs to
A4, its reconcile warning to A5. The cutline (§17) names, per task, the test file and
the case assertions it owns.

**Policy:**

| # | Given | Expect |
|---|---|---|
| GC1 | task, all deps `done`, no claim, size S | in `ready` |
| GC2 | dep `cancelled` (github: CLOSED + NOT_PLANNED) | not ready; reconcile stderr `blocked on cancelled dep <id>` |
| GC3 | size L | never ready |
| GC4 | `needs_human`, deps done, status blocked | not ready; reconcile emits no `blocked → ready` |
| GC5 | 4 ready tasks varying started-epic/unblocks/size/age | order = v0.1.4 order (fixture copied from v0.1.4 output) |
| GC6 | deps A→B→A | lint error names the cycle; reconcile warns `cycle:`; neither ready |
| GC7 | dep on nonexistent id | lint error; at runtime not ready + `unknown dep` warning |
| GC8 | `transition` ready→approved | exit 2, store unchanged |
| GC9 | github issue CLOSED+COMPLETED / CLOSED+NOT_PLANNED | normalized `done` / `cancelled` |
| GC10 | github list returns exactly `LIST_LIMIT` items | exit 3, message names `LIST_LIMIT` |
| GC11 | body `Depends-on: #3`, native blockedBy #3 and #4 | `deps` ids `["3","4"]` |
| GC42 | approved node X, target `release/x` (not the default branch); merged agent PR with `Delivery-Task: X`, base `release/x` | reconcile record X → `done`; the github backend closes the issue `completed` with a comment naming the PR |
| GC43 | node `claimed`; open agent PR with its `task_id` | reconcile record `claimed → in-review` |
| GC69 | open agent PRs for a `ready` node, a `blocked` node whose deps are done, and a `ready` node with an unmet dep; a `ready` node with only a non-agent PR | reconcile records `ready → in-review`, `blocked → in-review`, `ready → in-review` (no `blocked → ready` or `ready → blocked` first); none for the non-agent PR |
| GC44 | human claim idle 73h, `pinged_at` null / set | exactly one `ping` record / none; never released |
| GC45 | epic with children `done` + `cancelled`, one of them linked only through the epic's `- [ ] #N` checklist (github fixture) | epic → `done`; the checklist-only child counts toward completion, and its own `epic` stays null (parity) |
| GC47 | `transition <id> cancelled` with `--actor agent` / `--human ann` | exit 2, unchanged / `cancelled` |
| GC65 | reconcile produces a fix record that the transition table rejects (fixture: a `done` node and a stale-claim rule match) | warning on stderr, record not applied, other records applied |
| GC61 | `task-queue.sh` against the GC5 github fixture | stdout byte-identical to the captured v0.1.4 output |

**Tick plan:**

| # | Given | Expect |
|---|---|---|
| GC12 | serial; one changes-requested PR, one review-pending PR, one ready task | `[patch]` |
| GC13 | `--parallel 3`; one changes-requested PR (module c); ready tasks in modules a, a, b | patch + starts for a and b; second a skipped; each PR in at most one action |
| GC14 | cap reached, counting an approved-unmerged PR | no `start` |
| GC15 | `--auto-merge`; A approved+clean+`success`; B approved+conflicting; C approved+clean+`none` | `merge A`, `merge C`, `rebase B` |
| GC16 | approved+conflicting PR with `patch_iteration` 3 | no rebase; listed in `waiting` |
| GC17 | `--parallel` / `--parallel x` / `--parallel 20` / `--parallel 1` | mode parallel N=3 / 3 / 16 / serial |
| GC18 | two ready tasks, same module, different `target_branch` | both started (parallel 2) |
| GC19 | promote node whose epics are all done, no open promotion PR / same with `needs_human` set | `[promote <id>]` / no promote action, listed in `waiting` |
| GC20 | nothing actionable | `actions: []`, `waiting` names the reason |
| GC39 | `--auto-merge`; open promotion PR, clean+success | no `merge` action for it; `tick-merge.sh` on it exits 1 |
| GC62 | changes-requested agent PR at `patch_iteration` 3 | `patch` action is emitted (the patcher escalates) |
| GC70 | (a) claim-less, module-less `ready` node with an open agent PR, plus a free ready task; (b) `--auto-merge`; two approved clean PRs for one task, and an approved clean PR whose `base` differs from its node's `target_branch` | (a) no `start` for the node (listed in `waiting`), the free task starts; (b) one `merge`, the lower PR number; no `merge` for the off-base PR; both listed in `waiting` |

**Local backend:**

| # | Given | Expect |
|---|---|---|
| GC21 | 8 concurrent `graph.sh claim X` | exactly one exit 0, seven exit 1; one `claim` event |
| GC22 | (a) lock with a dead pid on this host, older than `LOCK_STALE_SECONDS`; (b) a live lock and `LOCK_WAIT_SECONDS=2`; (c) two concurrent breakers of one stale lock, plus a third process that acquires in between; (d) a lock dir with no `owner` | (a) broken, one `lock-broken` event; (b) exit 75; (c) exactly one `lock-broken` event, and the third process's lock survives; (d) treated as live |
| GC23 | a write completes | no `*.tmp.*` files remain; every epic file parses |
| GC24 | agent claim older than 4h, no PR | reconcile record `RECLAIMED`; local: node `ready` + `reclaim` event |
| GC25 | forge fixture: PR merged with `Delivery-Task: x` | x `done`; dependent → `ready` |
| GC26 | board F in github fixture shape and local store shape | byte-identical `graph.sh ready` and `tick-plan.sh` output |
| GC27 | claim from worktree A | visible from worktree B (same `STATE_DIR`) |

**Forge:**

| # | Given | Expect |
|---|---|---|
| GC28 | captured or doc-derived responses per adapter (open/merged/closed; conflict; checks pass/pending/fail/none; a `Reviewed-Head:` verdict) | normalized §4.2 PRs equal the expected fixtures, `reviewed_at_head` included |
| GC29 | fixture: formal review rejected as self-review (gitlab: no request-changes endpoint, so always a note) | comment-form fallback, `{posted:true, form:"comment"}`, body ends `Reviewed-Head: <sha>` |
| GC30 | `pr-merge --sha` with a stale sha | exit nonzero, no merge request sent (dry-run log) |
| GC31 | `FORGE_DRY_RUN=1 FORGE=gitlab forge.sh pr-create …` | prints `POST /api/v4/projects/<enc>/merge_requests` + body with source/target/title |
| GC32 | two-page list fixture | all PRs from both pages |
| GC33 | PR whose body only *mentions* `#12`; PR with `Delivery-Task: 12` | `task_id` null / `"12"`; reaper sees the second as #12's open PR and does not reclaim |
| GC46 | 5 PRs, each carrying exactly one linkage form (trailer; `Closes #7`; `task/x--s` head; `task/7-s` head; none) plus one carrying both a trailer and `Closes` | `task_id` per §4.3 precedence; the trailer wins |
| GC57 | forge reports mergeability as computing on 3 polls | `mergeable:"unknown"`; tick-plan emits no merge |
| GC58 | `*_REVIEW_TOKEN` set | dry-run request carries the review token; `form:"formal"` |
| GC63 | github `pr-merge` where the post-merge re-read shows `state:open` with auto-merge enabled (gh shim) | `gh pr merge --disable-auto` invoked; exit 1 |
| GC67 | merged-PR feed with `--since T`: fixtures with PRs merged before and after T, plus a closed-unmerged PR (gitea) | only PRs merged at or after T; github shim called with `--search "merged:>=T"`; gitea stops paging once `updated_at < T` |

**Plans, branches, init, config:**

| # | Given | Expect |
|---|---|---|
| GC34 | valid plan / one fixture per §8.2 error bullet / a `size: "L"` task | pass / exit 1 naming that error / exit 0 with an `L` warning |
| GC35 | `apply` twice (local); then a second plan reusing an id | second run creates 0 nodes; id reuse → exit 1 |
| GC36 | `apply` (github, gh shim) | epic issue, tasks created with `--parent` and `--blocked-by` |
| GC37 | `render` on the GC34 valid plan | Mermaid with one labeled edge per dep |
| GC38 | `task-worktree.sh` on a node whose target branch is missing | exit 1, message names `plan.sh apply` |
| GC48 | `graph.sh migrate` twice (gh shim); an issue needing 51 blockers | first run adds native edges and leaves `Depends-on:` text in the body; second run issues 0 edits; exit 1 naming the issue |
| GC64 | github issue whose `blockedBy.totalCount` (3) exceeds the returned `nodes` (2) | backend re-reads it via `gh issue view --json blockedBy`; `deps` has 3 ids |
| GC66 | local `graph.sh create` without an id in epic `auth` holding `auth-1`, `auth-7` | new id `auth-8` |
| GC49 | promote node, identical trees | `done`, note `nothing to promote`, no PR |
| GC50 | promote node, red `PROMOTE_GATE_CMD` | `needs_human`, claim released, no PR, exit 1 |
| GC51 | promote node, green gate | PR head T base P, body contains `Delivery-Task: <id>`; node `in-review` |
| GC52 | `tick-merge.sh <pr> <sha>` when the head moved / checks became `failure` | exit 1, no merge request |
| GC53 | `apply` with a missing target branch (git shim) | prints, then runs, `git push origin origin/<P>:refs/heads/<T>` |
| GC54 | `apply` where an existing node's title differs | `drift: <id> title`, node unchanged, exit 0 |
| GC55 | worktree for id `ready-policy`; an existing dir `task-ready-policy-extra--x`; numeric id 12 with a legacy dir `task-12-old` | creates `task-ready-policy--<slug>` (no false match); reuses `task-12-old` |
| GC56 | gh shim reporting 2.93.0 | text edges only, one warning line |
| GC59 | `FORGE=gitlab`, `GITLAB_TOKEN` unset; each of `graph.sh`, `forge.sh`, `tick-plan.sh`, `plan.sh`, `promote.sh` under an invalid config | `--check` exit 1; every entry point exits 1 with no backend/forge call (shim log empty) |
| GC40 | `GRAPH_BACKEND=github FORGE=gitlab GITLAB_TOKEN=x` | `--check` exit 1 |
| GC41 | `GRAPH_BACKEND=sqlite` | `--check` exit 1, lists `github local` |
| GC60 | `delivery-init.sh` with `GRAPH_BACKEND=local FORGE=gitea GITEA_TOKEN=x` in a temp repo (gh shim fails if called; forge dry-run) | `STATE_DIR` created; zero gh calls; conf scaffold contains every §11 key; printed advice has no `--enable-merge-commit=false` |

## 13. Testing and the gate

- **Discovery.** `scripts/check.sh` discovers `plugins/delivery-loop/scripts/tests/*-test.sh`
  by glob instead of naming files (task A1), so later tasks never edit the gate to
  register a test.
- **The gate stays offline.**
  - github and forge tests use captured or doc-derived JSON fixtures, with `gh` and
    `git` shims placed on `PATH` that record their calls.
  - curl adapters are tested via `FORGE_DRY_RUN`.
  - Live-forge smoke tests are runbook steps, not gate steps.
- **Local-backend tests** run in a throwaway repo under `${TMPDIR:-/tmp}` created by
  the test itself.
- **bash 3.2.** The gate's lint fails on `declare -A`, `mapfile`, `readarray`,
  `${x,,}`, `${x^^}`, `&>>`, `|&` and `coproc` anywhere under
  `plugins/delivery-loop/scripts/`. Empty-array expansion stays guarded under
  `set -u`, as `CLAUDE.md` requires.

## 14. Rollout (informative)

1. **Release branch.** `release/0.2.0` is cut from `main`, and every plan task's
   `target_branch` is `release/0.2.0`.
   - The release branch's `.claude/delivery.conf` sets `BASE_BRANCH=release/0.2.0`
     and `MODULES="policy graph forge plan engine skills"`.
   - Module path ownership (all under `plugins/delivery-loop/scripts/`; the first
     matching row wins):

     | Module | Paths |
     |---|---|
     | `plan` | `plan.sh`, `lib/plan-*.jq` |
     | `policy` | other `lib/*.jq`, `tick-plan.sh` |
     | `graph` | `graph.sh`, `backends/graph-*`, `task-queue.sh`, `claim-task.sh` |
     | `forge` | `forge.sh`, `backends/forge-*` |
     | `engine` | every other script |
     | `skills` | `skills/**` |

   - Each module owns the tests named after its files.
2. **Dogfood bootstrap (H0, before decomposition).** The installed v0.1.4 cannot
   target a non-default branch. `next-task` runs `gh pr create` without `--base`,
   and GitHub's closing keywords only fire on the default branch, so merged task PRs
   would never close their issues. Hence:
   - A small bootstrap PR to `release/0.2.0`, outside the plan:
     - `next-task` passes `--base "$BASE_BRANCH"`.
     - `task-queue.sh --fix` closes an open task as completed when a merged PR into
       `BASE_BRANCH` carries `Closes #N` for it.
     - Both manifests stay `0.1.4`.
   - The operator's runtime install then switches to a **pinned local checkout** of
     `release/0.2.0` at the bootstrap commit: a detached worktree, added as the
     `delivery-loop` marketplace. The loop runs that code while the release branch
     moves under it, and nothing reaches `main`.
   - After G3 merges, the marketplace is switched back to `blakemartz/delivery-loop`.
3. **Test against the release branch.** From a `release/0.2.0` checkout, run
   `CLAUDE_CONFIG_DIR=$(mktemp -d) claude plugin marketplace add ./ && … install …`.
   Then pilot the local backend on a scratch repo against each forge available to the
   operator.
4. **Promotion.** The last task (G3) bumps both manifests to `0.2.0` and restores
   `BASE_BRANCH=main`. A human then opens and merges the promotion PR
   `release/0.2.0 → main` (merge commit), and runs
   `claude plugin tag ./plugins/delivery-loop && git push --tags`.

## 15. Deferred

**v0.3 "gates & learning", to be specced separately:**
- deterministic write-scope check against `scope`;
- gate-tamper guard (diffs to the gate, tests or CI are high-risk);
- holdout `HOLDOUT_CMD`;
- risk lanes for auto-merge;
- structured review verdicts (UNIT/VERDICT/REASON/EVIDENCE/SCOPE);
- a re-plan edge at the patch cap, with fault-side tagging;
- a `lessons.jsonl` learning edge with expiry, and a lesson → styleguide → gate
  promotion ladder;
- `task-status --metrics`;
- stacked dependent tasks via GitHub stacked PRs (`STACK_MODE`).

**Later:**
- local-backend cross-machine sync (a state ref pushed with
  `--force-with-lease=<ref>:<old>` CAS);
- multi-hop promotion (`develop → qa → main`);
- back-merging P into T;
- a no-forge local mode;
- node kinds `human`, `contract`, `join`;
- critical-path ordering;
- a Claude Code `workflows/` implementation of the per-task pipeline.

## 16. Cross-doc alignment

**Design spec** (`agentic_delivery_spec.md`), owned by G1:
- Keep §1–§14 numbering.
- Add §15 Graph backends, §16 Forges, §17 Branch flow & promotion, §18 Plan files.
- Amend:
  - §2/§2.2: the thesis generalized beyond GitHub, and the config table;
  - §5: the transition table replaced by this spec's §5 table;
  - §5.1: precedence includes forge PR state;
  - §6: the tick runs `tick-plan.sh`;
  - §7.1: ready semantics for cancelled deps, plus the started-epic ordering, which
    the v0.1.4 text already omits;
  - §10: the `Delivery-Task:` and `Reviewed-Head:` trailers;
  - §13.2: generalized to every forge.

**Runbook**, owned by G1: local-backend operation, `STATE_DIR` backup
(`graph.sh export`), forge tokens and reviewer tokens, the release-branch workflow,
the promotion step, and keeping merge commits enabled (§7 recommended settings).

**Root README**, owned by G1:
- "How it works" idea 1 generalized beyond GitHub.
- The config table.
- Prerequisites per seam.
- A new "Branch flow" section.
- The recommended `gh repo edit` line no longer passes `--enable-merge-commit=false`.

**Plugin `plugins/delivery-loop/README.md`**, owned by G1: the script inventory.

**Plugin `docs/README.md`**, owned by G1: links to design spec §15–§18.

**`CLAUDE.md`:**
- Done in this PR: the module list, and the release-branch bump exception.
- Owned by G1:
  - "What this is": no longer GitHub-only;
  - the Layout tree: `graph.sh`, `forge.sh`, `plan.sh`, `tick-plan.sh`,
    `promote.sh`, `tick-merge.sh`, `backends/`;
  - "Verify a change": the gate runs every test by glob and the bash-3.2 lint;
  - the config-key list;
  - the four-place rule, which gains `delivery-config.sh`.

**`delivery-init.sh` and the `init` skill:** their repo-settings advice keeps merge
commits enabled. The script is owned by I1, the skill by F3.

**Registration:** this file is `docs/delivery_graph_spec.md`, matched by
`SPEC_SOURCES="docs/*_spec.md"`.

## 17. Decompose-ready cutline

The plan targets `release/0.2.0` and promotes to `main`. Paths are relative to
`plugins/delivery-loop/scripts/` unless they start with `plugins/`, `scripts/` or a
repo-root file. Every task's criteria implicitly include "`bash scripts/check.sh`
passes". On the release branch, no task bumps the version except G3 (`CLAUDE.md`
exception).

| ID | Module | Size | Depends on (via) | Owns (golden-case assertions) and acceptance criteria beyond the gate |
|---|---|---|---|---|
| A1 test-discovery | infra | S | — | `scripts/check.sh` runs every `plugins/delivery-loop/scripts/tests/*-test.sh` via a glob loop; `grep -c -e 'claim-winner-test.sh' -e 'orphan-claims-test.sh' scripts/check.sh` prints `0`; the §13 bash-3.2 lint is in `scripts/check.sh`, and `grep -q 'declare -A' scripts/check.sh` succeeds |
| A2 config-keys | engine | S | A1 (test glob runs `tests/config-check-test.sh`) | every §11 key in `lib/config.sh` (`_DL_VARS`, default, export), `delivery-config.sh`, the `delivery-init.sh` scaffold, the README table and design spec §2.2; `delivery-config.sh --check`; `tests/config-check-test.sh` passes GC40, GC41, GC59 (`--check` part) |
| A3 shapes | policy | S | A1 (test glob) | `lib/node.jq`, `lib/pr.jq` (`validate_node`, `validate_pr`); `tests/shapes-test.sh` accepts the valid node and PR fixtures and rejects 5 malformed ones |
| A4 ready-transitions | policy | M | A3 (`validate_node`) | `lib/graph.jq` (§5 helpers, including `cycles`), `lib/ready.jq`, `lib/transitions.jq`; `tests/ready-test.sh` passes GC1, GC3, GC5, GC8, GC47 and the "not ready" assertions of GC2, GC4, GC6, GC7 |
| A5 reconcile | policy | M | A4 (`lib/graph.jq`, ready predicate) | `lib/reconcile.jq`; `tests/reconcile-test.sh` passes the reconcile assertions of GC2, GC4, GC6, GC7, GC24 (record), GC25 (record), GC42 (record), GC43, GC44, GC45 (record), GC65 |
| A6 tick-plan | policy | M | A4 (ready order), A3 (PR shape) | `lib/tick-plan.jq`, `tick-plan.sh`; `tests/tick-plan-test.sh` passes GC12–GC20, GC39 (plan assertion), GC62, GC59 (`tick-plan.sh` part) |
| D1 forge-github | forge | M | A3 (PR shape), A2 (`FORGE`, `LIST_LIMIT`) | `forge.sh` + `backends/forge-github.sh` (every §7.1 op); `tests/forge-github-test.sh` (gh shim) passes GC28 (github), GC29, GC30, GC32, GC33 (`task_id`), GC46, GC57, GC58, GC63, GC67 (github) |
| B1 graph-github-read | graph | M | A4 (`ready.jq`), A2 (`GRAPH_BACKEND`, `LIST_LIMIT`, `--check`) | `graph.sh` (ready/list/show/export, config check at start) + `backends/graph-github.sh list/show`; `tests/graph-github-read-test.sh` (gh shim) passes GC5 (github fixture), GC9, GC10, GC11, GC44 (`pinged_at` derivation), GC45 (checklist normalization), GC56, GC64, GC59 (`graph.sh` part) |
| B2 graph-github-write | graph | M | B1 (read path), A5 (`reconcile.jq`), D1 (`forge.sh pr-list` + linkage) | github create/update/link/flag/claim/release/comment, `graph.sh transition`/`claim`/`reconcile --fix`; `task-queue.sh` and `claim-task.sh` become wrappers; the existing claim tests pass unchanged; `tests/graph-github-write-test.sh` passes GC33 (reaper), GC42 (issue closed), GC61 |
| B3 graph-migrate | graph | S | B2 (`link`) | `graph.sh migrate`; `tests/graph-migrate-test.sh` passes GC48 |
| D2 forge-gitlab | forge | M | D1 (contract, `forge.sh`) | `backends/forge-gitlab.sh`; `tests/forge-gitlab-test.sh` passes GC28 (gitlab), GC29, GC30, GC31, GC32, GC67 (gitlab), GC59 (`forge.sh` part) |
| D3 forge-gitea | forge | M | D1 (contract, `forge.sh`) | `backends/forge-gitea.sh`; `tests/forge-gitea-test.sh` passes GC28 (gitea), GC29, GC30, GC32, GC67 (gitea) |
| C1 local-store | graph | M | B1 (`graph.sh` dispatch) | `backends/graph-local.sh`: store, lock, journal, list/show/create/update/link/flag; `tests/graph-local-test.sh` passes GC22, GC23, GC27, GC66, GC44 (`pinged_at` derivation) |
| C2 local-claim-reconcile | graph | M | C1 (store), A5 (`reconcile.jq`), A6 (`tick-plan.sh` for GC26), D1 (`forge.sh pr-list`) | local claim/release/comment/reconcile; `tests/graph-local-claim-test.sh` passes GC21, GC24 (event), GC25 (end to end); `tests/parity-test.sh` passes GC26 |
| E1 plan-lint-render | plan | M | A4 (`lib/graph.jq` `cycles`) | `plan.sh lint`/`render` + `lib/plan-lint.jq`; `tests/plan-test.sh` passes GC34, GC37, the lint assertions of GC6, GC7, and GC59 (`plan.sh` part) |
| E2 plan-apply | plan | M | E1 (lint), B2 (github create/link), C1 (local create/link) | `plan.sh apply`, including the promote node; `tests/plan-apply-test.sh` passes GC35, GC36, GC53, GC54 |
| E3 branch-targets | engine | S | B1 (`graph.sh show`), A2 (config) | `task-worktree.sh <id>` forks from `origin/<target_branch>`, with `task-<id>--<slug>` naming and legacy reuse; `tests/task-worktree-test.sh` passes GC38, GC55 |
| E4 promote | engine | M | E2 (promote nodes), D1 (`pr-create`), A6 (merge rule, promote action), E3 (worktrees) | `promote.sh`, `tick-merge.sh`; `tests/promote-test.sh` passes GC49, GC50, GC51, GC52, GC39 (`tick-merge` refusal), GC59 (`promote.sh` part) |
| I1 init-script | engine | S | A2 (keys), D1 (`forge.sh whoami`), D3 (gitea adapter used by GC60), C1 (`STATE_DIR` layout) | `delivery-init.sh` per §10 `init` row (no `--enable-merge-commit=false`; adds the `promote` label on github; checks git ≥ 2.31 and gh ≥ 2.94 where needed); `tests/init-test.sh` passes GC60 |
| F1 skill-tick | skills | M | A6 (`tick-plan.sh`), E4 (`promote.sh`, `tick-merge.sh`), B2 (`graph.sh reconcile`) | `delivery-tick/SKILL.md` per §10; `! grep -nE -e '\bgh pr ' -e '\bgh issue ' plugins/delivery-loop/skills/delivery-tick/SKILL.md`; `grep -q 'tick-plan.sh' plugins/delivery-loop/skills/delivery-tick/SKILL.md` |
| F2 skill-task-roles | skills | M | F1 (skills serialization), B2, D1, E3 (`task-worktree.sh <id>`) | next/review/patch/deliver-task per §10; `! grep -nE -e '\bgh pr ' -e '\bgh issue ' plugins/delivery-loop/skills/{next,review,patch,deliver}-task/SKILL.md`; `grep -q 'Delivery-Task:' plugins/delivery-loop/skills/next-task/SKILL.md`; `grep -q -- '--sha' plugins/delivery-loop/skills/review-task/SKILL.md` |
| F3 skill-plan-init-status | skills | M | F2 (skills serialization), E2 (`plan.sh`), C2 (local backend), I1 (init script) | decompose per §8.5, task-status `--graph`, init per §10, author-spec via the seams; `! grep -nE -e '\bgh pr ' -e '\bgh issue ' plugins/delivery-loop/skills/{decompose,task-status,author-spec}/SKILL.md`; `! grep -n 'enable-merge-commit=false' plugins/delivery-loop/skills/init/SKILL.md` |
| G1 docs | docs | M | F3 (final skill behavior), I1, B3, D2, D3 | every §16 item owned by G1; a loop over `seq 1 18` asserting each `^## <i>\. ` heading exists in `plugins/delivery-loop/docs/agentic_delivery_spec.md` (exit 1 on the first missing); every §11 key appears in `README.md`; `! grep -n 'enable-merge-commit=false' README.md plugins/delivery-loop/docs/delivery_runbook.md` |
| G3 release | infra | S | G1 (docs final) | both manifests `0.2.0`; `.claude/delivery.conf` has `BASE_BRANCH=main`; `grep -ri lineage plugins/` empty |

---
*Authored 2026-11-08; revised after docs-review round 1 the same day. Decomposition
follows this spec's merge to `release/0.2.0` and the H0 bootstrap (§14); execution
belongs to the delivery loop.*
