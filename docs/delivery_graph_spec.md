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
- the three engine defects found in review (GC9, GC10, GC33);
- docs and the version bump.

**Not in v0.2 (do not decompose).** Everything in §15: cross-machine sync for the local
backend, write-scope checks, gate-tamper guard, risk lanes, structured verdicts,
re-plan edge, lessons ledger, metrics, stacked PRs, multi-hop promotion, a "no-forge"
local mode, and new node kinds beyond `task | epic | promote`.

**Behavior parity is a hard requirement.** With default config (`GRAPH_BACKEND=github`,
`FORGE=github`, no plan target), the ready set, its ordering, claim semantics, the
tick's choice of action, staleness windows (4h agent / 72h human) and the patch
budget (3) are unchanged from v0.1.4. The only exceptions are the defect fixes, which
are pinned by GC9, GC10 and GC33.

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
| `epic` | string \| null | parent epic id. github: native `parent.number`, else legacy `Part of epic #E` / `[Ee]pic #E`. |
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
| `reviewed_at_head` | bool | a verdict review or verdict comment exists for `head_sha`. |
| `author` | string | |

### 4.3 PR ↔ task linkage

- Agent PR bodies carry a trailer line `Delivery-Task: <node id>`, on every backend.
  On the github backend they also keep `Closes #N`.
- Adapters fill `task_id` from:
  1. the `Delivery-Task:` trailer;
  2. if absent and `GRAPH_BACKEND=github`, the first `Closes|Fixes|Resolves #N`;
  3. failing those, a `task/<id>--…` head branch, or the legacy `task/<n>-…`.
- The trailer replaces v0.1.4's `#N\b` body/title regex, which falsely matched any PR
  that merely mentioned the issue (GC33).

## 5. Policy core (`scripts/lib/`)

All of it is pure `jq`. Wall-clock time arrives as an argument (`--argjson now`), so
fixtures are deterministic.

**`ready.jq`.** Input: all nodes. Output: the ready set, best first, as JSON lines of
`{id, number?, title, unblocks, size, started, epic, module, target_branch}`.
`number` is present only when `id` is numeric, which preserves the v0.1.4 output
consumed by the `task-queue.sh` wrapper.

- *Ready iff:*
  - `kind=="task"`;
  - not `done`/`cancelled`;
  - every dep exists and has status `done`;
  - `claim==null` and no human assignee;
  - `size != "L"`;
  - `needs_human` false.
- A dep that is `cancelled` or **unknown** never satisfies readiness. Reconcile
  reports it (GC2, GC7). This is a behavior change: v0.1.4 treated any CLOSED dep as
  satisfied, including won't-do.
- *Ordering (unchanged from v0.1.4):*
  1. started-epic first (the epic has ≥ 1 `done` child);
  2. then `unblocks` descending (count of open nodes that list this id in `deps`);
  3. then `S` before `M`;
  4. then `created_at` ascending (GC5).

**`transitions.jq`.**
- The legal-transition table from design spec §5, plus `* → cancelled` (human only)
  and promote-node transitions (§9).
- `graph.sh transition <id> <to>` validates `(from, to, actor_kind)` against it and
  exits 2 on an illegal transition, without writing (GC8).

**`reconcile.jq`.** Input: `{nodes, prs, now}`. Output: a list of fix records
`{op, id, from, to, reason}`. The backend applies them; `--fix` prints them as
`fix: …` lines. Rules (parity with `task-queue.sh --fix`, extended):

1. `blocked → ready` when every dep is `done`, and never while `needs_human`.
2. `ready → blocked` when deps are unmet.
3. **Ground-truth status from PRs.**
   - A merged PR with `task_id` X sets X to `done`. This matters on the local
     backend; on github, `Closes #N` already closes the issue.
   - An open PR with `task_id` X while X is `claimed` sets X to `in-review`.
4. **Stale agent claims** (`by=="agent"`, no open PR for the node, `now - updated_at
   > 4h`, not `needs_human`) are released to `ready` with reason `RECLAIMED`.
5. **Stale human claims** older than 72h get one ping record. They are never released.
6. **Epics** become `done` when they have ≥ 1 child and every child is `done` or
   `cancelled`, with at least one `done`. (v0.1.4 closed an epic when every child was
   CLOSED.)
