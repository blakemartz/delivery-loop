#!/usr/bin/env bash
# delivery-init.sh — one-time, idempotent bootstrap of the delivery loop in the
# CURRENT git repo. Safe to re-run: every step checks before it acts.
#
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-init.sh" [module ...]
#
# Seams (docs/delivery_graph_spec.md §10 `init` row, §11): GRAPH_BACKEND
# (github | local) and FORGE (github | gitlab | gitea) come from, in order, an
# existing .claude/delivery.conf (plus env overrides, as lib/config.sh resolves
# them), the environment, or detection from the origin remote's host (asked on
# a terminal when the host is unrecognized). FORGE=github defaults the backend
# to github; any other forge defaults it to local. gh is required only when a
# seam is github.
#
# Requirements, checked up front: jq >= 1.6 always; git >= 2.31 for the local
# backend (`rev-parse --path-format`, §6.3); gh >= 2.94 for the github backend
# (native issue relations, §6.2).
#
# Local scaffolding runs first (gitignore, gate seed, .claude/delivery.conf with
# every §11 key, styleguides stub, and on the local backend the STATE_DIR store
# of §6.3), so a repo with no remote still gets it. Then, with a remote: forge
# auth via `forge.sh whoami`, and on the github backend the label taxonomy
# (including `promote`). With no remote, the script says how to connect one and
# exits 2 — re-run after connecting to finish. Optional args become extra
# module:<name> labels (github backend); you can also list modules in
# .claude/delivery.conf (MODULES=...).
#
# It deliberately does NOT change repo settings (outward-facing changes like
# merge strategy or enabling Issues) — it only prints the advice. That advice
# keeps merge commits ENABLED: promotion PRs merge with PROMOTE_MERGE_METHOD.
#
# Exit codes: 0 done · 1 a requirement or step failed · 2 no remote yet.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

# ver_ge HAVE WANT: dotted-numeric HAVE >= WANT (missing parts count as 0).
ver_ge() {
  local h="$1" w="$2" hn wn
  while [ -n "$h$w" ]; do
    hn="${h%%.*}"; wn="${w%%.*}"
    if [ "${hn:-0}" -gt "${wn:-0}" ]; then return 0; fi
    if [ "${hn:-0}" -lt "${wn:-0}" ]; then return 1; fi
    case "$h" in *.*) h="${h#*.}" ;; *) h="" ;; esac
    case "$w" in *.*) w="${w#*.}" ;; *) w="" ;; esac
  done
  return 0
}

# tool_ver CMD...: the first dotted version number on the command's first
# output line ("jq-1.7.1", "git version 2.39.3 (Apple Git-146)", "gh version
# 2.94.0 (…)"), or empty if there is none.
tool_ver() {
  { "$@" 2>/dev/null || true; } | sed -n '1s/^[^0-9]*\([0-9][0-9]*\(\.[0-9][0-9]*\)*\).*/\1/p'
}

# origin_host: the lowercased host of the origin remote (https, ssh:// and
# scp-style forms), or empty.
origin_host() {
  local u r
  u="$(git remote get-url origin 2>/dev/null || true)"
  case "$u" in
    *://*) r="${u#*://}"; r="${r%%/*}"; r="${r##*@}"; r="${r%%:*}" ;;
    *:*)   r="${u%%:*}"; r="${r##*@}" ;;
    *)     r="" ;;
  esac
  printf '%s' "$r" | tr '[:upper:]' '[:lower:]'
}

# detect_forge HOST: github | gitlab | gitea from well-known host names, or empty.
detect_forge() {
  case "$1" in
    github.com|*.github.com)                    echo github ;;
    gitlab.com|*gitlab*)                        echo gitlab ;;
    codeberg.org|*gitea*|*forgejo*)             echo gitea ;;
    *)                                          : ;;
  esac
}

# --- preflight: jq (the whole engine) ------------------------------------------
command -v jq >/dev/null 2>&1 || die "jq >= 1.6 is required (the engine parses all state with it). Install jq and re-run."
jq_v="$(tool_ver jq --version)"
if [ -n "$jq_v" ]; then
  ver_ge "$jq_v" 1.6 || die "jq >= 1.6 is required (found jq $jq_v). Upgrade jq and re-run."
elif ! jq -n --rawfile x /dev/null 'true' >/dev/null 2>&1; then
  die "jq >= 1.6 is required (for --rawfile); found: $(jq --version 2>&1 || echo unknown)"
fi

