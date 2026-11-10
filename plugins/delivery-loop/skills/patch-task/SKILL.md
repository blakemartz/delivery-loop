---
name: patch-task
description: Respond to review findings or failing CI on an existing agent PR, e.g. "/patch-task 17" (PR number). Bounded to 3 iterations, then escalates to a human. The patcher role of the agentic delivery loop.
---

# patch-task — fix a PR that got changes-requested

You are the **patcher** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.5, §9). Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`. Take `GATE_CMD` and `NOTIFY_ESCALATE_CMD` from `bash "$S/delivery-config.sh"` (the resolved `KEY=value` lines: defaults, `.claude/delivery.conf`, then environment) — never by reading the conf file yourself.

Every graph read or write goes through `graph.sh`, every PR read or post through `forge.sh`. Never call the tracker's or forge's CLI or API directly. The script headers under `${CLAUDE_PLUGIN_ROOT}/scripts/` are the authoritative contract for every flag, output, and exit code below.

**You never write a free-text note on the node.** You are implementer-side: the reviewer reads every node comment that is not a script-written marker as contract (`review-task` step 2). Your reasoning goes on the PR (`forge.sh pr-comment`).

**Private scratch.** Before anything else, `export TMPDIR=$(mktemp -d)` and keep every scratch file (comment bodies, script stderr, gate log) under it. Never write to a shared fixed path: other agents run beside you.

## Protocol

1. **Read the PR and its node.** `bash "$S/forge.sh" pr-view <pr>` — `head`, `base`, `head_sha`, `checks`, `task_id`, `patch_iteration`, `agent`, `state`. Not `open`, `agent: false`, or `task_id: null` → report and stop. `bash "$S/graph.sh" show <task_id>` gives the node's `status` and `target_branch`.
2. **Check the iteration budget.** `patch_iteration` is the highest `Patch iteration: n/3` PR comment. If it is already 3, **escalate** and STOP — do not patch: write a summary of the impasse to `"$TMPDIR/impasse.md"` and post it with `bash "$S/forge.sh" pr-comment <pr> --body-file "$TMPDIR/impasse.md"`, then `bash "$S/graph.sh" flag <task_id> needs-human on`, and run `NOTIFY_ESCALATE_CMD` if it is set. The impasse lives on the PR, not in a node comment.
3. **Gather findings.** The review: `bash "$S/forge.sh" pr-reviews <pr>` (`[{author, verdict, body, at, commit}]`; the newest `request-changes` verdict's body carries the findings) and `bash "$S/forge.sh" pr-comments <pr>`. CI: when `checks` is `failure`, `bash "$S/forge.sh" ci-failures <pr>` for the failing-job log text; exit 4 = unsupported by this forge: reproduce the failure by running `GATE_CMD` locally.
4. **Re-enter the task worktree and bring it level with the PR's remote head.** Work only in the worktree.
   - `path=$(bash "$S/task-worktree.sh" <task_id>)` (stdout is only the path; exit 1 → report and stop). It reuses the node's worktree if one exists. Otherwise it rebuilds one on the surviving local branch: `task/<id>--<slug>`, or for a numeric id a legacy `task/<n>-<slug>`. If that branch is gone too — `task-worktree.sh --cleanup` deletes it — it forks a **fresh** `task/<id>--<slug>` from current `origin/<target_branch>`. A fresh fork holds none of the PR's commits.
   - So the local branch name may differ from the PR's `head`: a legacy-named head (`task/<n>-<slug>`) re-entered as `task/<n>--<slug>`, or a re-titled node. That is expected. Do not rename the branch; step 8 pushes to `<head>` explicitly. The remote head branch is the source of truth.
   - Fetch both branches into their remote-tracking refs: `git -C "$path" fetch origin "+refs/heads/<head>:refs/remotes/origin/<head>" "+refs/heads/<target_branch>:refs/remotes/origin/<target_branch>"`.
   - `git -C "$path" status --porcelain` must be empty. Uncommitted changes are an earlier run's unfinished work: report and stop.
   - Then take the first case that applies:
     - `git -C "$path" merge-base --is-ancestor HEAD origin/<head>` exits 0 (the branch is the PR's, or behind it): `git -C "$path" merge --ff-only origin/<head>`.
     - `git -C "$path" rev-list origin/<target_branch>..HEAD` prints nothing (the branch has no commits of its own: a fresh fork, even one taken after the target moved): `git -C "$path" reset --hard origin/<head>`. Nothing is lost, because every commit on it is already on the target branch.
     - Otherwise the branch has commits that are on neither the PR nor the target branch. Those are genuine local-only commits: list them (`git -C "$path" log --oneline origin/<head>..HEAD ^origin/<target_branch>`, which leaves out commits already on the target branch), report them, and stop.
   - `git -C "$path" rev-parse HEAD` must now equal `pr-view`'s `head_sha`. If not, the PR moved under you: re-read `pr-view` and repeat this step.
5. **Fix every finding.** Address each review point and each failing check — and fix it toward the best-practice, idiomatic solution (spec §2.1), not just enough to silence the finding. If you disagree with a finding, don't silently ignore it — reply on the PR (`forge.sh pr-comment <pr> --body-file F`) with your reasoning and make the call visible.
6. **Catch up with the target branch by merging, never rebasing.** If `origin/<target_branch>` moved: `git -C "$path" fetch origin <target_branch> && git -C "$path" merge origin/<target_branch>`, resolving conflicts in the worktree. Never rebase a pushed branch and **never force-push** — review history stays intact.
7. **Re-verify.** Every acceptance criterion (`bash "$S/graph.sh" show <task_id> --format md`) + `GATE_CMD`, from `$path`, with the gate's output sent to a log unique to this run (e.g. `"$TMPDIR/gate-pr<pr>-$(date +%s).log"`). Hooks fire on commit/push; never bypass the gate (`--no-verify`). If you start a background process, capture its PID (`$!`) and kill only that PID; never kill by pattern (`pkill -f`, `killall`).
8. **Push** with a plain `git -C "$path" push origin HEAD:<head>`. Then post `Patch iteration: <n+1>/3` (n = step 1's `patch_iteration`) as the first line of a comment, followed by a short change summary: `bash "$S/forge.sh" pr-comment <pr> --body-file "$TMPDIR/iteration.md"`. Flip the node back for re-review **only if it is `changes-requested`**: `bash "$S/graph.sh" transition <task_id> in-review` (exit 2 = illegal from its current status: report it).
9. Report what changed and that the PR awaits re-review.

**Encode the lesson:** if the finding traces back to a harness gap (a criterion the gate should have caught, an ambiguous template), file a `module:infra` task (`graph.sh create`).

## Rebase-only mode (approved-but-conflicting PRs)

The orchestrator (`delivery-tick`, spec §8.2) dispatches this skill as a "rebase" on an **already-approved** PR that conflicts with (or is red against) its target branch after a sibling merged ahead of it. Same protocol, with three differences:

- **No review findings to fix** — steps 3/5 have nothing to address; the work *is* step 6: merge `origin/<target_branch>` into the branch, resolve conflicts in the worktree, re-verify with `GATE_CMD` (step 7), and push plainly (step 8). Still never rebase and never force-push.
- **Preserve the approval.** Do NOT transition the node: it stays `approved` — never send it back to `in-review`. Comment `Patch iteration: <n+1>/3 (rebase)` so repeated re-conflicts stay bounded.
- **Same iteration budget** (step 2): at `3/3`, or if the node is already `needs_human`, escalate and STOP instead of updating again — no rebase loop.

## Exit condition

Push + iteration comment + node back `in-review` (or, in rebase-only mode, approval preserved), or a `needs-human` escalation with summary.
