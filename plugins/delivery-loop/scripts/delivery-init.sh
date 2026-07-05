#!/usr/bin/env bash
# delivery-init.sh — one-time, idempotent bootstrap of the delivery loop in the
# CURRENT git repo. Safe to re-run: every step checks before it acts.
#
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-init.sh" [module ...]
#
# Creates the label taxonomy the engine + skills depend on, scaffolds
# .claude/delivery.conf with sensible detected defaults, and gitignores
# .worktrees/. Optional args become extra module:<name> labels; you can also
# list modules in .claude/delivery.conf (MODULES=...).
#
# It deliberately does NOT change repo merge settings (an outward-facing change)
# — it only prints the recommended command for you to run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

echo "==> repo: $(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo '(no remote yet)')"

# --- labels (idempotent via --force) ----------------------------------------
label() { gh label create "$1" --color "$2" --description "$3" --force >/dev/null && echo "  label: $1"; }

echo "==> labels: type / status / claim / authorship / size"
label "task" "1D76DB" "A unit of claimable work"
label "epic" "3E4B9E" "Tracker for a group of tasks; never claimable"
label "status:blocked"           "D93F0B" "Has unmet Depends-on issues"
label "status:ready"             "0E8A16" "Claimable now"
label "status:claimed"           "FBCA04" "Someone is working on it"
label "status:in-review"         "C5DEF5" "PR open, awaiting review"
label "status:changes-requested" "E99695" "Reviewer requested changes"
label "status:approved"          "2EA44F" "Reviewed and ready for human merge"
label "needs-human"              "B60205" "Escalated: a human must intervene"
label "claim:agent" "BFD4F2" "Claimed by an agent (absence + assignee = human claim)"
label "agent-authored" "EDEDED" "Produced by an agent"
label "human-authored" "EDEDED" "Produced by a human"
label "size:S" "C2E0C6" "Small: single-sitting change"
label "size:M" "FEF2C0" "Medium: max claimable size"
label "size:L" "F9D0C4" "Too big to claim - decompose further"

# --- module labels: built-ins + MODULES from conf + CLI args -----------------
modules_from_conf=""
[ -f .claude/delivery.conf ] && modules_from_conf="$( ( . .claude/delivery.conf 2>/dev/null; echo "${MODULES:-}" ) )"
echo "==> labels: module:*"
for m in infra docs $modules_from_conf "$@"; do
  [ -n "$m" ] && label "module:$m" "5319E7" "Owning module: $m"
done

# --- .worktrees/ gitignore ---------------------------------------------------
if ! grep -qxF '.worktrees/' .gitignore 2>/dev/null; then
  printf '\n# delivery-loop task worktrees\n.worktrees/\n' >> .gitignore
  echo "==> gitignore: added .worktrees/"
fi

# --- seed scripts/check.sh from detected tooling -----------------------------
# The gate is a checked-in, extensible artifact: init writes a best-effort
# starter from the linters / type-checkers / test frameworks it detects, and
# tasks extend it as the repo grows. Prefer the repo's own declared commands
# (package.json scripts) over guessed tool invocations. An undefined gate must
# FAIL rather than pass green, so a no-tooling seed exits 1 until you define it.
if [ -f scripts/check.sh ]; then
  echo "==> scripts/check.sh already exists — leaving it untouched"