# --- seams: GRAPH_BACKEND and FORGE ------------------------------------------
conf_existed=0
[ ! -f .claude/delivery.conf ] || conf_existed=1
if [ -f .claude/delivery.conf ]; then
  # Resolve exactly as the engine will (defaults < file < env), in a subshell so
  # config.sh's exports do not leak in before it is sourced for real below.
  seams="$(. "$SCRIPT_DIR/lib/config.sh"; printf '%s %s' "$GRAPH_BACKEND" "$FORGE")"
  backend="${seams% *}"; forge="${seams#* }"
  seam_src="from .claude/delivery.conf"
else
  forge="${FORGE:-}"; seam_src="from the environment"
  if [ -z "$forge" ]; then
    host="$(origin_host)"
    forge="$(detect_forge "$host")"
    seam_src="detected from origin ($host)"
    if [ -z "$forge" ] && [ -n "$host" ] && [ -t 0 ]; then
      printf 'Which forge hosts %s? [github/gitlab/gitea] (github): ' "$host" >&2
      read -r forge || forge=""
      seam_src="chosen for origin ($host)"
    fi
    if [ -z "$forge" ]; then
      forge=github
      if [ -n "$host" ]; then
        seam_src="default: origin host '$host' not recognized; set FORGE=gitlab|gitea and re-run if it is not GitHub"
      else
        seam_src="default: no origin remote"
      fi
    fi
  fi
  backend="${GRAPH_BACKEND:-}"
  if [ -z "$backend" ]; then
    if [ "$forge" = github ]; then backend=github; else backend=local; fi
  fi
fi
echo "==> seams: GRAPH_BACKEND=$backend FORGE=$forge ($seam_src)"

# Validate the combination before anything is written (delivery-config.sh
# --check semantics: GC40, GC41, GC59).
if ! ( export GRAPH_BACKEND="$backend" FORGE="$forge"; . "$SCRIPT_DIR/lib/config.sh"; dl_config_check ); then
  die "invalid GRAPH_BACKEND/FORGE combination (above) — fix it and re-run; nothing was written."
fi

