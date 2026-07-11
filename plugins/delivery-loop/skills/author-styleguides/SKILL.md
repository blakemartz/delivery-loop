---
name: author-styleguides
description: Author or evolve the repo's styleguides — the conventions in STYLEGUIDES_DIR that decompose fits tasks to, implementers follow, and reviewers enforce. Detects the stack, observes existing conventions, pins contested choices with the human, drafts, and lands nothing until the human ratifies. Re-runnable as stacks are added. e.g. "/author-styleguides" or "/author-styleguides python".
---

# author-styleguides — seed and evolve the constitution

You author the conventions the loop treats as constitutional: the decomposer fits tasks to them, implementers read them before writing code, and reviewers enforce them as the best-practice bar (spec `${CLAUDE_PLUGIN_ROOT}/docs/agentic_delivery_spec.md` §2.1, §3.2–3.4). They are the prose counterpart of the gate: `GATE_CMD` defines *correct* mechanically; the styleguides define *good* where only judgment can.

Read `.claude/delivery.conf` for `STYLEGUIDES_DIR` (default `styleguides/`), `GATE_CMD`, and `BASE_BRANCH`.

## Inputs

1. Optional scope argument (a stack or layer, e.g. "python", "frontend") — default: every stack detected in the repo.
2. What already exists in `STYLEGUIDES_DIR`. This skill is re-runnable: add the missing guide when a stack arrives, or revise a ratified one on explicit request — never silently rewrite ratified text.
3. The repo itself: language/framework manifests, the gate script `GATE_CMD` points at (it shows which rules are already enforced mechanically), CI workflows, and the existing code.

## Protocol

1. **Detect.** Enumerate the stacks and layers actually present (languages, frameworks, test tooling, repo topology — single package vs monorepo). One guide per stack/layer that agents will touch; skip layers with no code and no imminent work.
2. **Observe.** For each stack with existing code, mine the *dominant* conventions: layout, naming, typing strictness, error handling, dependency management, test placement and idiom. Where the codebase is consistent, the guide codifies what *is*. Where it is inconsistent, that is a **fork to pin, not a convention to codify**. Greenfield stacks start from the stack's idiomatic best practice.
3. **Pin.** Put the genuinely contested choices to the human as explicit decision sets, recommendation first (AskUserQuestion) — strictness levels, structural patterns, test philosophy, how to resolve each observed inconsistency. Never write a rule over an unpinned fork.
4. **Draft** one guide per stack/layer in the scratchpad. Keep each readable in one sitting: prescriptive rules, a short right/wrong example where ambiguity is likely, no restating what the stack's defaults already guarantee.
   - **Checkable rules graduate to the gate.** If a rule can be enforced mechanically (formatter, linter rule, type-checker flag, test), the guide states the principle and the enforcement belongs in the gate — wire it into `GATE_CMD`'s script now if trivial, otherwise flag it as a follow-up task for the backlog.
5. **Ratify — hard gate.** Present the drafts to the human with every judgment call flagged (each pin taken, anything observed-but-surprising, rules you chose *not* to write). **Nothing lands in the repo before the nod.** Apply their edits; re-present if the changes are substantive.
6. **Land.** Write the ratified guides into `STYLEGUIDES_DIR` (replace the seeded README stub's "empty constitution" note if present). Commit to `BASE_BRANCH` directly when the loop isn't live yet; open a PR when it is or when the operator prefers.

## Hard rules (violating any of these means your constitution is wrong)

1. **Nothing lands unratified** — the human's nod is what makes a convention constitutional.
2. **Never codify over an unpinned fork** — pins come from the human, not your preferences.
3. **Mechanically checkable rules graduate to the gate** — the styleguides hold only what judgment must enforce.
4. **Short enough that agents actually read them** — a guide nobody can hold in context is not a constitution, it's noise.

## Exit condition

Ratified guides exist in `STYLEGUIDES_DIR` for every in-scope stack (committed or in a PR), any gate-graduating rules are wired or filed, and the loop's implementers/reviewers have a real constitution to read — or a clean stop at the ratify gate, stated as such.