7. **Warnings, never mutations:**
   - `blocked on cancelled dep <id>`
   - `unknown dep <id>`
   - `cycle: <id> → … → <id>`

   These print on stderr.

**`tick-plan.jq`.** Input: `{nodes, prs, flags: {parallel, auto_merge}, now}`.
Output: `{mode, actions: [{action, pr?, id?, branch?, reason}], board: {<status>:
count}, waiting: [string]}`. Actions are `merge` | `patch` | `rebase` | `review` |
`promote` | `start`. It encodes today's `delivery-tick` rules verbatim (GC12–GC20):

- **Priority:** merge (only if `auto_merge`) > patch > rebase > review > promote >
  start.
- **merge** requires:
  - the PR is `open`, with `mergeable=="clean"` and `checks=="success"`;
  - its node is a `task` with status `approved`;
  - no `needs-human` label and no `needs_human` flag.

  Merge actions don't count against N. **Promote PRs are never merge actions**
  (GC39).
- **rebase:** the node is `approved` and the PR `conflicting`, skipped when
  `patch_iteration >= 3` or `needs_human`.
- **review:** the node is `in-review` and `reviewed_at_head` is false.
- **Batch independence:**
  - at most one action per PR;
  - in-flight = open agent PRs (including approved-but-unmerged) + `claimed` nodes;
  - starts fill `cap - in-flight`;
  - each start's `(target_branch, module)` must be distinct from every in-flight
    task's and every other start's. The module lock is **per target branch** (GC18).
  - nodes with no module are exempt from the module filter.
- **Modes:**
  - serial: the first action only, start cap 2.
  - `parallel` parsing is done by `tick-plan.sh`: bare → 3; non-integer → 3; > 16 →
    16; ≤ 1 → serial (GC17).

## 6. Graph backends

### 6.1 Backend contract

`backends/graph-<name>.sh <primitive> [args]`, sourced config, exit 0 on success:

| Primitive | Contract |
|---|---|
| `list` | All nodes as a JSON array of §4.1 nodes: open nodes plus every node any open node references, so deps resolve. |
| `show <id>` | One node. `--format md` renders title + body for agent prompts. |
| `create <node-json>` | Creates a node, returns its `id`. |
| `update <id> <patch-json>` | Merges the patch fields (status, claim, needs_human, …). Used by `transition`/`reconcile`. |
| `claim <id> <actor> <run>` | **Atomic** test-and-set: succeeds only if the node is still `ready` with no claim. Exit 0 = owned, 1 = lost or not claimable. |
| `release <id> <reason>` | Clears the claim and returns the node to `ready` (or leaves `needs_human` set). |
| `comment <id> <text>` | Durable note on the node (github: issue comment; local: journal event). |
| `link <id> <dep-id> [via]` | Adds a blocking edge. |

`graph.sh` adds:
- `ready`;
- `reconcile [--fix]`;
- `transition <id> <to>`;
- `migrate`, github only (§6.2);
- `export`, which dumps nodes as JSON for backup and debugging.

### 6.2 `github` backend

- **Reads** one paginated `gh issue list --state all --json
  number,title,state,stateReason,labels,assignees,body,createdAt,updatedAt,blockedBy,parent,comments`
  with `--limit "$LIST_LIMIT"`. If the result count equals `LIST_LIMIT`, it exits 3
  naming the key (GC10). v0.1.4 silently truncated at 500/1000 and read out-of-window
  deps as OPEN. `gh pr list` is never called without an explicit `--limit`; v0.1.4
  used the default 30, which blinded the stale-claim reaper (GC33).
- **Native relations.** `blockedBy.nodes[].number` and `parent.number` (shape
  verified 2026-11-08: `{"blockedBy":{"nodes":[{"number":7,"state":"OPEN",…}],"totalCount":3},"parent":{"number":1,…}}`).
  Requires gh ≥ 2.94.0. On older gh the backend falls back to text edges only and
  warns once.
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
  `Part of epic #E`. Text lines are left in place. It refuses to exceed the 50
  blockers per issue cap: it prints the offender and exits 1.
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
- The epic node itself is in its file's `epic` field.
- `schema` mismatch → refuse with the expected vs found version. No implicit
  migrations.