# --- preflight: per-seam tools -------------------------------------------------
if [ "$backend" = local ]; then
  git_v="$(tool_ver git --version)"
  if [ -n "$git_v" ]; then
    ver_ge "$git_v" 2.31 || die "git >= 2.31 is required by GRAPH_BACKEND=local (\`rev-parse --path-format\`); found git $git_v."
  else
    case "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)" in
      /*) : ;;
      *) die "git >= 2.31 is required by GRAPH_BACKEND=local (\`rev-parse --path-format\`)." ;;
    esac
  fi
fi
if [ "$backend" = github ] || [ "$forge" = github ]; then
  command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required when a seam is github (GRAPH_BACKEND=$backend FORGE=$forge). Install it, then: gh auth login"
  if [ "$backend" = github ]; then
    gh_v="$(tool_ver gh --version)"
    if [ -n "$gh_v" ] && ! ver_ge "$gh_v" 2.94; then
      die "gh >= 2.94 is required by GRAPH_BACKEND=github (native blocked-by / parent relations); found gh $gh_v. Upgrade gh and re-run."
    fi
  fi
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
fi

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

# Graph backend: where tasks and their dependency graph live. github | local.
# GRAPH_BACKEND=github requires FORGE=github.
GRAPH_BACKEND=$backend

# Local backend store. Empty = <git-common-dir>/delivery (shared by all worktrees).
STATE_DIR=""

# Seconds after which a local-backend lock is considered stale and may be broken.
LOCK_STALE_SECONDS=120

# github backend fetch ceiling; reaching it is an error, never a silent truncation.
LIST_LIMIT=5000

# Forge: where PRs live. github | gitlab | gitea. FORGE_URL (API base host) and
# FORGE_REPO (owner/repo, or group/subgroup/project) are derived from the origin
# remote when empty. Tokens (GITLAB_TOKEN, GITEA_TOKEN, *_REVIEW_TOKEN) come from
# the environment only — never put them in this checked-in file.
FORGE=$forge
FORGE_URL=""
FORGE_REPO=""

# Where plan files live.
PLANS_DIR="docs/plans/"

# Merge methods for task PRs and for promotion PRs.
TASK_MERGE_METHOD=squash
PROMOTE_MERGE_METHOD=merge

# Gate run on the target branch before a promotion PR. Empty = GATE_CMD.
PROMOTE_GATE_CMD=""
EOF
  echo "==> wrote .claude/delivery.conf (edit GATE_CMD to your repo's gate)"
fi

# --- resolve config (delivery.conf exists by now) -----------------------------
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"


# An existing (e.g. pre-v0.2) conf is never rewritten; name the keys it leaves
# to their built-in defaults so the operator can pin them if they care.
if [ "$conf_existed" = 1 ]; then
  missing=""
  for k in $_DL_VARS; do
    grep -qE "^[[:space:]]*(export[[:space:]]+)?$k=" .claude/delivery.conf || missing="$missing $k"
  done
  if [ -n "$missing" ]; then
    echo "    note: it does not set:$missing — built-in defaults apply (README config table)"
  fi
fi
# --- seed the styleguides directory ------------------------------------------
# STYLEGUIDES_DIR is the constitutional layer: decompose fits tasks to it,
# implementers read it before writing code, reviewers enforce it. Init only
# marks the spot — /delivery-loop:author-styleguides drafts the actual guides
# (with the human ratifying them).
if [ -d "$STYLEGUIDES_DIR" ]; then
  echo "==> $STYLEGUIDES_DIR already exists — leaving it untouched"
else
  mkdir -p "$STYLEGUIDES_DIR"
  cat > "$STYLEGUIDES_DIR/README.md" <<'EOF'
# Styleguides

The coding conventions the delivery loop treats as constitutional: the
decomposer fits tasks to them, implementers read the relevant guide before
writing code, and reviewers enforce them as a review bar.

This directory is empty because no guides have been authored yet. Run
`/delivery-loop:author-styleguides` to draft them from your stack and your
codebase's existing conventions — you review and ratify before anything lands.

Keep each guide short and prescriptive. A rule that can be checked mechanically
belongs in the gate (see GATE_CMD in .claude/delivery.conf), not in prose here.
EOF
  echo "==> seeded $STYLEGUIDES_DIR (empty constitution — run /delivery-loop:author-styleguides)"
fi


# --- local backend: the STATE_DIR store (§6.3) --------------------------------
# Initial layout: store.json {"schema":1,"created_at":…}, epics/, events.jsonl.
# An existing store is never rewritten; a store.json with another schema, or
# epic files without a store.json (a lost store), is refused, as the backend
# itself refuses them.
state=""
if [ "$GRAPH_BACKEND" = local ]; then
  state="$STATE_DIR"
  if [ -z "$state" ]; then
    common="$(git rev-parse --path-format=absolute --git-common-dir)" \
      || die "cannot resolve the git common dir for the default STATE_DIR"
    state="$common/delivery"
  fi
  if [ -f "$state/store.json" ]; then
    found="$(jq -r '.schema // "none" | tostring' "$state/store.json" 2>/dev/null || true)"
    [ "$found" = 1 ] \
      || die "local store $state/store.json: schema mismatch (expected 1, found ${found:-unparseable}); no implicit migrations"
    mkdir -p "$state/epics"
    [ -f "$state/events.jsonl" ] || : > "$state/events.jsonl"
    echo "==> local store: $state already initialized — leaving it untouched"
  else
    orphans="$(find "$state/epics" -maxdepth 1 -name '*.json' 2>/dev/null | head -n 1 || true)"
    [ -z "$orphans" ] \
      || die "local store: $state/store.json is missing but epic files exist under $state/epics — restore store.json (refusing to treat the store as empty)"
    mkdir -p "$state/epics"
    jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{schema: 1, created_at: $now}' > "$state/store.json.tmp.$$"
    mv "$state/store.json.tmp.$$" "$state/store.json"
    [ -f "$state/events.jsonl" ] || : > "$state/events.jsonl"
    echo "==> local store: created $state (store.json schema 1, epics/, events.jsonl)"
  fi
fi

# --- a connected remote is required from here --------------------------------
# "No remote" is decided from local git state (can't flake); once a remote
# exists, a forge failure is surfaced as a forge failure — never misread as "no repo".
if [ -z "$(git remote)" ]; then
  if [ "$FORGE" = github ]; then
    connect="      gh repo create <name> --private --source=. --push    # brand-new repo
      git remote add origin <url> && git push -u origin $BASE_BRANCH   # existing repo"
  else
    connect="      git remote add origin <url> && git push -u origin $BASE_BRANCH   # a $FORGE repo"
  fi
  cat >&2 <<EOF

==> Local scaffolding is done, but no remote is connected — the loop's PRs
    live on the forge ($FORGE), so the forge steps can't run yet.

    Connect one, then RE-RUN this script (it is idempotent) to finish:
$connect
EOF
  exit 2
fi

# --- forge auth (§7.1 whoami) --------------------------------------------------
if ! login="$(bash "$SCRIPT_DIR/forge.sh" whoami)" || [ -z "$login" ]; then
  die "forge auth check failed (\`forge.sh whoami\`, FORGE=$FORGE, see above). Check the token in the environment / gh auth, FORGE_URL and FORGE_REPO."
fi
echo "==> forge: $FORGE, authenticated as $login"

# --- github backend: repo + label taxonomy -------------------------------------
issues_enabled=true
repo_slug=""
if [ "$GRAPH_BACKEND" = github ]; then
  if ! repo_json="$(gh repo view --json nameWithOwner,hasIssuesEnabled)"; then
    echo "ERROR: a git remote exists but gh could not resolve the GitHub repo (see error above)." >&2
    echo "       Check auth/network (gh auth status); on a fork, pick the repo: gh repo set-default" >&2
    exit 1
  fi
  repo_slug="$(jq -r .nameWithOwner <<<"$repo_json")"
  issues_enabled="$(jq -r .hasIssuesEnabled <<<"$repo_json")"
  echo "==> repo: $repo_slug"
  case "$issues_enabled" in
    true)  : ;;
    false) echo "WARNING: Issues are DISABLED on $repo_slug (common on forks) — the loop cannot file or claim tasks until you run: gh repo edit --enable-issues" >&2 ;;
    *)     echo "WARNING: could not verify Issues are enabled on $repo_slug — check manually; enable with: gh repo edit --enable-issues" >&2 ;;
  esac

  # labels (idempotent via --force)
  label() {
    gh label create "$1" --color "$2" --description "$3" --force >/dev/null \
      || { echo "ERROR: creating label '$1' failed (see above) — the label set is incomplete; fix the cause and re-run (idempotent)." >&2; exit 1; }
    echo "  label: $1"
  }

  echo "==> labels: kind / status / claim / authorship / size"
  label "task" "1D76DB" "A unit of claimable work"
  label "epic" "3E4B9E" "Tracker for a group of tasks; never claimable"
  label "promote" "0B6E99" "Promotion node: merges a plan's target branch onward; never claimable"
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

  # module labels: built-ins + MODULES from conf + CLI args
  echo "==> labels: module:*"
  set -f  # $MODULES splits on words; don't let a stray glob match repo files
  for m in infra docs $MODULES "$@"; do
    [ -n "$m" ] && label "module:$m" "5319E7" "Owning module: $m"
  done
  set +f
else
  echo "==> labels: skipped (GRAPH_BACKEND=local keeps the graph in $state, not in labels)"
  if [ "$#" -gt 0 ]; then
    echo "    note: module args ($*) are labels on the github backend only — list modules in MODULES= in .claude/delivery.conf"
  fi
fi

echo
echo "Done. Next:"
if [ "$GRAPH_BACKEND" = github ] && [ "$issues_enabled" != "true" ]; then
  echo "  0. Ensure Issues are enabled on $repo_slug (the loop is inert without them):"
  echo "       gh repo edit --enable-issues"
fi
echo "  1. Review scripts/check.sh — init seeded it from detected tooling; make"
echo "     sure it runs your repo's real checks (GATE_CMD points at it)."
echo "  2. Recommended repo merge settings (apply them yourself; outward-facing)."
echo "     Keep merge commits ENABLED: task PRs merge with TASK_MERGE_METHOD=$TASK_MERGE_METHOD,"
echo "     promotion PRs with PROMOTE_MERGE_METHOD=$PROMOTE_MERGE_METHOD (a merge commit keeps ancestry)."
case "$FORGE" in
  github)
    echo "       gh repo edit --enable-squash-merge --enable-merge-commit \\"
    echo "                    --enable-rebase-merge=false --delete-branch-on-merge" ;;
  gitlab)
    echo "       Settings > Merge requests: Merge method 'Merge commit' (the project-level"
    echo "       method decides what a non-squash merge produces); Squash commits 'Allow';"
    echo "       enable 'Delete source branch' by default." ;;
  gitea)
    echo "       Repository settings > Pull Requests: enable 'Create merge commit' and"
    echo "       'Create squash commit' (a disallowed merge style is refused with 405);"
    echo "       enable 'Delete pull request branch after merge by default'." ;;
esac
echo "  3. Author your styleguides — the conventions every agent implements and"
echo "     reviews against: /delivery-loop:author-styleguides"
echo "  4. Specs: if none exist yet, author the first with /delivery-loop:author-spec;"
echo "     then propose a backlog: /delivery-loop:decompose"