else
  gate_steps=""
  add_step() { gate_steps="${gate_steps}$1"$'\n'; }

  # JS / TS — use the repo's own package.json scripts (jq is a prerequisite).
  if [ -f package.json ]; then
    pm=npm
    [ -f pnpm-lock.yaml ] && pm=pnpm
    [ -f yarn.lock ]      && pm=yarn
    for s in lint typecheck build test; do
      if jq -e --arg s "$s" '(.scripts // {})[$s] // empty' package.json >/dev/null 2>&1; then
        add_step "echo '==> $s'; $pm run $s"
      fi
    done
  fi

  # Python — detect configured tools; run through uv if a uv.lock is present.
  if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
    py=""; [ -f uv.lock ] && py="uv run "
    if [ -f ruff.toml ] || [ -f .ruff.toml ] || grep -q 'tool\.ruff' pyproject.toml 2>/dev/null; then
      add_step "echo '==> ruff';   ${py}ruff check ."
    fi
    if [ -f mypy.ini ] || [ -f .mypy.ini ] || grep -q 'tool\.mypy' pyproject.toml 2>/dev/null; then
      add_step "echo '==> mypy';   ${py}mypy ."
    fi
    if [ -f pytest.ini ] || [ -f tox.ini ] || grep -q 'tool\.pytest' pyproject.toml 2>/dev/null || [ -d tests ]; then
      add_step "echo '==> pytest'; ${py}pytest"
    fi
  fi

  # Go / Rust — standard toolchains.
  if [ -f go.mod ]; then
    add_step "echo '==> vet';    go vet ./..."
    add_step "echo '==> build';  go build ./..."
    add_step "echo '==> tests';  go test ./..."
  fi
  if [ -f Cargo.toml ]; then
    add_step "echo '==> clippy'; cargo clippy -- -D warnings"
    add_step "echo '==> build';  cargo build"
    add_step "echo '==> tests';  cargo test"
  fi

  mkdir -p scripts
  {
    cat <<'HDR'
#!/usr/bin/env bash
# check.sh — THE verification gate for this repo.
#
# The single definition of "is this repo correct": the delivery loop runs this
# identically for implementers, reviewers, and patchers (it is GATE_CMD in
# .claude/delivery.conf). Change what "correct" means HERE, nowhere else.
#
# Keep it honest as the repo grows: a task that adds a linter, test suite, or
# build step should extend this file to cover it.
#
# Seeded by /delivery-loop:init from detected tooling — review and adjust.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

HDR
    if [ -z "$gate_steps" ]; then
      cat <<'EMPTY'
# init detected no linters, type-checkers, or test frameworks in this repo.
# An undefined gate must fail rather than pass green — define your checks below
# (each must exit non-zero on failure), then delete this guard.
echo "check.sh: no checks defined yet — edit scripts/check.sh (see /delivery-loop:init)." >&2
exit 1
EMPTY
    else
      printf '%s' "$gate_steps"
      printf '\necho "==> gate passed"\n'
    fi
  } > scripts/check.sh
  chmod +x scripts/check.sh
  if [ -z "$gate_steps" ]; then
    echo "==> wrote scripts/check.sh — NO tooling detected; it fails until you define checks"
  else
    echo "==> wrote scripts/check.sh from detected tooling — review it before running the loop"
  fi
fi

# --- scaffold .claude/delivery.conf ------------------------------------------
mkdir -p .claude
if [ -f .claude/delivery.conf ]; then
  echo "==> .claude/delivery.conf already exists — leaving it untouched"
else
  setup_cmd=""; gate_cmd="bash scripts/check.sh"
  if   [ -f pnpm-lock.yaml ];   then setup_cmd="pnpm install --silent"
  elif [ -f package-lock.json ];then setup_cmd="npm ci"
  elif [ -f yarn.lock ];        then setup_cmd="yarn install --frozen-lockfile"
  elif [ -f uv.lock ];          then setup_cmd="uv sync"
  elif [ -f pyproject.toml ];   then setup_cmd="uv sync"
  elif [ -f go.mod ];           then setup_cmd="go mod download"
  elif [ -f Cargo.toml ];       then setup_cmd="cargo fetch"
  fi
  cat > .claude/delivery.conf <<EOF
# delivery-loop per-repo config. Sourced by the plugin's engine scripts and read
# by its skills. Every value is optional; the defaults shown are used when unset.

# Base branch worktrees fork from and PRs target.
BASE_BRANCH=main

# Command run once inside each fresh task worktree (install deps). Empty = none.
WORKTREE_SETUP_CMD="$setup_cmd"

# THE gate: one command that exits 0 iff the repo is correct. Implementers,
# patchers, and reviewers all run this. Point it at YOUR repo's check script.
GATE_CMD="$gate_cmd"

# Where /delivery-loop:decompose reads task specs from (glob; space-separated ok).
SPEC_SOURCES="docs/*_spec.md"

# Where the coding conventions live (read before implementing / reviewing).
STYLEGUIDES_DIR="styleguides/"

# Allowed module: labels (space-separated). The module is the concurrency unit:
# at most one in-flight task per module. Empty = modules optional.
MODULES=""

# Optional notification hooks. Run when a review lands an approval / when a task
# escalates to needs-human. Empty = silent. Example (macOS):
#   NOTIFY_APPROVE_CMD="afplay /System/Library/Sounds/Glass.aiff"
#   NOTIFY_ESCALATE_CMD="afplay /System/Library/Sounds/Basso.aiff"
NOTIFY_APPROVE_CMD=""
NOTIFY_ESCALATE_CMD=""
EOF
  echo "==> wrote .claude/delivery.conf (edit GATE_CMD to your repo's gate)"
fi

echo
echo "Done. Next:"
echo "  1. Review scripts/check.sh — init seeded it from detected tooling; make"
echo "     sure it runs your repo's real checks (GATE_CMD points at it)."
echo "  2. Recommended repo merge settings (run yourself; outward-facing):"
echo "       gh repo edit --enable-squash-merge --enable-merge-commit=false \\"
echo "                    --enable-rebase-merge=false --delete-branch-on-merge"
echo "  3. Propose a backlog: /delivery-loop:decompose"