**Lock.**
- Every mutating primitive runs inside `with_lock`, which:
  1. calls `mkdir "$STATE_DIR/lock"` (atomic on POSIX; no `flock`, which macOS lacks);
  2. on failure retries with backoff for up to 30s, then exits 75 (EX_TEMPFAIL);
  3. writes `lock/owner`;
  4. runs the critical section;
  5. calls `rm -rf "$STATE_DIR/lock"` in a trap.
- A lock is **stale** and may be broken when `owner`'s host equals this host, its pid
  is not alive (`kill -0` fails), and it is older than `LOCK_STALE_SECONDS`
  (default 120). Breaking a lock appends a `lock-broken` event (GC22).
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
- `reconcile` calls `forge.sh pr-list` (open PRs) and `forge.sh pr-view` for nodes
  that are `in-review`/`approved` and have no open PR. This is how a merge on the
  forge becomes `done` locally (GC25).
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
| `pr-list [--state open]` | All matching PRs, **fully paginated** (GC32). |
| `pr-find --head H` | The open PR for a head branch, or empty. |
| `pr-review <n> approve\|request-changes\|comment --body-file F` | Posts a verdict and returns `{posted, form: "formal"\|"comment", url}`. If the forge rejects a self-review, it falls back to a comment-form review with the same body (GC29). |
| `pr-reviews <n>` | `[{author, verdict, body, at, commit}]`, used to verify a verdict landed. |
| `pr-comment <n> --body-file F` / `pr-comments <n>` | Post / list plain comments. |
| `pr-merge <n> --method squash\|merge --sha S` | Merges only if the head is still S (GC30). The source branch is deleted on squash. |
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
| `mergeable` | `mergeStateStatus` CLEAN→clean, DIRTY→conflicting, BLOCKED/UNSTABLE/BEHIND→blocked, else unknown | `detailed_merge_status`: `mergeable`→clean; `conflict`/`need_rebase`→conflicting; `unchecked`/`checking`/`preparing`/`approvals_syncing`/`ci_still_running`→unknown (re-poll); everything else→blocked | `mergeable==true`→clean, `false`→conflicting (computed async: a 405 "try again later" → unknown) |
| `checks` | `statusCheckRollup` (all SUCCESS→success, any FAILURE/ERROR/CANCELLED→failure, else pending; empty→none) | `head_pipeline.status`: `success`→success; `failed`/`canceled`/`canceling`→failure; null→none; else pending | `GET /commits/{sha}/status`: `total_count==0`→none; `success`→success; `error`/`failure`→failure; `pending`→pending; `warning`/`skipped`→success (one statement in the adapter header; Gitea Actions posts one status per job (src)) |
| `pr-create` | `gh pr create` | `POST /merge_requests` `source_branch,target_branch,title,description` → `iid,web_url` | `POST /pulls` `head,base,title,body` → `number,html_url` |
| `pr-list` / `pr-find` | `gh pr list --limit $LIST_LIMIT` / `--head` | `GET /merge_requests?state=opened&per_page=100`, following `x-next-page` until empty (`x-total` is omitted above 10k) / `&source_branch=` | `GET /pulls?state=open&limit=<max_response_items>&page=n`, following `Link rel=next` / `GET /pulls/{base}/{head}` (Forgejo also has a `head` filter) |
| `pr-review` approve | `gh pr review --approve` | `POST /merge_requests/:iid/approve` with `sha` (409 if not head) | `POST /pulls/{n}/reviews` `event=APPROVED, commit_id` |
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
  report `unknown`.
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

Exits 1, listing every error (GC34), when:
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
  **reported, not overwritten**.
- **Order:**
  1. epics;
  2. tasks, in topological order so dep ids resolve;
  3. then one **promote node** per plan, if `promote_to` is set (§9);
  4. then `graph.sh reconcile --fix`.
- On github, tasks are sub-issues of their epic issue and carry native blocked-by
  links (GC36).
