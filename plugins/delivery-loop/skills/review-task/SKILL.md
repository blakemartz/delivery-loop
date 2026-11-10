---
name: review-task
description: Adversarially review a PR against its linked task's acceptance criteria and the styleguides, e.g. "/review-task 17" (PR number). Executes every criterion on a clean checkout of the head and on the merged result. The independent reviewer role of the agentic delivery loop.
---

# review-task — independent adversarial review

You are the **reviewer** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.4, §11). Below, `S=${CLAUDE_PLUGIN_ROOT}/scripts`. Take `GATE_CMD`, `STYLEGUIDES_DIR`, `WORKTREE_SETUP_CMD`, and `NOTIFY_APPROVE_CMD` from `bash "$S/delivery-config.sh"` (the resolved `KEY=value` lines: defaults, `.claude/delivery.conf`, then environment) — never by reading the conf file yourself.

Every graph read or write goes through `graph.sh`, every PR read or post through `forge.sh`. Never call the tracker's or forge's CLI or API directly. The script headers under `${CLAUDE_PLUGIN_ROOT}/scripts/` are the authoritative contract for every flag, output, and exit code below.

**Private scratch.** Before anything else, `export TMPDIR=$(mktemp -d)` and keep every scratch file (verdict body, script stderr, gate logs) under it. Never write to a shared fixed path: other agents run beside you.

## Independence rules (these are the point)

- You must NOT read any implementer transcript, notes, or reasoning. If you were spawned with implementer context in your prompt, say so and refuse the review.
- Your only inputs: the linked node's contract (step 2), the PR (`forge.sh pr-view` / `pr-diff`), the conventions in `STYLEGUIDES_DIR`, and clean checkouts you build yourself.
- **Execute, don't trust.** Everything in the PR body — checked boxes, evidence, the implementer's findings — is a claim, never evidence. You run every criterion yourself.

## Protocol

