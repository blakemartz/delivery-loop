---
name: author-spec
description: Author a decompose-ready sub-spec for one subsystem — collect operator pins, ground against code and primary sources, draft to the house template, land it through adversarial docs-review, then hand off to /decompose. Two hard human gates (draft nod before the PR, backlog approval inside /decompose). e.g. "/author-spec object storage".
---

# author-spec — subsystem → merged spec → backlog handoff

You are the **spec author** role from the delivery spec (`${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md`, §3.7). You produce the normative text the decomposer translates; you never implement tasks — **execution belongs to the delivery loop**.

Read `.claude/delivery.conf` for `SPEC_SOURCES` (where specs live / what `/decompose` reads), `STYLEGUIDES_DIR`, `BASE_BRANCH`, `WORKTREE_SETUP_CMD`, and `NOTIFY_ESCALATE_CMD`.

## Inputs

1. The subsystem argument (e.g. "object storage") — refuse politely if a spec for it already exists among `SPEC_SOURCES` (propose a vN+1 amendment instead).
2. The **parent/architecture specs** among `SPEC_SOURCES` — the frame the sub-spec derives from — and the product-intent doc if the repo keeps one (for the *why*, never for criteria). **If `SPEC_SOURCES` matches nothing, this is the repo's first spec:** frame it as the root architecture spec later sub-specs will derive from (§Frame states the whole system, not a parent), and skip the sibling pass in input 3.
3. Every **sibling sub-spec** the new one extends, consumes, or must not contradict, and the relevant conventions in `STYLEGUIDES_DIR`.
4. The live board: `gh issue list` + `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-queue.sh"` — cross-wave dependencies must name real issue numbers, and your repo's **serialization hazards** (e.g. DB migration single-head, generated-artifact/client regen, one-start-per-`module:`) are facts about *today's* in-flight waves.
5. Research notes, when the repo keeps them for the area.

## Pipeline (phase gates are hard — never skip forward)

1. **Frame.** Place the spec in the graph: sub-spec of what, extends/consumes which siblings, prerequisite of what, independent of what. State what exists in code today and what gap the spec closes.
2. **Pin.** Enumerate the genuine design forks (storage/queue/format choices, scope cutlines, rollout order). Present them to the operator as explicit decision sets with a recommendation first (AskUserQuestion), in prose a newcomer to the tool in question can follow. **Never write normative text over an unpinned fork.** Record the pins and their date in the spec header ("decisions confirmed with the operator YYYY-MM-DD").
3. **Ground.** Two passes, both mandatory:
   - *Repo*: an Explore agent maps the seams the spec builds on — exact model fields, protocols, registries, DTO gaps, and any **exhaustive enum/variant maps** a new case would ripple through (classic extension-race points — find them before the spec adds a variant).
   - *External*: every load-bearing external fact (endpoints, formats, licenses, rate limits, auth) is verified against **primary sources** (WebFetch/WebSearch or a research agent) — fetch the real API, don't trust prior notes. A fact that can't be verified is **flagged in the spec as unverified**, never silently assumed.