- **Missing target branch.** If `target_branch` doesn't exist on the remote, apply
  creates it from `origin/<promote_to or BASE_BRANCH>` and pushes it, printing the
  exact `git push` first. This is the only branch-creating step.

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
    GitHub's 50-blocker cap. Epics become `done` through reconcile rule 6.
  - It carries `target_branch` (T) and `promote_to` (P).
  - `next-task` never claims it: `ready.jq` admits only `kind=="task"`.
- **Promote action.** When a promote node's deps are all `done`, `tick-plan`
  emits `promote` for it (GC19). The tick runs `promote.sh <id>`, a deterministic
  script that takes no model judgment:
  1. Claim the node (actor `promote`).
  2. If `git diff --quiet origin/P origin/T` (identical trees), mark the node `done`
     with the note `nothing to promote`.
  3. Otherwise create a fresh worktree of `origin/T` and run `PROMOTE_GATE_CMD`
     (default `GATE_CMD`).
  4. If it is red: set `needs_human`, comment with the failing output, run
     `NOTIFY_ESCALATE_CMD`, and exit 1.
  5. If it is green:
     - open a PR with head T, base P, the title `Promote T → P`, a body listing the
       plan's done tasks, and `Delivery-Task: <promote id>`;
     - set the node to `in-review`.
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
| `delivery-tick` | Reconcile (`graph.sh reconcile --fix`) → `tick-plan.sh [--parallel N] [--auto-merge]`. Merge actions run via `tick-merge.sh <pr> <sha>`, which re-checks eligibility, merges via `forge.sh pr-merge`, then reconciles. Promote actions run via `promote.sh`. Agents are dispatched only for `patch`/`rebase`/`review`/`start`. The prose priority rules are deleted and replaced by "execute the plan's actions in order". |
| `next-task` | `graph.sh ready`/`claim`/`show --format md`/`transition`. The PR goes through `forge.sh pr-create --base <target_branch>`, with a body carrying `Delivery-Task:` and, on the local backend, the full task contract. |
| `review-task` | Reads the contract via `graph.sh show`, PR state via `forge.sh pr-view`/`pr-diff`. Posts via `forge.sh pr-review` and verifies via `pr-reviews`. Verdict of record: `graph.sh transition`. |
| `patch-task` | `forge.sh pr-view`/`pr-comments`/`ci-failures`. Rebases onto `target_branch`. Iteration counter unchanged (a PR comment). |
| `deliver-task` | Passes node ids, not issue numbers. Otherwise unchanged. |
| `decompose` | §8.5. |
| `task-status` | `graph.sh list` + `forge.sh pr-list` → board. `--graph` prints Mermaid. `--reclaim` → `graph.sh reconcile --fix`. |
| `init` | Asks for or detects `GRAPH_BACKEND` and `FORGE`. The local backend skips labels and creates `STATE_DIR`. Checks forge auth via `forge.sh whoami`. gh is required only when either seam is github. |
| `author-spec` | Board reads via `graph.sh`. Docs-review verdict via `forge.sh pr-review --comment`. |
| `author-styleguides` | No change. |

## 11. Configuration

New keys. Each follows the four-place rule (`lib/config.sh`, the `delivery-init.sh`
scaffold, the README table, and the design spec §2.2). **All of them land in one
task (A2)**, because `config.sh`, `delivery-init.sh` and the README are hub files.

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

Tokens: `GITLAB_TOKEN`, `GITEA_TOKEN`, from the environment only.

**`delivery-config.sh --check`** validates the combination and exits 1 with a
message:
- `GRAPH_BACKEND=github` requires `FORGE=github` (GC40);
- unknown backend or forge values are rejected, listing the valid ones (GC41);
- a gitlab/gitea forge with an unset token is rejected.

Every engine entry point runs the check once.

## 12. Golden cases

Fixtures live in `plugins/delivery-loop/scripts/tests/fixtures/`. Each case is
asserted by a `*-test.sh` named in the cutline.

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

**Tick plan:**