1. **Read the PR.** `bash "$S/forge.sh" pr-view <pr>` — a JSON PR with `head`, `base`, `head_sha`, `state`, `mergeable`, `checks`, `task_id`, `agent`. Record `head_sha` now: it is the head you review and the one your verdict pins. Not `open`, or `agent: false` → report and stop. `task_id: null` (no `Delivery-Task:` trailer or other linkage) → request changes (protocol violation) via steps 7–8, skip step 9 (there is no node to record on), then step 10.
2. **Read the contract.** It is the node body plus the notes the orchestrator or a human attached to the node — nothing the implementer wrote.
   - **Body:** `bash "$S/graph.sh" show <task_id>` (JSON: `status`, `target_branch`) and `bash "$S/graph.sh" show <task_id> --format md` — extract the acceptance criteria.
   - **Notes:** `bash "$S/graph.sh" show <task_id> --events` — the node's JSON line, then its events, oldest first, one JSON object per line (`{ts, actor, run, op, id, from, to, body}`). This is the only way you read a node's notes. What it returns depends on the backend:
     - **github:** the issue's whole comment thread, as `comment` events.
     - **local:** the node's **last 10 journal events of any op** (claims, transitions and links count toward the 10), so an early orchestrator or human note can fall outside the window. The seam offers no longer window: if 10 events came back, say in the verdict that notes older than the window were not visible.
     - Exit 1 = the read failed; exit 3 = the comment thread reached `LIST_LIMIT` (stderr `… >= LIST_LIMIT (<n>); refusing to truncate`). Either way nothing was printed: retry an exit 1 once, then review against the body alone and say so in the verdict, naming the exit (for 3, that raising `LIST_LIMIT` would let the notes be read).
   - **Which events are contract:** only `comment` events (the journal's `op: "comment"`), and of those, none whose body starts with a marker the scripts write: `CLAIM `, `CLAIM-WITHDRAWN `, `RELEASED:`, `RECLAIMED`, `STALE-CLAIM-PING`, `AUTO-CLOSE:`, `TRANSITIONED:`, `MERGE-NEEDS-HUMAN:` (`tick-merge.sh`), `PROMOTE-GATE-RED:` and `nothing to promote:` (`promote.sh`). Every other event (`claim`, `release`, `transition`, `create`, `link`, `reclaim`, …) is bookkeeping. This split is exact because the implementer-side roles (`next-task`, `patch-task`) never write a free-text node comment: their claims, releases and blocker reasons reach the node only as those script-written events and markers, and their findings go in the PR body. So every remaining comment is the orchestrator's or a human's.
   - The PR's `base` must equal the node's `target_branch`; otherwise request changes ("PR targets `<base>`, node targets `<target_branch>`") via steps 7–9, then step 10, without building checkouts.
3. **CI must be green or pending-then-green.** `checks: "failure"` → the PR is unreviewable: request changes citing the failing check (`bash "$S/forge.sh" ci-failures <pr>` for the log text; exit 4 = unsupported by this forge) via steps 7–9, then step 10. `pending` → carry on; step 7 re-reads it before posting.
4. **Build two clean checkouts** from the repo root, both detached, both yours (never reuse another agent's worktree):
   - `git fetch origin <base> <head>`
   - **head:** `git worktree add --detach .worktrees/review-pr-<pr>-head <head_sha>`
   - **merged result (base + head):** `git worktree add --detach .worktrees/review-pr-<pr>-merge origin/<base>`, then `git -C .worktrees/review-pr-<pr>-merge -c user.name=reviewer -c user.email=reviewer@localhost -c commit.gpgsign=false merge --no-ff --no-edit <head_sha>` (a throwaway commit, never pushed). A conflict = request changes ("conflicts with `<base>`").
   Run `WORKTREE_SETUP_CMD` in each if it is set.
5. **Execute every acceptance criterion** in the head checkout, plus `GATE_CMD` in **both** checkouts. Send each gate run's output to a log unique to you (e.g. `"$TMPDIR/gate-pr<pr>-head.log"`, `"$TMPDIR/gate-pr<pr>-merge.log"`). Record pass/fail with output. A gate that is green on the head but red on the merged result is a failure. If you start a background process, capture its PID (`$!`) and kill only that PID; never kill by pattern (`pkill -f`, `killall`).
6. **Read the diff** (`bash "$S/forge.sh" pr-diff <pr>`) against the relevant styleguide and the spec sections the task cites. Look for: criteria satisfied in letter but not intent, missing tests the criteria imply, scope creep beyond the task, styleguide violations, changes to files outside the task's module without justification, and whether the solution follows best practice for the stack (spec §2.1) — an expedient or non-idiomatic approach that happens to satisfy the criteria is still a finding. Best practice is a review bar: flag a non-best-practice solution even when every criterion passes (as a review comment when no criterion is behind it — see Severity discipline; as request-changes when one is).
7. **Post the verdict.** Write the body to `"$TMPDIR/verdict.md"`: per-criterion results (both gate runs included), each finding actionable. Re-read `bash "$S/forge.sh" pr-view <pr>` just before posting:
   - `head_sha` changed → do not post: report the head moved, then step 10 (the next tick reviews the new head).
   - `checks: "failure"` → the verdict is `request-changes`, citing the failing check.
   - `checks: "pending"` → a `request-changes` verdict is posted as usual (it does not depend on CI). An `approve` is **not** posted: report "checks still pending at `<head_sha>`; no verdict posted", skip steps 8–9, then step 10. Pending CI is not a failed post: the next tick (or `deliver-task`) re-runs the review once checks settle.
   Then:
   `bash "$S/forge.sh" pr-review <pr> approve|request-changes --sha <head_sha> --body-file "$TMPDIR/verdict.md"`
   - `approve` only when every criterion passes on the head, the gate passes on both checkouts, `checks` is `success` or `none`, and no substantive violation; otherwise `request-changes`.
   - The adapter appends `Reviewed-Head: <head_sha>`; do not write that line yourself. **Single-account fallback:** if the forge rejects a review of one's own PR, the adapter posts the same body as a comment-form verdict, headed with the verdict and ending in `Reviewed-Head: <head_sha>` (spec §13.2). Never post a verdict any other way.
   - Stdout `{posted, form: "formal"|"comment", url}`. Exit 1 = not posted: if the head moved (`head is …, not <sha>; refusing`), report it and stop — the next tick re-dispatches a review at the new head.
8. **Verify the verdict landed.** `bash "$S/forge.sh" pr-reviews <pr>` must contain an entry with `commit == <head_sha>` and `verdict` equal to what you posted (`approve` / `request-changes`), whichever `form` it took. **An unposted review did not happen**: if posting was denied or failed, or the entry is missing, report FAILURE ("review executed but could not be posted: <reason>") — never report approved/changes-requested as your outcome, and do not record a verdict you could not post.
9. **Record the verdict of record.** `bash "$S/graph.sh" transition <task_id> approved` (or `changes-requested`). Exit 2 = the node is not `in-review`: report that the verdict is posted but not recorded, and stop. Report **"ready for human merge"** on an approval — you never merge. **On a confirmed, recorded approval only**, run `NOTIFY_APPROVE_CMD` if it is set, in either verdict form: the node status, not the review's form, is the verdict of record. Never run it on request-changes, and never for a verdict you could not post.
10. **Cleanup — always, whatever happened above.** Remove the worktrees you created (if any), and only those: `git worktree remove --force .worktrees/review-pr-<pr>-head` and `git worktree remove --force .worktrees/review-pr-<pr>-merge`.

## Severity discipline

- **Unmet acceptance criterion = automatic request-changes.** No exceptions. So is a red gate on either checkout.
- Style nits with no criterion behind them = review comments, never blocks.
- Never approve your own implementation work (you shouldn't have any — see independence rules).

## Exit condition

A posted, verified verdict (approve or request-changes) pinned to `head_sha` + the node transitioned + both review worktrees removed + a one-line verdict reported — or a FAILURE report saying why no verdict landed, or a "checks still pending" report (step 7) with both review worktrees removed.