4. **Draft** to the house template (§Template below), in the scratchpad.
5. **Preview — hard gate.** Send the draft to the operator (SendUserFile when the harness provides it; otherwise print the draft path and a summary) with every judgment call flagged (cutline scope, deferred alternatives, anything that surprised you in grounding). **No PR before the nod.**
6. **Land.** Worktree from `origin/$BASE_BRANCH`; copy the spec into the specs directory (so `SPEC_SOURCES` matches it); make every §Cross-doc-alignment edit in the same commit; run `WORKTREE_SETUP_CMD` if the gate needs deps installed; commit, push, open the PR. Gates are never bypassed — no `--no-verify`, ever.
7. **Docs review.** Spawn a **fresh** adversarial reviewer (it must not see your drafting context). Its brief, which differs from `/delivery-loop:review-task` (there are no acceptance criteria to execute):
   - ground every claim the spec makes about existing code against `origin/$BASE_BRANCH`, and every external API contract against the **live** primary source;
   - check internal consistency (golden-case numbering, cutline ↔ case ↔ test-file mapping, §-references) and **buildability** (could a task agent implement each cutline task from the text and fixtures alone?);
   - sweep the other docs for claims this PR makes stale;
   - post exactly ONE verdict per round, as a GitHub **review comment**: `gh pr review --comment --body "<verdict>" <pr>` (flags first — the single-account verdict-of-record form; `delivery_runbook.md` §7, spec §13.2; formal `--approve`/`--request-changes` are rejected on same-account PRs), body opening `## Adversarial review — verdict: APPROVE|REQUEST_CHANGES` with numbered blockers. Verify it landed (`gh pr view --json reviews`) — an unposted verdict did not happen.
   Fix rounds: address blockers, push, and **resume the same reviewer** (its grounding context is the asset — a deliberate, docs-review-scoped deviation from the loop's fresh-reviewer rule, spec §3.7). Max 3 rounds, then `needs-human` (run `NOTIFY_ESCALATE_CMD` if set).
8. **Merge.** On APPROVE + green CI the PR is mergeable. Merge authority follows the delivery spec (§3.6, §8.2): **human by default** — squash-merge (`--delete-branch`) yourself only under the operator's explicit standing authorization; otherwise report ready-for-merge and stop at the gate. After the merge (whoever performs it): remove the worktree, fast-forward local `$BASE_BRANCH`.
9. **Hand off to `/decompose`.** Against the **merged** text — never pre-merge: review rounds change cutlines, and a pre-merge decomposition decomposes stale text. Run `/delivery-loop:decompose <spec area>` dry-run, present the printed backlog, and pass `--create` only on the operator's approval of that table (`/decompose`'s own gate — this skill sequences it, never absorbs or pre-satisfies it; a standing operator directive counts only when it explicitly covers backlog creation). Then report the epic, task numbers, and ready set, and update the operator's roadmap memory when the session keeps one.

## Template (the house shape — canonical order, applied with judgment)

Header (spec-graph position, research basis, pin date, code anchors) → **1 Purpose** → **2 Scope and non-goals** (cutline decisions; explicit "do not decompose" deferrals) → **3+ Design decisions** (normative; one § per subsystem piece, mapping tables pinned row by row) → **Domain model** (schema/migration changes marked ⚠ — additive/schema-only per house pattern; omit the section entirely in a migration-free wave) → **Semantics** → **API surface** (pagination convention; generated-artifact/client-regen discipline named where the stack has codegen) → **Golden cases** (numbered **globally** across the spec, fixture-pinned; one consolidated § or distributed per-subsystem tables — every normative behavior is owned by a case; a behavior no case pins is a review blocker) → **Configuration** (placement may precede the golden cases) → **Rollout/roadmap** (informative, when applicable) → **Deferred** → **Cross-doc alignment** (every touched doc, **always** including the registration that keeps the spec decomposable: ensure the new spec is matched by `SPEC_SOURCES` — add it to the glob/list if not — and listed wherever the repo indexes its specs) → **Decompose-ready cutline** + status footer ("authored YYYY-MM-DD; decomposition follows this PR's merge; execution belongs to the delivery loop"). Sections that genuinely don't apply are **omitted, never left empty** — the non-negotiables are the explicit deferrals, the golden-case ownership rule, the registration, and the cutline + footer.

## Hard rules (violating any of these means your spec is wrong)

1. **No normative text over an unpinned fork** — pins come from the operator, not from your preferences.
2. **Primary sources or flagged** — an unverified external fact stated as normative is a defect, not a shortcut.
3. **The cutline obeys `/decompose`'s hard rules verbatim** (command-checkable seams, ≤ size:M, exactly one `module:` per task) **plus the serialization flags** your repo needs: schema/migration ⚠, generated-artifact regen, and cross-wave `Depends-on:` with real issue numbers.
4. **Two human gates, always**: the draft nod (before the PR) and the `/decompose` backlog approval. An explicit operator instruction may waive a *named* gate ("skip the preview", "decompose on merge without re-asking"); silence waives nothing, and waiving one gate never waives the other.
5. **Fresh reviewer, one review-comment verdict per round, verdict verified landed** — an unposted verdict did not happen.
6. **Golden cases are the contract** — number them once, renumber everything downstream when review inserts one, and grep for stale references before pushing.

## Exit condition

Spec merged on `$BASE_BRANCH`, registered so `SPEC_SOURCES` matches it, decomposed into an epic + tasks with the ready set printed, roadmap memory updated — or a clean stop at a phase gate (draft awaiting nod / review awaiting fix round / `needs-human`), stated as such.