| # | Given | Expect |
|---|---|---|
| GC12 | serial; one changes-requested PR, one review-pending PR, one ready task | `[patch]` |
| GC13 | `--parallel 3`; one PR matching both patch and review; ready tasks in modules a, a, b | patch on that PR + starts for a and b (not the second a) |
| GC14 | cap reached, counting an approved-unmerged PR | no `start` |
| GC15 | `--auto-merge`; PR A approved+clean+success; PR B approved+conflicting | `merge A`, `rebase B` |
| GC16 | approved+conflicting PR with `patch_iteration` 3 | no rebase; listed in `waiting` |
| GC17 | `--parallel` / `--parallel x` / `--parallel 20` / `--parallel 1` | mode parallel N=3 / 3 / 16 / serial |
| GC18 | two ready tasks, same module, different `target_branch` | both started (parallel 2) |
| GC19 | promote node whose epics are all done, no open promotion PR | `[promote <id>]` |
| GC20 | nothing actionable | `actions: []`, `waiting` names the reason |

**Local backend:**

| # | Given | Expect |
|---|---|---|
| GC21 | 8 concurrent `graph.sh claim X` | exactly one exit 0, seven exit 1; one `claim` event |
| GC22 | lock dir with a dead pid on this host, older than `LOCK_STALE_SECONDS` | broken, op proceeds, `lock-broken` event; a live lock → waits, then exit 75 |
| GC23 | a write completes | no `*.tmp.*` files remain; every epic file parses |
| GC24 | agent claim older than 4h, no PR | reconcile → `ready`, `reclaim` event |
| GC25 | forge fixture: PR merged with `Delivery-Task: x` | x `done`; dependent → `ready` |
| GC26 | board F in github fixture shape and local store shape | byte-identical `graph.sh ready` and `tick-plan.sh` output |
| GC27 | claim from worktree A | visible from worktree B (same `STATE_DIR`) |

**Forge:**

| # | Given | Expect |
|---|---|---|
| GC28 | captured API responses per adapter (open/merged/closed; conflict; checks pass/pending/fail/none) | normalized §4.2 PRs equal the expected fixtures |
| GC29 | fixture: formal review rejected as self-review | comment-form fallback, `{posted:true, form:"comment"}` |
| GC30 | `pr-merge --sha` with a stale sha | exit nonzero, no merge request sent (dry-run log) |
| GC31 | `FORGE_DRY_RUN=1 FORGE=gitlab forge.sh pr-create …` | prints `POST /api/v4/projects/<enc>/merge_requests` + body with source/target/title |
| GC32 | two-page list fixture | all PRs from both pages |
| GC33 | PR whose body only *mentions* `#12`; PR with `Delivery-Task: 12` | `task_id` null / `"12"`; reaper sees the second as #12's open PR |

**Plans and branches:**

| # | Given | Expect |
|---|---|---|
| GC34 | valid plan / missing `via` / module ∉ MODULES / two plans with the same target but different `promote_to` | pass / error / error / error |
| GC35 | `apply` twice (local) | second run creates 0 nodes |
| GC36 | `apply` (github, `FORGE_DRY_RUN`-style gh shim) | epic issue, tasks created with `--parent` and `--blocked-by` |
| GC37 | `render` on the GC34 valid plan | Mermaid with one labeled edge per dep |
| GC38 | `task-worktree.sh` on a node whose target branch is missing | exit 1, message names `plan.sh apply` |
| GC39 | `--auto-merge`; open promotion PR clean+success | no `merge` action for it |
| GC40 | `GRAPH_BACKEND=github FORGE=gitlab` | `--check` exit 1 |
| GC41 | `GRAPH_BACKEND=sqlite` | `--check` exit 1, lists `github local` |

## 13. Testing and the gate

- **Discovery.** `scripts/check.sh` discovers `plugins/delivery-loop/scripts/tests/*-test.sh`
  by glob instead of naming files (task A1), so later tasks never edit the gate to
  register a test.
- **The gate stays offline.** github and forge tests use captured JSON fixtures and
  a `gh` shim placed on `PATH`. curl adapters are tested via `FORGE_DRY_RUN`.
  Live-forge smoke tests are runbook steps, not gate steps.
- **Local-backend tests** run in a throwaway repo under `${TMPDIR:-/tmp}` created by
  the test itself.
- **bash 3.2.** No associative arrays, no `mapfile`, no `${x,,}`. Empty arrays are
  guarded under `set -u`. `bash -n` already covers every script, and the gate adds a
  `grep` lint for those three constructs.

## 14. Rollout (informative)

