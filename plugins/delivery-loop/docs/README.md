# Design docs

- `agentic_delivery_spec.md` — what the delivery system *is*: roles, the task
  model, the lifecycle state machine, queue mechanics, concurrency/conflict
  strategy, verification, and the upgrade path. The skills cite it by section.
  The v0.2 seams have their own sections:
  - [§15 Graph backends](agentic_delivery_spec.md#15-graph-backends) — `graph.sh`, the github and local backends;
  - [§16 Forges](agentic_delivery_spec.md#16-forges) — `forge.sh`, the github, gitlab and gitea adapters;
  - [§17 Branch flow & promotion](agentic_delivery_spec.md#17-branch-flow--promotion) — target branches, promote nodes, `promote.sh`;
  - [§18 Plan files](agentic_delivery_spec.md#18-plan-files) — the plan schema, `plan.sh lint`/`render`/`apply`.
- `delivery_runbook.md` — how a human *runs* it: operating modes, the free-run
  playbook, throughput physics, known constraints, troubleshooting, the backends
  and forge tokens, and the release-branch workflow.

Both are written to be project-agnostic; everything repo-specific is a key in
`.claude/delivery.conf` (see the spec's §2.2). They were extracted and hardened
in a real multi-agent build before being generalized here.
