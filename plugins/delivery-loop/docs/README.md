# Design docs

- `agentic_delivery_spec.md` — what the delivery system *is*: roles, the task
  model, the lifecycle state machine, queue mechanics, concurrency/conflict
  strategy, verification, and the upgrade path. The skills cite it by section.
- `delivery_runbook.md` — how a human *runs* it: operating modes, the free-run
  playbook, throughput physics, known constraints, and troubleshooting.

Both are written to be project-agnostic; everything repo-specific is a key in
`.claude/delivery.conf` (see the spec's §2.2). They were extracted and hardened
in a real multi-agent build before being generalized here.