1. **Release branch.** `release/0.2.0` is cut from `main`. Every task's
   `target_branch` is `release/0.2.0`.
   - The installed v0.1.4 loop only knows `BASE_BRANCH`, so the release branch's own
     `.claude/delivery.conf` sets `BASE_BRANCH=release/0.2.0` and
     `MODULES="policy graph forge plan engine skills"`.
   - The orchestrator runs from a checkout of `release/0.2.0`.
   - Finer modules restore parallelism that a single `engine` module would
     serialize:
     - `policy` = `scripts/lib/*.jq`
     - `graph` = `scripts/graph.sh` + `backends/graph-*`
     - `forge` = `scripts/forge.sh` + `backends/forge-*`
     - `plan` = `scripts/plan.sh` + `lib/plan-*.jq`
     - `engine` = other scripts
2. **Test against the release branch.** From a `release/0.2.0` checkout, run
   `CLAUDE_CONFIG_DIR=$(mktemp -d) claude plugin marketplace add ./ && … install …`.
   Then pilot the local backend on a scratch repo against each forge available to the
   operator.
3. **Promotion.** The last task (G3) bumps both manifests to `0.2.0` and restores
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

- **Design spec** (`agentic_delivery_spec.md`):
  - keep §1–§14 numbering;
  - add §15 Graph backends, §16 Forges, §17 Branch flow & promotion, §18 Plan files;
  - amend §5.1 (precedence includes forge PR state), §6 (tick = `tick-plan.sh`),
    §7.1 (ready semantics: cancelled deps), §2.2 (config table).
- **Runbook:** local-backend operation, `STATE_DIR` backup (`graph.sh export`),
  forge tokens, release-branch workflow, and the promotion step.
- **README:** "How it works" idea 1 generalized beyond GitHub, config table, Install
  prerequisites per seam, and a new "Branch flow" section.
- **Plugin `docs/README.md`:** links to §15–§18.
- **`CLAUDE.md`:** the config key list, and the module list for this repo.
- **Registration:** this file is `docs/delivery_graph_spec.md`, matched by
  `SPEC_SOURCES="docs/*_spec.md"`.

## 17. Decompose-ready cutline

Target `release/0.2.0` → promote to `main`. Every task's criteria implicitly include
"`bash scripts/check.sh` passes". IDs are plan ids.

| ID | Module | Size | Depends on (via) | Acceptance criteria (beyond the gate) |
|---|---|---|---|---|
| A1 test-discovery | infra | S | — | `scripts/check.sh` runs every `plugins/delivery-loop/scripts/tests/*-test.sh` by glob; a new dummy `*-test.sh` exiting 1 makes the gate fail (shown in PR evidence, not committed); bash-3.2 lint added |
| A2 config-keys | engine | S | — | all §11 keys in `_DL_VARS`/defaults/export; scaffolded by `delivery-init.sh`; README + design spec §2.2 tables; `delivery-config.sh --check` passes GC40–GC41 (`tests/config-check-test.sh`) |
| A3 shapes | policy | S | A1 (test glob) | `lib/node.jq`, `lib/pr.jq` with `validate_node`/`validate_pr`; `tests/shapes-test.sh` accepts valid fixtures and rejects 5 malformed ones |
| A4 ready-transitions | policy | M | A3 (validate_node) | `lib/ready.jq`, `lib/transitions.jq`; `tests/ready-test.sh` passes GC1–GC8 |
| A5 reconcile | policy | M | A4 (ready predicate) | `lib/reconcile.jq`; `tests/reconcile-test.sh` passes GC2, GC4, GC6, GC7, GC24, GC25 and the epic rule 6 |
| A6 tick-plan | policy | M | A4 (ready order), A3 (pr shape) | `lib/tick-plan.jq` + `scripts/tick-plan.sh`; `tests/tick-plan-test.sh` passes GC12–GC20, GC39 |
| B1 graph-dispatch-github-read | graph | M | A4 (ready.jq), A2 (`LIST_LIMIT`, `GRAPH_BACKEND`) | `scripts/graph.sh` (ready/list/show/export) + `backends/graph-github.sh list/show` via gh shim; `tests/graph-github-test.sh` passes GC9–GC11 and GC5 parity on the v0.1.4 fixture |
| B2 graph-github-write | graph | M | B1 (contract), A5 (reconcile.jq) | claim (reuses claim-winner/orphan-claims), release, update, transition, comment, `reconcile --fix`; `task-queue.sh`/`claim-task.sh` become wrappers; existing claim tests + new GC33 reaper case pass |
| B3 graph-migrate | graph | S | B2 (write path) | `graph.sh migrate` idempotent under gh shim (second run issues 0 edits); refuses > 50 blockers |
| D1 forge-github | forge | M | A3 (pr shape), A2 (`FORGE`) | `scripts/forge.sh` + `backends/forge-github.sh` (all §7.1 ops); `tests/forge-github-test.sh` passes GC28 (github), GC29, GC30, GC32, GC33 |
| D2 forge-gitlab | forge | M | D1 (contract) | `backends/forge-gitlab.sh`; `tests/forge-gitlab-test.sh` passes GC28 (gitlab), GC29–GC32 via fixtures + `FORGE_DRY_RUN` |
| D3 forge-gitea | forge | M | D1 (contract) | `backends/forge-gitea.sh`; `tests/forge-gitea-test.sh` passes GC28 (gitea), GC29–GC32 |
| C1 local-store | graph | M | B1 (dispatcher contract) | `backends/graph-local.sh` store/lock/journal + list/show/create/update/link; `tests/graph-local-test.sh` passes GC22, GC23, GC27 |
| C2 local-claim-reconcile | graph | M | C1 (store), A5 (reconcile.jq), D1 (`forge.sh pr-list`) | claim/release/comment/reconcile; passes GC21, GC24, GC25; `tests/parity-test.sh` passes GC26 |
| E1 plan-lint-render | plan | M | A4 (cycle/ready helpers) | `scripts/plan.sh lint/render` + `lib/plan-lint.jq`; `tests/plan-test.sh` passes GC6, GC7, GC34, GC37 |
| E2 plan-apply | plan | M | E1 (lint), B2 (github create), C1 (local create) | `plan.sh apply`; passes GC35, GC36; promote node emitted when `promote_to` set |
| E3 branch-targets | engine | S | B1 (`graph.sh show`), A2 | `task-worktree.sh` takes a node id, forks from `origin/<target_branch>`, `task-<id>--<slug>` naming with legacy `task-<n>-*` reuse; passes GC38 |
| E4 promote | engine | M | E2 (promote nodes), D1 (pr-create), A6 (promote action) | `scripts/promote.sh` + `scripts/tick-merge.sh`; tests cover identical-tree → done, red gate → needs_human, green → PR body with `Delivery-Task:` (gh shim) |
| F1 skill-tick | skills | M | A6, E4, B2 | `delivery-tick/SKILL.md` drives `tick-plan.sh`/`tick-merge.sh`/`promote.sh`; `grep -c 'gh pr\|gh issue' skills/delivery-tick/SKILL.md` = 0 |
| F2 skill-task-roles | skills | M | F1 (module serialization), B2, D1, E3 | next/review/patch/deliver-task use `graph.sh`/`forge.sh` only (`grep` = 0 outside fenced diagnostics); PR template carries `Delivery-Task:` |
| F3 skill-plan-init-status | skills | M | F2, E2, C2 | decompose per §8.5; task-status `--graph`; init backend/forge selection; author-spec via seams; `grep` check as in F2 |
| I1 init-script | engine | S | A2, D1, C1 | `delivery-init.sh`: local backend skips labels + creates `STATE_DIR`; gh required only for github seams; adds `promote` label; `bash -n` + a dry-run test in a temp repo |
| G1 docs | docs | M | F3 (final behavior) | design spec §15–§18 added with §1–§14 numbers intact (`grep -c '^## 1[0-4]\.'` unchanged); runbook + README + plugin docs/README + CLAUDE.md per §16 |
| G3 release | infra | S | G1, I1, B3, D2, D3 | both manifests `0.2.0` (gate checks agreement); `.claude/delivery.conf` restores `BASE_BRANCH=main`; `grep -ri lineage plugins/` empty |

---
*Authored 2026-11-08. Decomposition follows this spec's merge to `release/0.2.0`;
execution belongs to the delivery loop.*
